# Phase C, item 2a, STEP 1 -- establish a fast heartbeat so settings changes
# are noticed in ~1 min instead of ~10. Run in the REGULAR umesh window.
#
# Chicken-and-egg: the daemon can only ADOPT a server-pushed cadence after it
# receives one, and receiving one needs a heartbeat at the CURRENT (600 s)
# cadence. A service restart short-circuits that -- the daemon heartbeats
# immediately on startup. So this step serves the fast cadence and you restart
# the service; from then on it re-reads settings every 60 s.
#
# 60 s is the floor: services::heartbeat clamps a pushed cadence to
# [60, 21600] seconds and warns outside that range.

$testDir = "C:\ai-broker-test"
$local   = "C:\Users\umesh\work\dev_device_plane.py"

Copy-Item "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" $local -Force

Write-Host "=== restarting mock: version 1, ENABLED, heartbeat 60s ===" -ForegroundColor Cyan
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$env:CONFIG_VERSION             = "1"
$env:AI_BROKER_ENABLED          = "1"
$env:HEARTBEAT_INTERVAL_SECONDS = "60"
Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
    -ArgumentList "-u", $local, "--port", "8080" `
    -RedirectStandardOutput "$testDir\device-plane.out" `
    -RedirectStandardError  "$testDir\device-plane.err" `
    -WindowStyle Hidden
Start-Sleep -Seconds 3

$cfg = curl.exe -s http://127.0.0.1:8080/endpoint/v1/config
Write-Host "  /config serves: $cfg"
if ($cfg -match '"heartbeat_interval_seconds":\s*60' -and $cfg -match '"enabled":\s*true') {
    Write-Host "  GOOD: fast cadence + enabled" -ForegroundColor Green
} else {
    Write-Host "  UNEXPECTED payload" -ForegroundColor Red
    Get-Content "$testDir\device-plane.err" -Tail 10 -ErrorAction SilentlyContinue
    exit 1
}

Write-Host ""
Write-Host "STEP 2 -- restart the service from the ELEVATED window:" -ForegroundColor Cyan
Write-Host '  sc.exe stop AiBrokerTest ; Start-Sleep -Seconds 3 ; sc.exe start AiBrokerTest'
Write-Host ""
Write-Host "Confirm it adopted the cadence (should say 'starting at 60s cadence'):" -ForegroundColor Cyan
Write-Host '  Select-String -Path "C:\ProgramData\ZscalerAIProtect\daemon.log" -Pattern "heartbeat: starting at" | Select-Object -Last 2'
Write-Host ""
Write-Host "STEP 3 -- then run the flip test back here:" -ForegroundColor Cyan
Write-Host '  powershell -ExecutionPolicy Bypass -File "\\tsclient\Z\commands\phase-c-negative-flip.ps1"'
