# Redeploy BOTH binaries -- this fix is in the DAEMON (broker_home now resolves
# the active console user's home when running as a service, instead of pushing
# systemprofile\.ai-broker when writing broker.json). Run the WHOLE script
# from the ELEVATED window.

$daemonHash = "9480CA8BEE64D184D9AA6ECF91A239FF297E8E11BB190600C9AE8064B4EF845B"
$brokerHash = "694C10C6362C80B7FD1D61D63D1ADC4970837F45BA4BAC9E52C808A817D5DC3F"

Write-Host "Stopping service..."
sc.exe stop AiBrokerTest
Start-Sleep -Seconds 3

Write-Host "Killing any leftover processes..."
Get-Process ai-broker-mon,zscaler-ai-protect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

$leftover = Get-Process ai-broker-mon,zscaler-ai-protect -ErrorAction SilentlyContinue
if ($leftover) {
    Write-Host "ERROR: processes still running, aborting:" -ForegroundColor Red
    $leftover | Format-Table Id, ProcessName
    exit 1
}
Write-Host "Confirmed clean." -ForegroundColor Green

Write-Host "Copying BOTH fresh binaries..."
Copy-Item "\\tsclient\Z\target\release\zscaler-ai-protect.exe" "C:\Users\umesh\work\zscaler-ai-protect.exe" -Force
Copy-Item "\\tsclient\Z\target\release\ai-broker-mon.exe" "C:\Users\umesh\work\ai-broker-mon.exe" -Force

$d = (Get-FileHash "C:\Users\umesh\work\zscaler-ai-protect.exe" -Algorithm SHA256).Hash
$b = (Get-FileHash "C:\Users\umesh\work\ai-broker-mon.exe" -Algorithm SHA256).Hash
if ($d -ne $daemonHash) { Write-Host "ERROR: daemon hash mismatch! got $d" -ForegroundColor Red; exit 1 }
if ($b -ne $brokerHash) { Write-Host "ERROR: broker hash mismatch! got $b" -ForegroundColor Red; exit 1 }
Write-Host "Both hashes confirmed." -ForegroundColor Green

Remove-Item "C:\Users\umesh\.ai-broker\logs\llm-proxy-child.log" -ErrorAction SilentlyContinue
Remove-Item "C:\ai-broker-test\start_llm_proxy_spawn.log" -ErrorAction SilentlyContinue

Write-Host "Checking mock device plane on :8080..."
$health = curl.exe -s http://127.0.0.1:8080/health
if ($health -ne "ok") {
    Write-Host "Mock device plane NOT reachable -- start it in its own window first:" -ForegroundColor Yellow
    Write-Host '  & "C:\Program Files\Python312\python.exe" -u "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" --port 8080 *> "C:\ai-broker-test\device-plane.log"'
    exit 1
}
Write-Host "Mock device plane is up." -ForegroundColor Green

Write-Host "Starting service..."
sc.exe start AiBrokerTest
Start-Sleep -Seconds 20

Write-Host ""
Write-Host "Done. Now run these separately (output ordering is unreliable in-script):" -ForegroundColor Cyan
Write-Host '  Get-Content "C:\ai-broker-test\start_llm_proxy_spawn.log"'
Write-Host '  netstat -ano | findstr :8788'
Write-Host '  Get-Content "C:\ProgramData\ZscalerAIProtect\daemon.log" -Tail 5 | Select-String "status.json"'
