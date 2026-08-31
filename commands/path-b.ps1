# Step 2 - Path B: full daemon, SYSTEM service, session 0.
# Run this part from umesh's own (non-elevated) window.

Get-Process ai-broker-mon,zscaler-ai-protect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Get-Process ai-broker-mon,zscaler-ai-protect -ErrorAction SilentlyContinue   # must be empty

# Binaries are already fresh at C:\Users\umesh\work\*.exe from path-a.ps1 --
# AiBrokerTest's binPath already points there, so no re-copy needed.

Write-Host "Checking mock device plane on :8080..."
try {
    $health = curl.exe -s http://127.0.0.1:8080/health
    if ($health -ne "ok") { throw "unexpected response: $health" }
    Write-Host "Mock device plane is up." -ForegroundColor Green
} catch {
    Write-Host "Not running -- starting it now (leave this in its own window):" -ForegroundColor Yellow
    Write-Host '  & "C:\Program Files\Python312\python.exe" -u "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" --port 8080 *> "C:\ai-broker-test\device-plane.log"'
}

Write-Host "`nOnce the mock device plane is confirmed up, from an ELEVATED window" -ForegroundColor Cyan
Write-Host "(runas /user:ec2amaz-vrae5e8\administrator powershell.exe), run:"
Write-Host '  sc.exe query AiBrokerTest'
Write-Host '  sc.exe start AiBrokerTest'
Write-Host "`nThen back here, check the result:" -ForegroundColor Cyan
Write-Host '  powershell -ExecutionPolicy Bypass -File "\\tsclient\Z\commands\check-both.ps1"'
