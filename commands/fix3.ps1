# Redeploy the session-priority-fix build of the daemon (WTSActive now beats a
# stale WTSDisconnected session) and re-test the AiBrokerTest SYSTEM service
# privilege-drop path.
# Run this from an elevated PowerShell on the VM.

$expectedHash = "92DE3EC705C074F827D02A1C3A12CD9401035E242DA579173B1AA7CA2C3C2806"

Write-Host "Stopping AiBrokerTest service..."
sc.exe stop AiBrokerTest

Write-Host "Killing any leftover daemon/broker processes..."
Get-Process zscaler-ai-protect, ai-broker-mon -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$leftover = Get-Process zscaler-ai-protect, ai-broker-mon -ErrorAction SilentlyContinue
if ($leftover) {
    Write-Host "ERROR: processes still running, aborting:" -ForegroundColor Red
    $leftover | Format-Table Id, ProcessName, SI
    exit 1
}
Write-Host "Confirmed clean." -ForegroundColor Green

Write-Host "Copying fixed binary from Z: ..."
Copy-Item "\\tsclient\Z\target\release\zscaler-ai-protect.exe" "C:\Users\umesh\work\zscaler-ai-protect.exe" -Force

$actualHash = (Get-FileHash "C:\Users\umesh\work\zscaler-ai-protect.exe" -Algorithm SHA256).Hash
if ($actualHash -ne $expectedHash) {
    Write-Host "ERROR: hash mismatch after copy!" -ForegroundColor Red
    Write-Host "  expected: $expectedHash"
    Write-Host "  actual:   $actualHash"
    exit 1
}
Write-Host "Hash confirmed: $actualHash" -ForegroundColor Green

Write-Host "Checking mock device plane on :8080..."
try {
    $health = curl.exe -s http://127.0.0.1:8080/health
    if ($health -ne "ok") { throw "unexpected response: $health" }
    Write-Host "Mock device plane is up." -ForegroundColor Green
} catch {
    Write-Host "WARNING: mock device plane not reachable ($_). Restart it before continuing:" -ForegroundColor Yellow
    Write-Host '  & "C:\Program Files\Python312\python.exe" -u "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" --port 8080 *> "C:\ai-broker-test\device-plane.log"'
}

Write-Host "Starting AiBrokerTest service..."
sc.exe start AiBrokerTest
Start-Sleep -Seconds 5

Write-Host "`n--- ai-broker-mon.exe owner (the actual test) ---" -ForegroundColor Cyan
Get-Process ai-broker-mon -IncludeUserName -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, UserName, SI

Write-Host "`n--- latest broker-launch log lines ---" -ForegroundColor Cyan
Select-String -Path "C:\ProgramData\ZscalerAIProtect\daemon.log" -Pattern "launched ai-broker-mon|could not start ai-broker-mon" |
    Select-Object -Last 4
