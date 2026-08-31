# Phase C, item 2b -- broker.json `protocol_version` mismatch must produce a
# CLEAN refusal. Run in the REGULAR umesh window -- no elevation, and no
# interaction with the live AiBrokerTest service AT ALL. This spins up its
# OWN throwaway `ai-broker-mon --control` pointed at a scratch ZAX_DEMO_HOME,
# so there is nothing here that can leave the box mid-teardown to restore.
#
# WHAT CHANGED FROM THE OLD TEST: PROTOCOL_VERSION used to live in a shared
# `ai-broker/protocol` crate BOTH binaries linked -- constructing a mismatch
# meant building a whole second broker.exe with the constant bumped, hash-
# verifying it, swapping it onto the live service, then restoring. That crate
# is deleted. `BROKER_PROTOCOL_VERSION` now lives on `BrokerFile` itself
# (ai_types::broker) -- a plain JSON field ai-protect writes into broker.json.
# A mismatch is now just... writing the wrong number into broker.json by
# hand. No special build, no hash-verified swap, no service stop/start.
#
# What "clean" means, per agent-manager/src/lib.rs's AgentManager::apply:
#   - logs (to this sandbox's own logs\zax.log): tracing::error! "protocol
#     version mismatch: broker.json vN vs this build vM -- ignoring this
#     snapshot"
#   - returns immediately with StatusFile{ready: false, message: "protocol
#     version mismatch: ...", agents: []} -- the WHOLE snapshot is dropped,
#     not just the version field, so agents[] stays empty even though
#     broker.json also listed one
#   - and recovers cleanly the instant a correctly-versioned broker.json lands
#   - and the process never crashes, either way

$scratch    = "C:\ai-broker-test\protocol-mismatch-sandbox"
$exe        = "C:\Users\umesh\work\ai-broker-mon.exe"
$brokerFile = "$scratch\broker.json"
$statusFile = "$scratch\status.json"
$log        = "$scratch\logs\zax.log"

Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

# --llm-proxy refuses to start without config.yaml AND init.yaml ("Run
# ai-broker-mon (no args) once to bootstrap") -- but the real bootstrap flow
# (bootstrap.rs::do_bootstrap) does far more than write those two files: it
# registers a REAL MCP entry in ~/.claude.json, opens Claude Desktop, and
# runs interactive OIDC. None of that belongs in an isolated sandbox test.
# Both templates it would have written (mon/templates/config.yaml,
# mon/templates/init.yaml) are comment-only by default, so writing that same
# near-empty content directly is the safe, scoped equivalent of the one
# piece of bootstrap this sandbox actually needs.
Set-Content -Path "$scratch\config.yaml" -Value "# bootstrapped for the sandbox test -- see mon/templates/config.yaml`n" -Encoding ascii
# init.yaml is NOT comment-only like config.yaml -- it carries a real,
# load-bearing `cloud: dev` key (SDK default is prod). A dummy placeholder
# here silently defaulted the SDK to prod, which then rejected the demo/alpha
# tenant's token with "Invalid token issuer" against api.zsagentic.ai instead
# of the dev endpoint (api.zsagenticdev.ai) the live broker's own init.yaml
# correctly targets. Copy the real template, not a stand-in for it.
Copy-Item "\\tsclient\Z\ai-gateway\mon\templates\init.yaml" "$scratch\init.yaml" -Force

# A THIRD, DIFFERENT init.yaml: the SDK's own BUNDLED config
# (sdk_config.rs::bundled_yaml_path), holding the real OIDC issuer/client_id
# -- unrelated to the per-user-home one above despite the identical filename.
# It resolves two ways, neither home-relative: env!("CARGO_MANIFEST_DIR")
# (a path baked in on the BUILD machine, meaningless once copied to this
# VM) or std::env::current_dir()/config/init.yaml (this process's CWD). The
# live broker never hits this because the daemon spawns it with
# cwd = bin.parent() (ai_broker_launch.rs); Start-Process below never set
# -WorkingDirectory, so it inherited THIS SHELL's cwd instead, with no
# config/ under it at all. Mirror the live setup: copy the real bundled
# config next to a working directory we control, and pass it explicitly.
$sandboxWorkDir = "$scratch\work"
New-Item -ItemType Directory -Path "$sandboxWorkDir\config" -Force | Out-Null
Copy-Item "\\tsclient\Z\ai-gateway\config\*" "$sandboxWorkDir\config\" -Force -ErrorAction SilentlyContinue

# The sandbox's hand-crafted broker.json always carries credential.available
# = $false, and it has no cached JWT/refresh token of its own (fresh $scratch
# every run) -- so with nothing to fall back on, the SDK's ONLY option is
# "[auth] launching interactive OIDC (last resort)": a real browser popup,
# possibly with MFA, that no script can complete inside a 20-30s window. That
# directly contradicts this test's own premise ("recovers cleanly the INSTANT
# a correctly-versioned broker.json lands") and is why re-running this script
# kept popping the login window instead of ever finishing on its own. Seed a
# cached credential from the live broker's own already-authenticated sidecar
# (this session already completed a real OIDC round for it earlier) so the
# sandbox can do a token REFRESH instead -- no browser, no human, no MFA.
$liveSidecar = "C:\Users\umesh\.ai-broker\.credentials.json"
if (Test-Path $liveSidecar) {
    Copy-Item $liveSidecar "$scratch\.credentials.json" -Force
    Write-Host "  seeded a cached credential from the live broker's sidecar -- avoids interactive OIDC" -ForegroundColor Green
} else {
    Write-Host "  WARNING: no live sidecar at $liveSidecar to seed -- this run will fall through to interactive OIDC (a real browser popup, possibly MFA) and likely won't complete unattended" -ForegroundColor Yellow
}

# Isolate this sandbox instance completely from the live service: its own
# home (so broker.json/status.json/logs all land under $scratch, per
# paths::resolve_home()'s ZAX_DEMO_HOME override) and its own LLM-proxy port
# (AgentManager::apply spawns a proxy unconditionally once past the version
# check -- without this it would fight the live service for :8788).
$env:ZAX_DEMO_HOME       = $scratch
$env:ZAX_LLM_PROXY_PORT  = "18788"

function Write-BrokerJson {
    param([int]$ProtocolVersion, [string[]]$AgentTypes = @())
    $agents = @($AgentTypes | ForEach-Object { @{ agent_type = $_; state = "detected" } })
    $body = @{
        protocol_version = $ProtocolVersion
        credential       = @{ available = $false }
        agents           = $agents
        advisories       = @()
    } | ConvertTo-Json -Depth 6
    Set-Content -Path $brokerFile -Value $body -Encoding ascii
}

function Read-StatusJson {
    if (-not (Test-Path $statusFile)) { return $null }
    for ($i = 0; $i -lt 5; $i++) {
        try { return (Get-Content $statusFile -Raw | ConvertFrom-Json) } catch { Start-Sleep -Milliseconds 300 }
    }
    return $null
}

Write-Host "=== spawning an isolated ai-broker-mon --control (ZAX_DEMO_HOME=$scratch) ===" -ForegroundColor Cyan
$proc = Start-Process -FilePath $exe -ArgumentList "--control" -PassThru -WindowStyle Hidden `
    -WorkingDirectory $sandboxWorkDir `
    -RedirectStandardOutput "$scratch\stdout.log" -RedirectStandardError "$scratch\stderr.log"
Start-Sleep -Seconds 2   # let its watcher start polling before broker.json exists

# ---- phase 1: wrong protocol_version --------------------------------------
Write-Host ""
Write-Host "=== writing broker.json with a deliberately wrong protocol_version ===" -ForegroundColor Cyan
Write-BrokerJson -ProtocolVersion 999 -AgentTypes @("codex")
Write-Host "  wrote $brokerFile (protocol_version=999, plus a codex entry that must be ignored too)"
Start-Sleep -Seconds 4   # one 3s poll tick, plus slack

$status1     = Read-StatusJson
$readyFalse  = [bool]($status1 -and ($status1.ready -eq $false))
$mismatchMsg = [bool]($status1 -and ($status1.message -match "protocol version mismatch"))
$noAgents    = [bool]($status1 -and (@($status1.agents).Count -eq 0))
$aliveAfter1 = [bool](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)

Write-Host ("  status.json.ready == false                                 : {0}" -f $readyFalse)  -ForegroundColor $(if($readyFalse){"Green"}else{"Red"})
Write-Host ("  status.json.message mentions the mismatch                  : {0}" -f $mismatchMsg) -ForegroundColor $(if($mismatchMsg){"Green"}else{"Red"})
Write-Host ("  status.json.agents is EMPTY (snapshot dropped wholesale)   : {0}" -f $noAgents)    -ForegroundColor $(if($noAgents){"Green"}else{"Red"})
Write-Host ("  process still alive (no crash)                             : {0}" -f $aliveAfter1) -ForegroundColor $(if($aliveAfter1){"Green"}else{"Red"})

Write-Host ""
Write-Host "=== the actual broker-side log line ===" -ForegroundColor Cyan
Get-Content $log -Tail 20 -ErrorAction SilentlyContinue | Select-String "protocol version mismatch" | Select-Object -Last 2

# ---- phase 2: correct protocol_version recovers ---------------------------
# Recovery isn't just "the watcher notices the rewrite" (one 3s poll tick,
# like phase 1) -- past the version check, apply() spawns a brand-new
# --llm-proxy child from cold (process creation, TLS CA/cert generation,
# socket bind) and listener::wait_for_llm_proxy() itself allows up to 20s for
# that child to report itself listening. A flat 4s wait here (copy-pasted
# from phase 1, which never spawns anything) checks status.json long before
# the proxy could plausibly be up, and reads as a recovery failure that isn't
# one. Poll instead, generously, the same way the other phase scripts wait
# out a broker respawn.
Write-Host ""
Write-Host "=== writing broker.json again with the CORRECT protocol_version -- must recover ===" -ForegroundColor Cyan
Write-BrokerJson -ProtocolVersion 1

$status2   = $null
$recovered = $false
for ($i = 1; $i -le 9; $i++) {
    Start-Sleep -Seconds 3
    $status2   = Read-StatusJson
    $recovered = [bool]($status2 -and ($status2.ready -eq $true))
    Write-Host ("  +{0,2}s  status.json.ready={1}" -f ($i * 3), $(if ($status2) { $status2.ready } else { "<no status.json>" }))
    if ($recovered) { break }
}

if (-not $recovered) {
    # status.json.message is exactly the diagnostic AgentManager::apply sets
    # for this branch ("failed to spawn local LLM proxy" vs "spawned but did
    # not report listening in time" vs whatever the mismatch left behind) --
    # the poll loop above never printed it, so a FAIL here gave no way to
    # tell which failure mode it was. Dump it plus the sandbox's own process
    # output, since that's the only place a spawn/bind failure would surface.
    Write-Host ""
    Write-Host "=== recovery did not complete -- diagnostics ===" -ForegroundColor Yellow
    Write-Host "  status.json.message: $(if ($status2) { $status2.message } else { '<no status.json at all>' })"
    # $log ($scratch\logs\zax.log) is the --control PARENT's own tracing
    # output -- wait_for_llm_proxy's "proxy child exited before listening"
    # warning, and agent-manager's own tracing::error!/warn! calls, land
    # HERE, not in llm-proxy-child.log (that's the CHILD's redirected
    # stdout/stderr, a separate mechanism). It's been silently empty every
    # attempt so far -- worth seeing directly rather than assumed benign.
    # $log is small (a fresh sandbox each run) and both the --control parent
    # and --llm-proxy child interleave into it -- a 15-line tail already cut
    # off the agent-manager/listener lines that precede the OIDC block once,
    # so show the whole thing for $log specifically rather than guess at a
    # tail size again.
    foreach ($f in @("$scratch\stdout.log", "$scratch\stderr.log", "$scratch\logs\llm-proxy-child.log")) {
        if (Test-Path $f) {
            Write-Host "  --- tail of $f ---"
            Get-Content $f -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Host "  (not present: $f)"
        }
    }
    if (Test-Path $log) {
        Write-Host "  --- full contents of $log ---"
        Get-Content $log -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host "  (not present: $log)"
    }
    # Did the --llm-proxy child even get spawned as an OS process, and is it
    # (or was it) actually bound to the sandbox's isolated port? This
    # distinguishes "never spawned" / "spawned then died" / "spawned, alive,
    # just never bound" -- three different bugs that all look identical from
    # status.json alone.
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
    if ($children) {
        Write-Host "  child process(es) of the sandbox --control (PID $($proc.Id)):"
        $children | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize | Out-Host
    } else {
        Write-Host "  NO child process of PID $($proc.Id) -- --llm-proxy was never spawned as an OS process at all" -ForegroundColor Red
    }
    $sandboxPort = Get-NetTCPConnection -LocalPort 18788 -State Listen -ErrorAction SilentlyContinue
    Write-Host "  port 18788 (sandbox's isolated proxy port) listening: $([bool]$sandboxPort)"
}

$aliveAfter2 = [bool](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)

Write-Host ("  status.json.ready == true once the version is fixed       : {0}" -f $recovered)   -ForegroundColor $(if($recovered){"Green"}else{"Red"})
Write-Host ("  process still alive throughout                             : {0}" -f $aliveAfter2) -ForegroundColor $(if($aliveAfter2){"Green"}else{"Red"})

$verdictPass = $readyFalse -and $mismatchMsg -and $noAgents -and $aliveAfter1 -and $recovered -and $aliveAfter2
Write-Host ""
if ($verdictPass) {
    Write-Host "VERDICT: PASS -- clean refusal on the bad snapshot, clean recovery on the next good one" -ForegroundColor Green
} else {
    Write-Host "VERDICT: FAIL -- see the flags above" -ForegroundColor Red
}

# ---- teardown --------------------------------------------------------------
# Nothing to restore: the live AiBrokerTest service was never stopped,
# copied over, or otherwise touched -- only this sandbox process + directory.
Write-Host ""
Write-Host "=== tearing down the sandbox ===" -ForegroundColor Cyan
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Remove-Item Env:\ZAX_DEMO_HOME -ErrorAction SilentlyContinue
Remove-Item Env:\ZAX_LLM_PROXY_PORT -ErrorAction SilentlyContinue

if (-not $verdictPass) { exit 1 }
exit 0
