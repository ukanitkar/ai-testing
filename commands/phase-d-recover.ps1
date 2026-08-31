# Phase D -- --recover: reverse the bootstrap's config edits + kill stray
# ai-broker-mon processes. Run in the REGULAR umesh window.
#
# No elevation needed: PROCESS_TERMINATE against a same-user process succeeds
# without it (recover.rs's windows_proc::terminate opens with just that one
# right), and this must run as the SAME user the live broker ran as so
# paths::resolve_home() resolves to the same ~/.ai-broker (do NOT set
# ZAX_DEMO_HOME here -- that would point --recover at a different home than
# the one the live broker actually used).
#
# THIS IS THE LAST DESTRUCTIVE TEST. It strips codex's [mcp_servers.zax] entry
# and deletes the cached-JWT sidecar by default (--keep-credentials opts out,
# not used here), so anything reconnecting afterward needs a fresh OIDC round.
# The script itself forces and verifies that respawn at the end so the box is
# left healthy rather than stopping mid-teardown.
#
# ALSO TESTS A STRUCTURAL QUESTION, decided by reading the code before running
# anything: ai_broker_launch::reconcile() -- the ONLY place that reaps a dead
# broker and respawns it -- has EXACTLY ONE call site in the whole source tree,
# inside on_settings_received. The periodic scan-tick handler (on_agent_rescan)
# only checks `guard.is_some()`, never has_exited(). So killing the broker
# externally (exactly what --recover does) should leave it dead until the
# daemon receives a genuinely NEW settings frame (a config_version bump) --
# not on any timer, no matter how long you wait. Verified empirically below
# rather than trusted from the reading alone.

$exe     = "C:\Users\umesh\work\ai-broker-mon.exe"
$codex   = "C:\Users\umesh\.codex\config.toml"
$cred    = "C:\Users\umesh\.ai-broker\.credentials.json"
$local   = "C:\Users\umesh\work\dev_device_plane.py"
$testDir = "C:\ai-broker-test"

# daemon.log lives under C:\ProgramData\ZscalerAIProtect, which is
# SYSTEM/Administrators-only (windows_security::allow_system_admins_traverse_only)
# -- this REGULAR umesh window can't read it directly, so route through the
# elevated helper's "read-daemon-log" action instead. Standalone copy of
# run-e2e-suite.ps1's Read-DaemonLog: this script runs as its own process
# (`& $script`), not dot-sourced, so it has no access to that scope.
function Read-DaemonLog {
    param([string]$Pattern = "", [int]$Tail = 0, [int]$TimeoutSeconds = 20)
    $id       = [guid]::NewGuid().ToString()
    $reqFile  = "$testDir\elevated-request.json"
    $respFile = "$testDir\elevated-response-$id.json"
    @{ id = $id; action = "read-daemon-log"; pattern = $Pattern; tail = $Tail } |
        ConvertTo-Json | Set-Content -Path $reqFile -Encoding ascii
    $elapsed = 0
    while (-not (Test-Path $respFile) -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
    }
    if (-not (Test-Path $respFile)) {
        Write-Host "  [read-daemon-log] TIMEOUT -- is run-e2e-suite-elevated-helper.ps1 running?" -ForegroundColor Red
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

function Snapshot($label) {
    Write-Host ""
    Write-Host "=== $label ===" -ForegroundColor Cyan
    $procs = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
    if ($procs) { $procs | Select-Object Id, SI | Format-Table -AutoSize }
    else { Write-Host "  no ai-broker-mon processes" }
    $port = Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue
    Write-Host "  port 8788 listening: $([bool]$port)"
    if (Test-Path $codex) {
        $has = (Get-Content $codex -Raw) -match "mcp_servers\.zax"
        Write-Host "  codex config has [mcp_servers.zax]: $has"
    } else {
        Write-Host "  codex config.toml absent"
    }
    Write-Host "  credentials sidecar present: $(Test-Path $cred)"
}

Snapshot "BEFORE"
$beforeCodexHasZax = (Test-Path $codex) -and ((Get-Content $codex -Raw) -match "mcp_servers\.zax")
$beforeCredPresent = Test-Path $cred

# --recover deletes the cached-JWT sidecar by default (this header's own
# words: "anything reconnecting afterward needs a fresh OIDC round") --
# meaning without a backup, the respawn this script forces later would need
# a REAL browser-based OIDC login to ever bind :8788 again, which nothing
# here can complete unattended. Back it up now so it can go back right
# before the respawn: this doesn't weaken the delete-path assertions below
# ($credOk etc. are checked right after the real run, before any restore),
# it just avoids leaving the box needing a human at the very end.
$credBackup = "$testDir\phase-d-recover-cred-backup.json"
if ($beforeCredPresent) { Copy-Item $cred $credBackup -Force }

Write-Host ""
Write-Host "=== DRY RUN (safety pass -- must change nothing) ===" -ForegroundColor Cyan
& $exe --recover --dry-run
$dryExit = $LASTEXITCODE
Write-Host "dry-run exit code: $dryExit"

Snapshot "AFTER DRY RUN (must be IDENTICAL to BEFORE)"
$afterDryCodexHasZax = (Test-Path $codex) -and ((Get-Content $codex -Raw) -match "mcp_servers\.zax")
$afterDryCredPresent = Test-Path $cred
$dryRunClean = ($dryExit -eq 0) -and ($afterDryCodexHasZax -eq $beforeCodexHasZax) -and ($afterDryCredPresent -eq $beforeCredPresent)
if (-not $dryRunClean) {
    Write-Host "  FAIL: dry-run changed state (exit=$dryExit, codex zax before/after=$beforeCodexHasZax/$afterDryCodexHasZax, cred before/after=$beforeCredPresent/$afterDryCredPresent)" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== REAL RUN (kills live broker+proxy, strips codex wiring, drops cached JWT) ===" -ForegroundColor Cyan
& $exe --recover
$realExit = $LASTEXITCODE
Write-Host "recover exit code: $realExit  (0 = fully repaired, 1 = something left unresolved)"

Start-Sleep -Seconds 2
Snapshot "AFTER --recover"

Write-Host ""
Write-Host "=== verifying specific claims ===" -ForegroundColor Cyan
$stillProcs = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
$sweepOk = -not [bool]$stillProcs
Write-Host ("  Toolhelp32 sweep + self-exclusion worked (no ai-broker-mon left): {0}" -f $sweepOk) -ForegroundColor $(if ($sweepOk) { "Green" } else { "Red" })

$credOk = -not (Test-Path $cred)
Write-Host ("  credentials sidecar removed (default -- no --keep-credentials passed): {0}" -f $credOk) -ForegroundColor $(if ($credOk) { "Green" } else { "Red" })

$codexNow = if (Test-Path $codex) { Get-Content $codex -Raw } else { "" }
$codexOk = $codexNow -notmatch "mcp_servers\.zax"
Write-Host ("  codex [mcp_servers.zax] entry removed: {0}" -f $codexOk) -ForegroundColor $(if ($codexOk) { "Green" } else { "Red" })

$portFree = -not (Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue)
Write-Host ("  port 8788 released: {0}" -f $portFree) -ForegroundColor $(if ($portFree) { "Green" } else { "Red" })

Write-Host ""
Write-Host "=== testing the self-healing gap (expect: stays dead for ~90s) ===" -ForegroundColor Cyan
Write-Host "  reconcile() -- the only reap+respawn path -- fires ONLY from" -ForegroundColor Yellow
Write-Host "  on_settings_received (confirmed: exactly one call site in the source)." -ForegroundColor Yellow
Write-Host "  The periodic scan tick only checks guard.is_some(), never has_exited()," -ForegroundColor Yellow
Write-Host "  so it should NOT bring the broker back on its own." -ForegroundColor Yellow
for ($i = 1; $i -le 9; $i++) {
    Start-Sleep -Seconds 10
    $alive = [bool](Get-Process ai-broker-mon -ErrorAction SilentlyContinue)
    Write-Host ("  +{0,3}s  broker_alive={1}" -f ($i * 10), $alive)
}
$stillDead = -not [bool](Get-Process ai-broker-mon -ErrorAction SilentlyContinue)
if ($stillDead) {
    Write-Host "  CONFIRMED: still dead after 90s with no new settings frame -- no periodic self-heal" -ForegroundColor Green
} else {
    Write-Host "  UNEXPECTED: broker came back with no new settings frame -- re-check reconcile() call sites" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== restoring the credential sidecar so the respawned broker skips OIDC ===" -ForegroundColor Cyan
if (Test-Path $credBackup) {
    Copy-Item $credBackup $cred -Force
    Write-Host "  restored $cred from backup" -ForegroundColor Green
} else {
    Write-Host "  no backup to restore (none existed before --recover ran)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== forcing the respawn: bump CONFIG_VERSION so a NEW settings frame arrives ===" -ForegroundColor Cyan
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$env:CONFIG_VERSION             = "4"
$env:AI_BROKER_ENABLED          = "1"
$env:HEARTBEAT_INTERVAL_SECONDS = "60"
Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
    -ArgumentList "-u", $local, "--port", "8080" `
    -RedirectStandardOutput "$testDir\device-plane.out" `
    -RedirectStandardError  "$testDir\device-plane.err" `
    -WindowStyle Hidden
Start-Sleep -Seconds 3
$cfg = curl.exe -s http://127.0.0.1:8080/endpoint/v1/config
Write-Host "  /config now serves: $cfg"

Write-Host "  waiting up to 70s for the daemon's next heartbeat to pick it up..." -ForegroundColor Cyan
$respawned = $false
for ($i = 1; $i -le 14; $i++) {
    Start-Sleep -Seconds 5
    if (Get-Process ai-broker-mon -ErrorAction SilentlyContinue) { $respawned = $true; break }
    Write-Host ("  +{0,3}s  still dead" -f ($i * 5))
}
if ($respawned) {
    Write-Host "  RESPAWNED once a new settings frame arrived" -ForegroundColor Green
    Get-Process ai-broker-mon | Select-Object Id, SI | Format-Table -AutoSize
} else {
    Write-Host "  FAIL: did not respawn even after a version bump" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== final state (polling up to 60s for broker.json/status.json/proxy to settle) ===" -ForegroundColor Cyan
# A process existing (confirmed above) is NOT the same as it being fully up:
# its --llm-proxy child still has to authenticate (now skipped, thanks to
# the restored sidecar) and register with the backend before binding
# :8788, and the config-delta merge that re-wires codex is a SEPARATE tick
# on top of that. This session has seen the full sequence take anywhere
# from a few seconds to ~25s -- a flat 8s wait doesn't give it a fair chance.
$finalRestored = $false
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 3
    $finalCodexHasZax = (Test-Path $codex) -and ((Get-Content $codex -Raw) -match "mcp_servers\.zax")
    $finalCredPresent = Test-Path $cred
    $finalPortListening = [bool](Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue)
    Write-Host ("  +{0,2}s  codex_zax={1}  cred={2}  port_8788={3}" -f ($i * 3), $finalCodexHasZax, $finalCredPresent, $finalPortListening)
    if ($finalCodexHasZax -and $finalCredPresent -and $finalPortListening) { $finalRestored = $true; break }
}
Snapshot "FINAL"
if (-not $finalRestored) {
    Write-Host "  FAIL: box not fully restored (codex zax=$finalCodexHasZax, cred=$finalCredPresent, port=$finalPortListening)" -ForegroundColor Red
}
Write-Host ""
Write-Host "=== daemon log: did the config-delta merge automatically re-wire codex? ===" -ForegroundColor Cyan
Read-DaemonLog -Pattern "launched ai-broker-mon|applied config delta .*for agent 'codex'" -Tail 30 | Select-Object -Last 6

$verdictPass = $dryRunClean -and ($realExit -eq 0) -and $sweepOk -and $credOk -and $codexOk -and $portFree -and $stillDead -and $respawned -and $finalRestored
if (-not $verdictPass) { exit 1 }
exit 0
