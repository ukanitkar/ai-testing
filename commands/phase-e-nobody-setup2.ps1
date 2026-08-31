# Phase E, PART 1 (v3) -- run from the ELEVATED window (schtasks /RU SYSTEM
# needs it). The first two attempts both failed for reasons that had nothing
# to do with the product:
#
#   attempt 1: bumped the mock's version immediately, and the daemon's own
#     ~60s heartbeat picked it up before there was time to log off -- the
#     broker was still alive, reconcile() correctly did nothing, no fallback
#     was ever attempted.
#   attempt 2: fixed that with a built-in delay inside the mock -- but the
#     mock was launched as a plain child of the umesh session via
#     Start-Process, so when the session tore down on logoff, Windows killed
#     the mock right along with the broker. With no mock reachable, the
#     daemon's heartbeat to 127.0.0.1:8080 just failed silently the whole
#     time nobody was logged on -- confirmed by a total gap in daemon.log
#     (zero config_version fetch lines between the last known-good fetch and
#     the next manual one after reconnecting).
#
# Fix: run the mock as a SYSTEM-context Windows scheduled task instead of an
# interactive child process. A SYSTEM task is not tied to any logon and
# survives a logoff -- the same way the real production backend (a remote
# HTTPS endpoint) is never affected by a Windows session ending.

$taskName = "ZaxMockDevicePlane"
$wrapperTemplate = "\\tsclient\Z\commands\phase-e-mock-wrapper.ps1"
$wrapperFilled   = "C:\ai-broker-test\phase-e-mock-wrapper-filled.ps1"
$daemon = "C:\ProgramData\ZscalerAIProtect\daemon.log"

New-Item -ItemType Directory -Path "C:\ai-broker-test" -Force | Out-Null

Write-Host "=== current state ===" -ForegroundColor Cyan
Get-Process ai-broker-mon -ErrorAction SilentlyContinue | Select-Object Id, SI | Format-Table -AutoSize
Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue | Select-Object OwningProcess

$heldVersion = 0
$lastFetch = Select-String -Path $daemon -Pattern "config_version (\d+) differs from held" -ErrorAction SilentlyContinue |
             Select-Object -Last 1
if ($lastFetch -and ($lastFetch.Line -match "config_version (\d+) differs from held")) {
    $heldVersion = [int]$Matches[1]
}
$delayedVersion = $heldVersion + 1
Write-Host "  daemon currently holds config_version: $heldVersion -- will delay-switch to $delayedVersion"

Write-Host ""
Write-Host "=== cleaning up any prior interactive-session mock and scheduled task ===" -ForegroundColor Cyan
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
schtasks /delete /tn $taskName /f 2>$null | Out-Null
Start-Sleep -Seconds 1

Write-Host ""
Write-Host "=== filling in the wrapper and registering the SYSTEM scheduled task ===" -ForegroundColor Cyan
(Get-Content $wrapperTemplate -Raw) `
    -replace "__BASE_VERSION__", "$heldVersion" `
    -replace "__DELAYED_VERSION__", "$delayedVersion" `
    -replace "__DELAY_SECONDS__", "150" |
    Set-Content -Path $wrapperFilled -Encoding ascii

$trCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrapperFilled`""
schtasks /create /tn $taskName /tr $trCmd /sc once /st 23:59 /ru SYSTEM /f
if ($LASTEXITCODE -ne 0) {
    Write-Host "  schtasks /create FAILED (exit $LASTEXITCODE) -- aborting" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== starting the task now ===" -ForegroundColor Cyan
schtasks /run /tn $taskName
Start-Sleep -Seconds 3

$cfg = curl.exe -s http://127.0.0.1:8080/endpoint/v1/config
Write-Host "  /config serves right now (must be UNCHANGED, version $heldVersion): $cfg"
if ($cfg -notmatch "`"version`":\s*$heldVersion") {
    Write-Host "  UNEXPECTED -- aborting. Check C:\ai-broker-test\device-plane-scheduled.log" -ForegroundColor Red
    Get-Content "C:\ai-broker-test\device-plane-scheduled.log" -Tail 20 -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "  confirmed: version will not change for 150s, and this mock will SURVIVE your logoff" -ForegroundColor Green

Write-Host ""
Write-Host "=== ARMED. Log off any time in the next ~2 minutes ===" -ForegroundColor Yellow
Write-Host "  A genuine sign-out, not a disconnect:" -ForegroundColor Yellow
Write-Host ""
Write-Host "    shutdown /l" -ForegroundColor Cyan
Write-Host ""
Write-Host "Wait ~5-6 minutes, then reconnect and run:" -ForegroundColor Yellow
Write-Host '  powershell -ExecutionPolicy Bypass -File "\\tsclient\Z\commands\phase-e-nobody-check2.ps1"' -ForegroundColor Cyan
