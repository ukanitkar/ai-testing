# Phase B prep -- bring the stack back up after the reboot.
# Run this in the REGULAR umesh window (no elevation needed).
#
# The mock is started DETACHED with its output redirected to files, rather
# than occupying a console. Two reasons: a console-hosted mock froze once
# when QuickEdit selection blocked its handler threads and wedged the whole
# pipeline, and detaching leaves this window free for the actual test.

$testDir = "C:\ai-broker-test"
$local   = "C:\Users\umesh\work\dev_device_plane.py"

New-Item -ItemType Directory -Path $testDir -Force | Out-Null

# Copy the mock locally first. A long-running process should not depend on
# \\tsclient\Z staying mounted -- that path evaporates if the RDP session drops.
Copy-Item "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" $local -Force
Write-Host "mock script copied to $local" -ForegroundColor Green

# Already running?
$existing = Get-Process python -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "python already running (pid $($existing.Id -join ',')) -- not starting a second one" -ForegroundColor Yellow
} else {
    Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
        -ArgumentList "-u", $local, "--port", "8080" `
        -RedirectStandardOutput "$testDir\device-plane.out" `
        -RedirectStandardError  "$testDir\device-plane.err" `
        -WindowStyle Hidden
    Write-Host "mock device plane started (detached)" -ForegroundColor Green
    Start-Sleep -Seconds 3
}

Write-Host ""
Write-Host "=== mock health ===" -ForegroundColor Cyan
$health = curl.exe -s http://127.0.0.1:8080/health
if ($health -eq "ok") {
    Write-Host "  /health -> ok" -ForegroundColor Green
    Write-Host "  /config -> $(curl.exe -s http://127.0.0.1:8080/endpoint/v1/config)"
} else {
    Write-Host "  FAILED (got: '$health')" -ForegroundColor Red
    Write-Host "  stderr:" -ForegroundColor Yellow
    Get-Content "$testDir\device-plane.err" -ErrorAction SilentlyContinue | Select-Object -Last 10
    exit 1
}

Write-Host ""
Write-Host "Next, in the ADMIN window:" -ForegroundColor Cyan
Write-Host "  sc.exe start AiBrokerTest"
Write-Host ""
Write-Host "Then back here, after ~20s:" -ForegroundColor Cyan
Write-Host '  powershell -ExecutionPolicy Bypass -File "\\tsclient\Z\commands\phase-b-verify.ps1"'
