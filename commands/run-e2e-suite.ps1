# AI Broker Windows E2E suite -- MAIN orchestrator.
#
# Runs every checklist item marked DONE in
# docs/ai-broker-work/ai-broker-windows-e2e-runbook.html §7, in one pass,
# against the AiBrokerTest service on this VM. This does not reimplement the
# individual tests -- it calls the same commands\phase-*.ps1 / path-*.ps1
# scripts that already proved each thing, in a safe order, narrating what's
# about to happen before each one so the run can be followed without the
# runbook open beside it.
#
# COMPONENT NAMES used throughout match the "AI Broker Control Plane"
# architecture diagram -- the CURRENT-STATE cut, docs\ai-broker-work\
# ai-gateway-control-plane.html -- so a step here and a box/arrow in that
# diagram are the same thing:
#   - ai-protect daemon        -- root (dev shell) / LocalSystem (as a service)
#   - ai-broker-mon --control  -- the console user (umesh); the daemon drops
#                                 to this identity via CreateProcessAsUserW
#                                 before spawning it
#   - ai-broker-mon --llm-proxy -- a CHILD of --control, same identity, no
#                                 second privilege drop
#   - ai-broker-mon --mcp-server -- spawned later by the AGENT itself (Codex),
#                                 not by this suite; only its config wiring is
#                                 exercised here
#
# There is no control socket / named pipe and no multi-message handshake
# anymore (that older design -- StartUp/StartedUp, RegisterAgent/
# AgentRegistered, PushCredential/CredentialApplied -- is retired; see
# Diagram 01 of docs\ai-broker-work\ai-broker-control-plane.html for the
# historical record). ai-protect and ai-broker now exchange exactly two
# files, each independently polled every 3s, neither side holding a live
# connection to the other:
#   - broker.json  -- ai-protect writes (bound user, home, credential, the
#     full discovered-agent list, per-agent advisories); ai-broker watches it
#   - status.json  -- ai-broker writes (LLM-proxy readiness, whether it needs
#     a fresh credential, per-agent registration status + config deltas);
#     ai-protect watches it and merges any delta into that agent's real
#     config file itself -- ai-broker never writes an agent's config directly
#
# RUN THIS from umesh's own, NON-elevated PowerShell window. Several steps
# need elevation (starting/stopping the service, reading another session's
# process owner) -- those are delegated to run-e2e-suite-elevated-helper.ps1,
# which must already be running in a separate elevated window (see that
# script's own header for how to open one). This script will tell you plainly
# if it can't reach the helper.
#
# WHAT THIS DELIBERATELY DOES NOT AUTOMATE, and why:
#   - Path A (direct `--llm-proxy` run) -- it blocks in its own window on an
#     interactive OIDC browser login and is meant to be left running; Path B
#     (the service) already exercises the same proxy code end-to-end without
#     a second interactive login, so this suite runs Path B only.
#   - The "nobody logged on" negative case -- it requires an actual RDP
#     logoff of the session this script would be running in, plus a
#     SYSTEM-context scheduled task for the mock. Automating a self-logoff
#     from inside an unattended script is exactly the kind of action that
#     should be a deliberate, separate act, not a side effect of "run
#     everything". See commands\phase-e-nobody-setup2.ps1 onward to run it by
#     hand.
#   - A reboot-survival pass -- opt in explicitly with -IncludeReboot; off by
#     default because it restarts the VM this script is running on.
#   - VM cleanup and the credential-push end-to-end check -- neither is in
#     the DONE list (cleanup is TODO, credential push is BLOCKED on a
#     daemon-side stub), so neither belongs in a "run the done steps" script.

param(
    [switch]$SkipDestructive,   # skip protocol-mismatch / enabled=false / watchdog / --recover
    [switch]$IncludeReboot,     # opt in to the reboot-survival check (restarts this VM)
    [int]$ElevatedTimeoutSeconds = 60
)

$ErrorActionPreference = "Continue"
$repoRoot   = (Resolve-Path "$PSScriptRoot\..").Path
$home_      = "C:\Users\umesh"
$testDir    = "C:\ai-broker-test"
$brokerLog  = "$home_\.ai-broker\logs\zax.log"
$transcript = "$testDir\run-e2e-suite-$(Get-Date -Format yyyyMMdd-HHmmss).log"

New-Item -ItemType Directory -Path $testDir -Force | Out-Null
try { Start-Transcript -Path $transcript -Append | Out-Null } catch {}

$results = @()  # {step, item, verdict}

function Show-Step {
    param(
        [int]$Num,
        [string]$Item,
        [string[]]$Components,
        [string]$Messages = "",
        [string]$Why,
        [switch]$Destructive,
        [string]$Restores = "",
        [string]$Anchors = ""   # zax-anchor slug(s) -- see "AI Broker Control Plane" diagram
    )
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host ("STEP $Num -- $Item") -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host "components:" -ForegroundColor DarkCyan
    foreach ($c in $Components) { Write-Host "  - $c" }
    if ($Messages) { Write-Host "message(s) : $Messages" -ForegroundColor DarkCyan }
    Write-Host "why        : $Why" -ForegroundColor DarkCyan
    if ($Anchors) {
        # Grep the repo for this exact string to land on the code this step
        # exercises -- a slug outlives line-number drift; the doc-side match
        # is the same tag in the "AI Broker Control Plane" diagram/artifact.
        Write-Host "code       : zax-anchor(ai-broker-control-plane): $Anchors" -ForegroundColor DarkGray
    }
    if ($Destructive) {
        Write-Host "impact     : DESTRUCTIVE -- $Restores" -ForegroundColor Yellow
    } else {
        Write-Host "impact     : read-only / self-contained, nothing to restore" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# $Pass defaults to $true so call sites that only ever report an
# informational/skip verdict (never a real failure) don't need to pass it.
# Any call site that DOES have a real pass/fail signal must pass it
# explicitly -- that's what makes the abort-on-first-failure below meaningful
# instead of decorative.
function Record($item, $verdict, [bool]$Pass = $true) {
    # $script: (not a bare local $results) -- otherwise each call would create
    # its own local array and the summary table at the end would show only
    # the very last entry.
    $script:results += [pscustomobject]@{ Item = $item; Verdict = $verdict }
    if ($Pass) { return }

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Red
    Write-Host "ABORTING -- '$item' failed. Not proceeding to later steps." -ForegroundColor Red
    Write-Host ("=" * 78) -ForegroundColor Red
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host "SUMMARY (partial -- run stopped early)" -ForegroundColor Green
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    $script:results | Format-Table -AutoSize -Wrap
    Write-Host ""
    Write-Host "Full transcript: $transcript" -ForegroundColor Green
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

function Invoke-Elevated {
    param([string]$Action, [int]$TimeoutSeconds = $ElevatedTimeoutSeconds)
    $id       = [guid]::NewGuid().ToString()
    $reqFile  = "$testDir\elevated-request.json"
    $respFile = "$testDir\elevated-response-$id.json"
    @{ id = $id; action = $Action } | ConvertTo-Json | Set-Content -Path $reqFile -Encoding ascii
    Write-Host "  -> asked the elevated helper to run '$Action' (waiting up to ${TimeoutSeconds}s)..." -ForegroundColor DarkCyan
    $elapsed = 0
    while (-not (Test-Path $respFile) -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 1
        $elapsed++
    }
    if (-not (Test-Path $respFile)) {
        Write-Host "  TIMEOUT waiting for the elevated helper." -ForegroundColor Red
        Write-Host "  Is run-e2e-suite-elevated-helper.ps1 running in its own elevated window?" -ForegroundColor Red
        return $null
    }
    $resp = Get-Content $respFile -Raw | ConvertFrom-Json
    Remove-Item $respFile -Force -ErrorAction SilentlyContinue
    return $resp
}

# Reads daemon.log through the elevated helper's "read-daemon-log" action --
# C:\ProgramData\ZscalerAIProtect is SYSTEM/Administrators-only, so this
# non-elevated window can't read it directly (see the helper's SECURITY NOTE).
# Returns an array of matching lines (possibly empty), never throws.
function Read-DaemonLog {
    param([string]$Pattern = "", [int]$Tail = 0, [int]$TimeoutSeconds = $ElevatedTimeoutSeconds)
    $id       = [guid]::NewGuid().ToString()
    $reqFile  = "$testDir\elevated-request.json"
    $respFile = "$testDir\elevated-response-$id.json"
    @{ id = $id; action = "read-daemon-log"; pattern = $Pattern; tail = $Tail } |
        ConvertTo-Json | Set-Content -Path $reqFile -Encoding ascii
    $elapsed = 0
    while (-not (Test-Path $respFile) -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 1
        $elapsed++
    }
    if (-not (Test-Path $respFile)) {
        Write-Host "  [read-daemon-log] TIMEOUT waiting for the elevated helper." -ForegroundColor Red
        return @()
    }
    $resp = Get-Content $respFile -Raw | ConvertFrom-Json
    Remove-Item $respFile -Force -ErrorAction SilentlyContinue
    if (-not $resp.ok) {
        Write-Host "  [read-daemon-log] $($resp.note)" -ForegroundColor Yellow
        return @()
    }
    return @($resp.lines)
}

# The service reporting RUNNING (what sc-start's own 20s wait confirms) is
# NOT the same as the LLM proxy actually being ready: --llm-proxy still has
# to authenticate and register with the backend before binding :8788, which
# this session has seen take anywhere from a few seconds to ~25s on top of
# the service coming up. Every step that restarts the service and then
# immediately needs the proxy (11, 12, 13) hit this same race until fixed
# one at a time -- this is the shared fix, not another one-off.
function Wait-ForPort8788 {
    param([int]$TimeoutSeconds = 30)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Seconds 3
        $elapsed += 3
        Write-Host ("  +{0,2}s  still waiting for :8788" -f $elapsed)
    }
    return $false
}

# Returns whether the phase script itself reported success. Every phase
# script this suite calls now ends with an explicit `exit 0`/`exit 1`
# reflecting its own VERDICT (added specifically so this signal is real, not
# guessed from console output). Reset $LASTEXITCODE before invoking: a
# script invoked via `& $script` only overwrites it if it calls `exit`
# itself, so without this reset, a script that somehow fell through without
# exiting would silently inherit and report an unrelated PRIOR command's
# exit code instead of a trustworthy default.
function Run-Phase {
    param([string]$Name)
    $script = "$repoRoot\commands\$Name"
    if (-not (Test-Path $script)) {
        Write-Host "  MISSING: $script -- skipping this step" -ForegroundColor Red
        return $false
    }
    $global:LASTEXITCODE = 0
    # Pipe away the phase script's own pipeline output (Out-Null), not just
    # its console text: PowerShell functions return their ENTIRE pipeline
    # output, not just what follows `return`, so anything the phase script
    # writes to the success stream (e.g. phase-a-acl.ps1's Format-Table,
    # which emits formatted objects there -- Write-Host does NOT, it bypasses
    # the pipeline) would otherwise get bundled in with the trailing
    # boolean below, turning this function's actual return value into an
    # array instead of the clean boolean callers now depend on.
    & $script | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# =============================================================================
Write-Host "AI BROKER WINDOWS E2E SUITE" -ForegroundColor Green
Write-Host "repo: $repoRoot" -ForegroundColor Green
Write-Host "transcript: $transcript" -ForegroundColor Green

# ---- Preflight --------------------------------------------------------------
Show-Step -Num 0 -Item "Preflight: session, mock device plane, elevated helper" `
    -Components @("this window (umesh, non-elevated)", "ai-protect daemon (not started yet)") `
    -Why "Every later step assumes umesh is the ACTIVE console session (not just logged in) and the mock device plane is reachable on :8080 -- both are the two things that silently invalidate a whole run if wrong."

# ---- Stale-state cleanup -----------------------------------------------
# The e2e-suite's own state (this run's, or a prior run's that crashed or
# was Ctrl-C'd) can leak across runs, since nothing here starts from a fresh
# VM every time. Fixing ai_broker.enabled below covers the mock; this covers
# everything else that's bitten this session: a stray broker/proxy process
# from an aborted run squatting on :8788 (racing the real one Step 2 starts),
# a leftover sandbox test directory whose OWN cleanup never ran because the
# run stopped before reaching it, and a stale elevated-request.json that the
# helper (if restarted fresh) would process as real work the instant it starts.
Write-Host "=== stale-state cleanup ===" -ForegroundColor Cyan
# ai-broker-mon runs as umesh -- killable from this non-elevated window.
# zscaler-ai-protect runs as SYSTEM under the service; a non-elevated
# Stop-Process on it would just fail silently (access denied), which would
# be misleading to report as "killed" -- its lifecycle belongs to Step 1's
# elevated sc-stop, not this cleanup pass.
$strayProcs = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
if ($strayProcs) {
    Write-Host "  killing stray ai-broker-mon process(es) from a prior run:" -ForegroundColor Yellow
    $strayProcs | Select-Object Id, ProcessName | Format-Table -AutoSize | Out-Host
    $strayProcs | Stop-Process -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  no stray ai-broker-mon processes" -ForegroundColor Green
}
foreach ($stale in @("$testDir\elevated-request.json", "$testDir\protocol-mismatch-sandbox", "$testDir\cfgapply")) {
    if (Test-Path $stale) {
        Write-Host "  removing stale $stale" -ForegroundColor Yellow
        Remove-Item $stale -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Get-ChildItem "$testDir\elevated-response-*.json" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== active session ===" -ForegroundColor Cyan
query user
$me = $env:USERNAME
Write-Host "running as: $me" -ForegroundColor $(if ($me -ieq "umesh") { "Green" } else { "Yellow" })
if ($me -ine "umesh") {
    Write-Host "WARNING: this suite is written for the console user 'umesh' -- several path constants below assume that account. Adjust `$home_` at the top if this VM uses a different one." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== mock device plane (:8080) ===" -ForegroundColor Cyan
# Starts (or restarts) the mock fresh, serving known-good defaults --
# AI_BROKER_ENABLED=1 in particular, since the daemon's very first heartbeat
# (right after Step 2's service restart, with no state of its own yet) reads
# whatever this is serving at that moment. Kills any existing python.exe
# first: the mock is a long-lived process, so "already up" alone proves
# nothing about what it's currently CONFIGURED to serve -- it could be one
# left over from an earlier run's negative case (enabled=false) that never
# got restored.
function Start-FreshMock {
    Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    $local = "$home_\work\dev_device_plane.py"
    Copy-Item "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" $local -Force -ErrorAction SilentlyContinue
    $env:CONFIG_VERSION = "1"; $env:AI_BROKER_ENABLED = "1"; $env:HEARTBEAT_INTERVAL_SECONDS = "60"
    Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
        -ArgumentList "-u", $local, "--port", "8080" `
        -RedirectStandardOutput "$testDir\device-plane.out" -RedirectStandardError "$testDir\device-plane.err" `
        -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

$health = curl.exe -s http://127.0.0.1:8080/health 2>$null
if ($health -ne "ok") {
    Write-Host "not reachable -- starting it detached (redirected to files, never a console -- an interactive console once froze and wedged the whole daemon pipeline)" -ForegroundColor Yellow
    Start-FreshMock
    $health = curl.exe -s http://127.0.0.1:8080/health 2>$null
    if ($health -ne "ok") { Write-Host "FAILED to bring the mock up -- aborting" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
    Write-Host "mock is up (60s heartbeat cadence -- keeps the rest of this run from waiting on the 600s default)" -ForegroundColor Green
} else {
    Write-Host "already up -- checking what it's actually serving" -ForegroundColor Green
    $cfg = curl.exe -s http://127.0.0.1:8080/endpoint/v1/config 2>$null
    if ($cfg -notmatch '"ai_broker":\s*\{\s*"enabled":\s*true') {
        Write-Host "  BUT ai_broker.enabled is not true ($cfg) -- leftover state from an earlier run's negative case. Restarting fresh." -ForegroundColor Yellow
        Start-FreshMock
        $health = curl.exe -s http://127.0.0.1:8080/health 2>$null
        if ($health -ne "ok") { Write-Host "FAILED to bring the mock back up -- aborting" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
        Write-Host "  mock restarted fresh, ai_broker.enabled=true" -ForegroundColor Green
    } else {
        Write-Host "  confirmed: ai_broker.enabled=true" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== elevated helper reachability ===" -ForegroundColor Cyan
$probe = Invoke-Elevated -Action "sc-query" -TimeoutSeconds 15
if (-not $probe) {
    Write-Host "Cannot reach the elevated helper. Open an elevated window now:" -ForegroundColor Red
    Write-Host '  runas /user:EC2AMAZ-VRAE5E8\administrator powershell.exe' -ForegroundColor Yellow
    Write-Host "then in it:" -ForegroundColor Red
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$repoRoot\commands\run-e2e-suite-elevated-helper.ps1`"" -ForegroundColor Yellow
    Write-Host "and re-run this script." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host "elevated helper is reachable" -ForegroundColor Green

# ---- Step 0: fresh deploy -----------------------------------------------
Show-Step -Num 1 -Item "Step 0 -- fresh deploy: copy the freshly-built binaries onto the VM" `
    -Components @("ai-protect daemon (root/LocalSystem)", "ai-broker-mon --control (console user)") `
    -Why "Everything below tests THIS binary pair, not whatever was already on disk -- a stale-copy false negative burned real debugging time before hash-verification became mandatory." `
    -Destructive -Restores "stops the service first (via the elevated helper) so the copy isn't blocked by a file-in-use daemon/broker" `
    -Anchors "boot-1-spawn-broker"

$null = Invoke-Elevated -Action "sc-stop"
Copy-Item "\\tsclient\Z\target\release\zscaler-ai-protect.exe" "$home_\work\zscaler-ai-protect.exe" -Force -ErrorAction SilentlyContinue
Copy-Item "\\tsclient\Z\target\release\ai-broker-mon.exe" "$home_\work\ai-broker-mon.exe" -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$home_\.ai-broker\config" -Force | Out-Null
Copy-Item "\\tsclient\Z\ai-gateway\config\*" "$home_\.ai-broker\config\" -Force -ErrorAction SilentlyContinue
$deployOk = (Test-Path "$home_\work\zscaler-ai-protect.exe") -and (Test-Path "$home_\work\ai-broker-mon.exe")
if ($deployOk) {
    $dHash = (Get-FileHash "$home_\work\zscaler-ai-protect.exe" -Algorithm SHA256).Hash
    $bHash = (Get-FileHash "$home_\work\ai-broker-mon.exe" -Algorithm SHA256).Hash
    Write-Host "  deployed daemon hash: $dHash" -ForegroundColor Green
    Write-Host "  deployed broker hash: $bHash" -ForegroundColor Green
    Record "Step 0 -- fresh deploy" "DONE (see hashes above)"
} else {
    Write-Host "  FAIL: one or both binaries missing after copy -- check the \\tsclient\Z redirection and target\release paths" -ForegroundColor Red
    Record "Step 0 -- fresh deploy" "FAIL -- binary copy did not land" -Pass $false
}

# ---- Step: start the service = Path B ---------------------------------------
Show-Step -Num 2 -Item "Path B -- SYSTEM service crosses the privilege boundary, file protocol converges" `
    -Components @(
        "ai-protect daemon (LocalSystem, session 0)",
        "ai-broker-mon --control (dropped to umesh via CreateProcessAsUserW)",
        "ai-broker-mon --llm-proxy (child of --control, same identity)"
    ) `
    -Messages "broker.json (daemon writes) -> / <- status.json{ready, proxy_base_url} (broker writes)" `
    -Why "This is the whole bootstrap sequence: spawn across the privilege boundary, ai-protect writes the first broker.json, the broker's own child proxy reports listening, and status.json comes back reporting it -- no handshake round-trip, just two files each side ends up watching." `
    -Anchors "boot-1-spawn-broker, watcher-status-file"

$start = Invoke-Elevated -Action "sc-start"
Write-Host ""
Write-Host "=== daemon.log: spawn + status.json readiness ===" -ForegroundColor Cyan
Read-DaemonLog -Pattern "launched ai-broker-mon|could not launch|status.json .. ready" -Tail 60 |
    Select-Object -Last 6
Record "Path B -- full daemon, SYSTEM service, session 0" $(if ($start.ok) { "DONE" } else { "CHECK LOG -- service did not report RUNNING" }) -Pass ([bool]$start.ok)

# ---- Step: privilege-drop verdict -------------------------------------------
Show-Step -Num 3 -Item "Privilege-drop ownership verification" `
    -Components @("ai-protect daemon (expect SI=0, SYSTEM)", "ai-broker-mon --control + --llm-proxy (expect SI=console session, umesh)") `
    -Why "The single most important fact in this whole suite: the daemon stays root/LocalSystem and the broker (both of its processes) runs as the console user, never the other way around."

$ps = Invoke-Elevated -Action "psinfo"
Record "Privilege-drop ownership verification" $(if ($ps.ok) { "DONE (see table above)" } else { "FAIL -- see above" }) -Pass ([bool]$ps.ok)

# ---- Step: TLS + per-install token, against the LIVE Path-B proxy ----------
Show-Step -Num 4 -Item "TLS + per-install-token scheme exercised live" `
    -Components @("ai-broker-mon --llm-proxy (HTTPS, self-minted CA, token-gated)") `
    -Why "The proxy from Path B above is the same code as Path A's -- so its TLS+token behavior can be probed here without a second interactive OIDC round: wrong/missing token must 401, a bare http:// connection must simply fail (no plaintext fallback)."

$tokenPath = "$home_\.ai-broker\llm-proxy.token"
if (Test-Path $tokenPath) {
    $token = (Get-Content $tokenPath -Raw).Trim()
    Write-Host "  token file present ($($token.Length) chars)" -ForegroundColor Green

    # zax.log, not llm-proxy-child.log: the phase-c-protocol-mismatch
    # investigation this session established that --llm-proxy's own tracing
    # (rejected-token warnings included) lands in zax.log -- the same file
    # the --control parent writes to -- while llm-proxy-child.log has been
    # empty in every diagnostic dump taken all session. Reading the wrong
    # file here meant rejectedDelta could only ever read 0, silently
    # defeating the one check that could tell "right token passed the local
    # gate" apart from "right token was wrongly rejected by it" (both come
    # back 401 from curl either way). zax.log lives under $home_\.ai-broker
    # (umesh's own home, never SYSTEM-locked like daemon.log), so this
    # window can still read it directly, no elevated helper needed.
    $llmProxyLog = "$home_\.ai-broker\logs\zax.log"
    $rejectedPattern = "missing or incorrect access token"
    $rejectedBefore = (Select-String -Path $llmProxyLog -Pattern $rejectedPattern -ErrorAction SilentlyContinue | Measure-Object).Count

    $codeRight = curl.exe -k -s -o NUL -w "%{http_code}" "https://127.0.0.1:8788/$token/v1/responses" -X POST -H "content-type: application/json" -d "{}"
    $codeWrong = curl.exe -k -s -o NUL -w "%{http_code}" "https://127.0.0.1:8788/wrong-token/v1/responses" -X POST -H "content-type: application/json" -d "{}"
    $codeMissing = curl.exe -k -s -o NUL -w "%{http_code}" "https://127.0.0.1:8788/v1/responses" -X POST -H "content-type: application/json" -d "{}"
    Write-Host "  right token  -> HTTP $codeRight   (expect NOT 401 -- reaches the upstream auth check instead)"
    Write-Host "  wrong token  -> HTTP $codeWrong   (expect 401)" -ForegroundColor $(if ($codeWrong -eq "401") { "Green" } else { "Red" })
    Write-Host "  no token     -> HTTP $codeMissing   (expect 401)" -ForegroundColor $(if ($codeMissing -eq "401") { "Green" } else { "Red" })

    Start-Sleep -Milliseconds 500  # let the child's log line land before re-reading
    $rejectedAfter = (Select-String -Path $llmProxyLog -Pattern $rejectedPattern -ErrorAction SilentlyContinue | Measure-Object).Count
    $rejectedDelta = $rejectedAfter - $rejectedBefore
    Write-Host "  local gate rejections this run: $rejectedDelta (expect 2 -- wrong + missing only)" `
        -ForegroundColor $(if ($rejectedDelta -eq 2) { "Green" } elseif ($rejectedDelta -ge 3) { "Red" } else { "Yellow" })
    if ($codeRight -eq "401") {
        if ($rejectedDelta -ge 3) {
            Write-Host "  -> right token was rejected by the LOCAL gate itself -- real bug in strip_token_prefix (llm_leg.rs)" -ForegroundColor Red
        } else {
            Write-Host "  -> right token passed the local gate; the 401 came from further downstream (likely the real upstream LLM API -- no real credential is configured in this test env)" -ForegroundColor Yellow
        }
    }

    $plain = curl.exe -s -o NUL -w "%{http_code}" --max-time 5 "http://127.0.0.1:8788/$token/v1/responses" -X POST -d "{}" 2>$null
    # curl's own convention: "000" means no HTTP response was received at all (refused/reset/
    # timeout) -- that IS the expected, correct outcome here (no plaintext fallback). The old
    # check treated any non-empty string, including the literal "000", as "got a response" and
    # flagged it red -- a false positive that misread curl's own success signal as a failure.
    $noPlaintextResponse = (-not $plain) -or ($plain -eq "000")
    Write-Host "  plain http:// (no TLS) -> $(if ($noPlaintextResponse) { "no response / connection refused (expected)" } else { "HTTP $plain (unexpected -- should not speak plaintext)" })" -ForegroundColor $(if ($noPlaintextResponse) { "Green" } else { "Red" })
    $step4Pass = ($codeWrong -eq "401") -and ($codeMissing -eq "401") -and ($rejectedDelta -lt 3)
    Record "TLS + per-install-token scheme exercised live" $(
        if ($rejectedDelta -ge 3) { "FAIL -- right token rejected by the local gate itself (see strip_token_prefix)" }
        elseif ($step4Pass) { "DONE" }
        else { "CHECK ABOVE" }
    ) -Pass $step4Pass
} else {
    Write-Host "  token file not found yet at $tokenPath -- proxy may still be starting; re-run this step in a moment" -ForegroundColor Yellow
    Record "TLS + per-install-token scheme exercised live" "SKIPPED (token file not ready)"
}

# ---- Step: unit suites --------------------------------------------------
Show-Step -Num 5 -Item "Unit suites green on Windows (ai-warden, ai-broker-mon)" `
    -Components @("build tree at $repoRoot") `
    -Why "Regression coverage for fixes #1/#2 and everything else touched this session. Split non-elevated/elevated because 8 permission_apply tests + one app_capture test need SeRestorePrivilege and are guarded to skip cleanly without it -- see the runbook's `"Elevation is not a single axis`" callout." `
    -Destructive:$false

$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if ($cargo) {
    Write-Host "=== non-elevated: cargo test -p ai-warden --lib ===" -ForegroundColor Cyan
    Push-Location $repoRoot
    cargo test -p ai-warden --lib
    $neCode = $LASTEXITCODE
    Write-Host ""
    Write-Host "=== ai-broker-mon: cargo test -p ai-broker-mon --bin ai-broker-mon ===" -ForegroundColor Cyan
    cargo test -p ai-broker-mon --bin ai-broker-mon
    $monCode = $LASTEXITCODE
    Pop-Location
    Write-Host ""
    Write-Host "=== elevated pass (the 9 skip-guarded tests) ===" -ForegroundColor Cyan
    $elevated = Invoke-Elevated -Action "cargo-test-elevated" -TimeoutSeconds 300
    $step5Pass = ($neCode -eq 0 -and $monCode -eq 0 -and [bool]$elevated.ok)
    Record "Unit suites green on Windows" $(if ($step5Pass) { "DONE" } else { "CHECK OUTPUT ABOVE" }) -Pass $step5Pass
} else {
    Write-Host "  cargo not found on this box -- this VM only received built .exe files, not the toolchain. Skipping (run the unit suites from the laptop instead)." -ForegroundColor Yellow
    Record "Unit suites green on Windows" "SKIPPED (no cargo on this VM)"
}

# ---- Step: secure_file ACL spot check ---------------------------------------
Show-Step -Num 6 -Item "secure_file owner-only DACL (llm-proxy.token, .credentials.json, mitm-ca-key.pem) + owner re-confirms the privilege drop" `
    -Components @("ai-broker-mon --control / --llm-proxy (the writer, as umesh)") `
    -Why "Read-only ACL/owner inspection of files the broker wrote as the dropped-to console user -- run as umesh on purpose: a file's OWNER always gets READ_CONTROL for free, which is what makes umesh (not Administrator) the identity guaranteed to read these descriptors correctly."
$step6Pass = Run-Phase "phase-a-acl.ps1"
Record "secure_file owner-only DACL" "see PASS/FAIL lines above, per file" -Pass $step6Pass

# ---- Step: credential refresh, edge-triggered off status.json ---------------
Show-Step -Num 7 -Item "Credential refresh, live (edge-triggered, no flag file anymore)" `
    -Components @("ai-broker-mon --control (recomputes status.json.credential_requested every tick)", "ai-protect daemon (polls status.json, refetches + rewrites broker.json on false->true)") `
    -Messages "status.json{credential_requested: true} -> ... -> broker.json{credential: ...} (rewritten)" `
    -Why "Proves the edge-trigger actually fires end to end: ages the cached user-JWT sidecar directly (there's no flag file to touch anymore -- credential_requested is a pure function of the sidecar's expiry), and confirms ai-protect notices the flip and rewrites broker.json, even though the pushed credential itself is still empty (zax_user_credential::fetch is still a daemon-side stub)." `
    -Anchors "watcher-status-file"
$step7Pass = Run-Phase "phase-b-cred-watcher.ps1"
Record "Credential refresh, live" "see VERDICT line above" -Pass $step7Pass

# ---- Step: config-delta apply, live -----------------------------------------
Show-Step -Num 8 -Item "Config-delta apply, live (status.json ConfigDelta, no ZIP anymore)" `
    -Components @("ai-broker-mon --control (reports a ConfigDelta in status.json)", "ai-protect daemon (merges it into the real file, writes as the owning user)") `
    -Why "Exercises the Windows ownership reassignment (SetSecurityInfo) inside write_atomic_under that unit tests can only SKIP without SeRestorePrivilege -- this daemon runs elevated for real, so it's the one place this path genuinely executes. Also re-proves the allowlist: a delta naming .ssh/authorized_keys must be refused, not written -- since no real adapter ever emits one, this half hand-crafts status.json directly to exercise the defense." `
    -Destructive -Restores "backs up and restores the real .codex\config.toml itself; the negative case briefly stops ai-broker-mon and forces a respawn afterward" `
    -Anchors "watcher-status-file"
$step8Pass = Run-Phase "phase-b-config-apply.ps1"
Record "Config-delta apply, live" "see PASS/FAIL lines above" -Pass $step8Pass

# ---- Step: MCP stdio relay ---------------------------------------------------
Show-Step -Num 9 -Item "MCP leg -- ai-broker-mon --mcp-server stdio relay" `
    -Components @("ai-broker-mon --mcp-server (spawned directly here, standing in for an agent)") `
    -Why "The Codex CLI isn't installed on this VM, so the relay is driven directly over its newline-JSON-RPC stdio -- the same protocol an agent would use. --mcp-server had zero prior Windows coverage before this test existed." `
    -Destructive:$false

Write-Host "  running with a 60s watchdog: the runbook itself documents a real hang risk here (interactive OIDC on an aged-out cached credential)." -ForegroundColor Yellow
$job = Start-Job -ScriptBlock { & "$using:repoRoot\commands\phase-c-mcp-stdio.ps1" }
if (Wait-Job $job -Timeout 60) {
    Receive-Job $job
    # phase-c-mcp-stdio.ps1 doesn't set an exit code today (it only prints
    # per-check PASS lines), so completing within the timeout is the only
    # signal available -- a real regression, matching every other step here,
    # would need that script to exit non-zero too.
    Record "MCP leg -- --mcp-server stdio relay" "see checks above"
} else {
    Write-Host "  TIMED OUT after 60s -- likely stuck on interactive OIDC (a hang IS itself a finding for a mode an agent spawns non-interactively). Killing the job." -ForegroundColor Red
    Stop-Job $job
    Receive-Job $job
    Record "MCP leg -- --mcp-server stdio relay" "TIMEOUT (see zax.log for an OIDC prompt)" -Pass $false
}
Remove-Job $job -Force -ErrorAction SilentlyContinue

# ---- Negative case: broker.json protocol_version mismatch ------------------
# Deliberately OUTSIDE the -SkipDestructive gate below: unlike the old
# version of this test (which swapped the live broker.exe for a specially
# rebuilt one), this one only ever touches its own throwaway sandbox process
# and directory -- the live AiBrokerTest service is never stopped, copied
# over, or otherwise affected, so there is nothing here for -SkipDestructive
# to actually protect against.
Show-Step -Num 10 -Item "Negative case -- broker.json protocol_version mismatch refuses cleanly" `
    -Components @("a throwaway, isolated ai-broker-mon --control (own scratch ZAX_DEMO_HOME) -- the live service is never touched") `
    -Messages "broker.json{protocol_version: 999} -> status.json{ready: false, message: `"protocol version mismatch...`", agents: []}" `
    -Why "PROTOCOL_VERSION used to live in a shared crate BOTH binaries linked, so testing a mismatch meant building and hash-swapping a whole second broker.exe. BROKER_PROTOCOL_VERSION now lives on BrokerFile itself (ai_types::broker) -- a mismatch is now just writing the wrong number into broker.json by hand, no rebuild, no elevation, no touching the live service at all. Also proves the WHOLE snapshot is dropped (agents[] stays empty), not just the version field ignored -- and that the same sandbox recovers cleanly the instant a correctly-versioned broker.json lands."

$step10Pass = Run-Phase "phase-c-protocol-mismatch.ps1"
Record "Protocol-version mismatch negative case" "see VERDICT line above" -Pass $step10Pass

if ($SkipDestructive) {
    Write-Host ""
    Write-Host "=== -SkipDestructive set: skipping enabled=false / watchdog / --recover ===" -ForegroundColor Yellow
    Record "ai_broker.enabled=false transition" "SKIPPED (-SkipDestructive)"
    Record "Parent-death watchdog" "SKIPPED (-SkipDestructive)"
    Record "Graceful proxy shutdown" "SKIPPED (-SkipDestructive)"
    Record "--recover" "SKIPPED (-SkipDestructive)"
} else {

    # ---- Negative case: ai_broker.enabled=false transition ------------------
    Show-Step -Num 11 -Item "Negative case -- ai_broker.enabled=false stops a LIVE broker" `
        -Components @("ai-protect daemon (settings.received -> reconcile())", "ai-broker-mon --control + --llm-proxy (both torn down)") `
        -Why "Tests the enabled->disabled TRANSITION, not just a fresh start with the toggle off -- the daemon must reap and stop an already-running broker on the very next settings frame that disables it." `
        -Destructive -Restores "bumps CONFIG_VERSION again with enabled=1 at the end, so the broker comes back up before this script continues"

    $step11SetupPass = Run-Phase "phase-c-negative-setup.ps1"
    Write-Host "  restarting the service so it adopts the fast (60s) heartbeat..." -ForegroundColor DarkCyan
    $null = Invoke-Elevated -Action "sc-stop"
    $null = Invoke-Elevated -Action "sc-start"
    $step11FlipPass = Run-Phase "phase-c-negative-flip.ps1"

    Write-Host "  restoring: enabled=1, version bumped again, so the rest of this run has a live broker..." -ForegroundColor DarkCyan
    Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $env:CONFIG_VERSION = "3"; $env:AI_BROKER_ENABLED = "1"; $env:HEARTBEAT_INTERVAL_SECONDS = "60"
    Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
        -ArgumentList "-u", "$home_\work\dev_device_plane.py", "--port", "8080" `
        -RedirectStandardOutput "$testDir\device-plane.out" -RedirectStandardError "$testDir\device-plane.err" -WindowStyle Hidden

    # Poll rather than a fixed sleep: the daemon is still on the 60s heartbeat
    # cadence from setup above, so a broker respawn can legitimately take just
    # under a full 60s interval plus the first broker.json write's own budget
    # (spawn + proxy start) -- a flat 15s wait
    # left the broker down when the NEXT step (parent-death watchdog) needs it
    # alive, making that step fail for a reason unrelated to what it tests.
    Write-Host "  waiting up to 90s for the daemon's next heartbeat to respawn the broker..." -ForegroundColor DarkCyan
    $processUp = $false
    for ($i = 1; $i -le 18; $i++) {
        Start-Sleep -Seconds 5
        if (Get-Process ai-broker-mon -ErrorAction SilentlyContinue) { $processUp = $true; break }
        Write-Host ("  +{0,3}s  still waiting for the process" -f ($i * 5))
    }
    # A process named ai-broker-mon existing is NOT the same as it being
    # actually ready: that's the --control parent, whose own --llm-proxy
    # CHILD still has to spawn, authenticate, and register with the backend
    # before it binds :8788 -- which this session has seen take anywhere from
    # a few seconds to ~25s across several attempts. The very next step
    # (parent-death watchdog) needs the proxy already listening, so wait for
    # the port too, not just the process, before declaring this restored.
    $portUp = $false
    if ($processUp) {
        Write-Host "  process is up -- waiting up to 30s more for the LLM proxy to bind :8788..." -ForegroundColor DarkCyan
        for ($i = 1; $i -le 10; $i++) {
            if (Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue) { $portUp = $true; break }
            Start-Sleep -Seconds 3
            Write-Host ("  +{0,2}s  still waiting for :8788" -f ($i * 3))
        }
    }
    $respawned = $processUp -and $portUp
    $step11Pass = $step11SetupPass -and $step11FlipPass -and $respawned
    if ($respawned) {
        Write-Host "  broker respawned and :8788 is listening" -ForegroundColor Green
        Record "ai_broker.enabled=false transition" "see VERDICT line above; restored to enabled afterward" -Pass $step11Pass
    } elseif ($processUp) {
        Write-Host "  broker process is up but :8788 never bound -- later steps that need a live proxy will likely fail" -ForegroundColor Red
        Record "ai_broker.enabled=false transition" "see VERDICT line above; RESTORE FAILED -- process up but proxy never bound" -Pass $step11Pass
    } else {
        Write-Host "  broker did NOT respawn within 90s -- later steps that need a live broker will likely fail" -ForegroundColor Red
        Record "ai_broker.enabled=false transition" "see VERDICT line above; RESTORE FAILED -- broker still down after 90s" -Pass $step11Pass
    }

    # ---- Parent-death watchdog ------------------------------------------------
    Show-Step -Num 12 -Item "Parent-death watchdog (orphan guard)" `
        -Components @("ai-broker-mon --control (killed)", "ai-broker-mon --llm-proxy (must notice and exit on its own)") `
        -Why "Before commit f5c3e367 there was no Windows watchdog at all -- an orphaned proxy would squat on port 8788 until someone killed it by hand. This kills ONLY the control process and checks the proxy child exits within seconds." `
        -Destructive -Restores "restarts the service afterward via the elevated helper"
    $step12Pass = Run-Phase "phase-c-watchdog.ps1"
    Write-Host "  restarting the service (the watchdog test intentionally kills the broker)..." -ForegroundColor DarkCyan
    $null = Invoke-Elevated -Action "sc-stop"
    $r = Invoke-Elevated -Action "sc-start"
    Write-Host "  waiting for the proxy to rebind :8788 before the next step needs it..." -ForegroundColor DarkCyan
    $step12PortUp = Wait-ForPort8788 -TimeoutSeconds 30
    Record "Parent-death watchdog" "see VERDICT line above; service restarted" -Pass ($step12Pass -and [bool]$r.ok -and $step12PortUp)

    # ---- Graceful proxy shutdown ----------------------------------------------
    Show-Step -Num 13 -Item "Graceful proxy shutdown" `
        -Components @("ai-broker-mon --llm-proxy (stop -> shutdown-flag drain -> restart -> rebind)") `
        -Why "Evidenced rather than directly instrumented: a proxy that shut down ungracefully would leave port 8788 orphaned/held, and the restarted proxy would fail to bind it. A clean stop/start cycle that successfully rebinds is the observable proof." `
        -Destructive -Restores "this IS a stop/start cycle -- ends with the service running again"
    $before = [bool](Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue)
    Write-Host "  8788 listening before stop: $before"
    $null = Invoke-Elevated -Action "sc-stop"
    $duringPort = [bool](Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue)
    Write-Host "  8788 listening after stop : $duringPort   (expect false -- released cleanly)" -ForegroundColor $(if (-not $duringPort) { "Green" } else { "Red" })
    $r = Invoke-Elevated -Action "sc-start"
    $after = Wait-ForPort8788 -TimeoutSeconds 30
    Write-Host "  8788 listening after start: $after   (expect true -- rebind succeeded, so the previous child didn't orphan it)" -ForegroundColor $(if ($after) { "Green" } else { "Red" })
    $step13Pass = (-not $duringPort) -and $after
    Record "Graceful proxy shutdown" $(if ($step13Pass) { "DONE" } else { "CHECK ABOVE" }) -Pass $step13Pass

    # ---- --recover ---------------------------------------------------------
    Show-Step -Num 14 -Item "-- recover -- stray-process cleanup + config strip (THE LAST DESTRUCTIVE TEST)" `
        -Components @("ai-broker-mon --control + --llm-proxy (both killed by the toolhelp32 sweep)", "the agent's config file (its [mcp_servers.zax] entry stripped)", "ai-protect daemon (must respawn the broker once a NEW settings frame arrives -- not on any timer)") `
        -Messages "codex's [mcp_servers.zax] stripped from config.toml directly, then re-wired later via a fresh status.json ConfigDelta once respawned" `
        -Why "Runs a dry-run first (must change NOTHING), then the real run, then deliberately proves the self-heal GAP the runbook found: reconcile() -- the only reap+respawn path -- has exactly one call site (on_settings_received), so the broker stays dead until a genuinely new config_version arrives, never on a timer alone. The script forces that new frame at the end so the box is never left mid-teardown." `
        -Destructive -Restores "self-restoring: forces a fresh settings frame at the end so the broker respawns and re-wires codex automatically"
    $step14Pass = Run-Phase "phase-d-recover.ps1"
    Record "--recover" "see PASS/FAIL + FINAL snapshot above" -Pass $step14Pass
}

# ---- Excluded from this run: nobody-logged-on, reboot -----------------------
Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkGray
Write-Host "NOT RUN BY THIS SCRIPT (see the header for why):" -ForegroundColor Yellow
Write-Host "  - Negative case: nobody logged on -- needs a real RDP logoff of THIS session." -ForegroundColor Yellow
Write-Host "    Run by hand: commands\phase-e-nobody-setup2.ps1 (elevated) then log off and" -ForegroundColor Yellow
Write-Host "    follow with phase-e-nobody-check2.ps1 after logging back in." -ForegroundColor Yellow
if ($IncludeReboot) {
    Write-Host ""
    Write-Host "=== -IncludeReboot passed: rebooting this VM now ===" -ForegroundColor Red
    Write-Host "After it comes back: log in as umesh, then run commands\phase-b-prep.ps1" -ForegroundColor Yellow
    Write-Host "followed by commands\phase-b-verify.ps1 to confirm the privilege drop survived." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    Restart-Computer -Force
} else {
    Write-Host "  - Privilege-drop survives a reboot -- pass -IncludeReboot to this script to" -ForegroundColor Yellow
    Write-Host "    actually restart this VM, or run commands\phase-b-prep.ps1 / -verify.ps1 by hand after a manual reboot." -ForegroundColor Yellow
}

# ---- Summary -----------------------------------------------------------
Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkGray
Write-Host "SUMMARY" -ForegroundColor Green
Write-Host ("=" * 78) -ForegroundColor DarkGray
$results | Format-Table -AutoSize -Wrap
Write-Host ""
Write-Host "Full transcript: $transcript" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
