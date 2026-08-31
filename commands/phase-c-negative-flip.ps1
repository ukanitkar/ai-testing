# Phase C, item 2a, STEP 3 -- the actual negative test: flip ai_broker.enabled
# to false and confirm the daemon STOPS a running broker on reconcile.
# Run in the REGULAR umesh window, after phase-c-negative-setup.ps1 + the
# service restart (so the 60 s cadence is in effect).
#
# Serving CONFIG_VERSION=2 is what makes the daemon re-read settings at all:
# it only re-fetches /config when the heartbeat advertises a version it does
# not already hold. Without the bump, flipping the toggle is invisible.
#
# This tests the enabled->disabled TRANSITION (reconcile stops a LIVE broker),
# which is the interesting half -- as opposed to a fresh daemon start with the
# toggle already off, where reconcile simply never spawns one.

$testDir = "C:\ai-broker-test"
$local   = "C:\Users\umesh\work\dev_device_plane.py"

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

Write-Host "=== baseline ===" -ForegroundColor Cyan
$procs = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
if (-not $procs) {
    Write-Host "  no broker running -- nothing for the transition to stop." -ForegroundColor Red
    Write-Host "  Re-run setup + the service restart first." -ForegroundColor Red
    exit 1
}
$procs | Select-Object Id, ProcessName, SI | Format-Table -AutoSize
Write-Host "  8788 listening: $([bool](Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue))"

# How many times has it stopped before? Used to detect a NEW stop rather than
# matching a stale line from an earlier run.
$before = (Read-DaemonLog -Pattern "stopped ai-broker-mon").Count
Write-Host "  prior 'stopped' log lines: $before"

Write-Host ""
Write-Host "=== flipping mock: version 2, DISABLED, heartbeat still 60s ===" -ForegroundColor Cyan
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$env:CONFIG_VERSION             = "2"
$env:AI_BROKER_ENABLED          = "0"
$env:HEARTBEAT_INTERVAL_SECONDS = "60"
Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
    -ArgumentList "-u", $local, "--port", "8080" `
    -RedirectStandardOutput "$testDir\device-plane.out" `
    -RedirectStandardError  "$testDir\device-plane.err" `
    -WindowStyle Hidden
Start-Sleep -Seconds 3
$cfg = curl.exe -s http://127.0.0.1:8080/endpoint/v1/config
Write-Host "  /config serves: $cfg"
if ($cfg -notmatch '"version":\s*2' -or $cfg -notmatch '"enabled":\s*false') {
    Write-Host "  UNEXPECTED payload -- aborting" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== waiting for the heartbeat to pick it up (allowing 150s) ===" -ForegroundColor Cyan
$stopped = $false
for ($i = 1; $i -le 15; $i++) {
    Start-Sleep -Seconds 10
    $now = (Read-DaemonLog -Pattern "stopped ai-broker-mon").Count
    $alive = [bool](Get-Process ai-broker-mon -ErrorAction SilentlyContinue)
    Write-Host ("  +{0,3}s  broker_alive={1}  stopped_lines={2}" -f ($i*10), $alive, $now)
    if ($now -gt $before) { $stopped = $true; break }
}

Write-Host ""
$alive = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
$port  = Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue
$verdictPass = $false
if ($stopped -and -not $alive) {
    Write-Host "VERDICT: PASS -- disable frame observed, broker stopped" -ForegroundColor Green
    if ($port) { Write-Host "  BUT 8788 still held by PID $($port.OwningProcess)" -ForegroundColor Red }
    else { Write-Host "  8788 released" -ForegroundColor Green; $verdictPass = $true }
} elseif ($stopped -and $alive) {
    Write-Host "VERDICT: PARTIAL -- 'stopped' logged but a broker is still alive" -ForegroundColor Red
    $alive | Select-Object Id, ProcessName | Format-Table -AutoSize
} else {
    Write-Host "VERDICT: FAIL/TIMEOUT -- no new 'stopped' line in 150s" -ForegroundColor Red
    Write-Host "  If the cadence never dropped to 60s, the next heartbeat could" -ForegroundColor Yellow
    Write-Host "  still be up to 600s away. Check:" -ForegroundColor Yellow
    Write-Host '    Select-String -Path "C:\ProgramData\ZscalerAIProtect\daemon.log" -Pattern "heartbeat: starting at" | Select-Object -Last 2'
}

Write-Host ""
Write-Host "=== relevant daemon log ===" -ForegroundColor Cyan
Read-DaemonLog -Pattern "stopped ai-broker-mon|settings|config_version|heartbeat: " -Tail 40 | Select-Object -Last 8

Write-Host ""
Write-Host "To RESTORE (enabled again, version 3 so the daemon re-reads):" -ForegroundColor Cyan
Write-Host '  Get-Process python | Stop-Process -Force'
Write-Host '  $env:CONFIG_VERSION="3"; $env:AI_BROKER_ENABLED="1"; $env:HEARTBEAT_INTERVAL_SECONDS="60"'
Write-Host '  Start-Process "C:\Program Files\Python312\python.exe" -ArgumentList "-u","C:\Users\umesh\work\dev_device_plane.py","--port","8080" -RedirectStandardOutput "C:\ai-broker-test\device-plane.out" -RedirectStandardError "C:\ai-broker-test\device-plane.err" -WindowStyle Hidden'

# The restore itself (bumping CONFIG_VERSION, waiting for respawn) happens back
# in run-e2e-suite.ps1 after this returns -- this script's own job is only to
# confirm the broker actually stopped, so the exit code reflects only that.
if (-not $verdictPass) { exit 1 }
exit 0
