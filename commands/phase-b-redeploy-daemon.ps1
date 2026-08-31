# Redeploy ONLY the daemon (the access_mode fix is in ai-warden's
# utils::atomic_write::windows; the broker binary is untouched), then restart
# the service so the config-apply test can be re-run against the fix.
#
# Run this WHOLE script from the ELEVATED window.

$daemonHash = "C6E0BED4B3180C0CEDA83B94B855A4D64FC61586A7FB23379BF5B9FF9922DA93"

Write-Host "Stopping service..."
sc.exe stop AiBrokerTest
Start-Sleep -Seconds 3
Get-Process ai-broker-mon, zscaler-ai-protect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

$leftover = Get-Process ai-broker-mon, zscaler-ai-protect -ErrorAction SilentlyContinue
if ($leftover) {
    Write-Host "ERROR: still running, aborting:" -ForegroundColor Red
    $leftover | Format-Table Id, ProcessName
    exit 1
}
Write-Host "Confirmed clean." -ForegroundColor Green

Copy-Item "\\tsclient\Z\target\release\zscaler-ai-protect.exe" "C:\Users\umesh\work\zscaler-ai-protect.exe" -Force
$d = (Get-FileHash "C:\Users\umesh\work\zscaler-ai-protect.exe" -Algorithm SHA256).Hash
if ($d -ne $daemonHash) {
    Write-Host "ERROR: hash mismatch! got $d" -ForegroundColor Red
    exit 1
}
Write-Host "Daemon hash confirmed: $d" -ForegroundColor Green

# The mock must be up before the daemon starts, or the daemon burns its first
# heartbeats on connection failures and backs off for a minute-plus.
$health = curl.exe -s http://127.0.0.1:8080/health
if ($health -ne "ok") {
    Write-Host "Mock device plane NOT up -- start it in the umesh window first:" -ForegroundColor Red
    Write-Host '  powershell -ExecutionPolicy Bypass -File "\\tsclient\Z\commands\phase-b-prep.ps1"'
    exit 1
}
Write-Host "Mock device plane is up." -ForegroundColor Green

Write-Host "Starting service..."
sc.exe start AiBrokerTest
Start-Sleep -Seconds 20

Write-Host ""
Write-Host "Now re-run the config-apply test in the UMESH window:" -ForegroundColor Cyan
Write-Host '  powershell -ExecutionPolicy Bypass -File "\\tsclient\Z\commands\phase-b-config-apply.ps1"'
