# Phase E, PART 2 (v3) -- run AFTER reconnecting (umesh window is fine for
# everything here; the elevated block at the end is optional).

$daemon    = "C:\ProgramData\ZscalerAIProtect\daemon.log"
$taskName  = "ZaxMockDevicePlane"
$schedLog  = "C:\ai-broker-test\device-plane-scheduled.log"
$local     = "C:\Users\umesh\work\dev_device_plane.py"

Write-Host "=== 0. did the SYSTEM-context mock survive the logoff? ===" -ForegroundColor Cyan
Write-Host "  (corroborating evidence -- its own access log should span the whole gap)" -ForegroundColor Cyan
if (Test-Path $schedLog) {
    $lines = (Get-Content $schedLog | Measure-Object -Line).Lines
    Write-Host "  $schedLog has $lines line(s) -- if this is large/continuous, the mock kept"
    Write-Host "  answering heartbeats the whole time nobody was logged on:"
    Get-Content $schedLog -Tail 8
} else {
    Write-Host "  log not found -- the task may not have run at all" -ForegroundColor Red
}
schtasks /query /tn $taskName /v /fo list 2>$null | Select-String "Status|Last Run Time|Last Result"

Write-Host ""
Write-Host "=== 1. did the fallback fire while nobody was logged on? ===" -ForegroundColor Cyan
$fallback = Select-String -Path $daemon -Pattern "no interactive session; starting" -ErrorAction SilentlyContinue |
            Select-Object -Last 1
if ($fallback) {
    Write-Host "  FOUND:" -ForegroundColor Green
    Write-Host "  $($fallback.Line.Trim())"
} else {
    Write-Host "  NOT FOUND -- check the full timeline below" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== 2. full recent timeline ===" -ForegroundColor Cyan
Select-String -Path $daemon -Pattern "config_version|launched ai-broker-mon|stopped ai-broker-mon|no interactive session|OidcFailed|could not (launch|start)" |
    Select-Object -Last 15 | ForEach-Object { $_.Line.Trim() }

Write-Host ""
Write-Host "=== 3. current process state ===" -ForegroundColor Cyan
$procs = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
if ($procs) { $procs | Select-Object Id, SI | Format-Table -AutoSize }
else { Write-Host "  none running -- the SYSTEM-fallback broker already exited (OIDC timeout), as expected" }
Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue | Select-Object OwningProcess

Write-Host ""
Write-Host "=== 4. tearing down the scheduled-task mock, forcing a NEW frame now that umesh is back ===" -ForegroundColor Cyan
schtasks /end /tn $taskName 2>$null | Out-Null
schtasks /delete /tn $taskName /f 2>$null | Out-Null
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$heldVersion = 0
$lastFetch = Select-String -Path $daemon -Pattern "config_version (\d+) differs from held" -ErrorAction SilentlyContinue |
             Select-Object -Last 1
if ($lastFetch -and ($lastFetch.Line -match "config_version (\d+) differs from held")) {
    $heldVersion = [int]$Matches[1]
}
$nextVersion = $heldVersion + 1
Write-Host "  daemon currently holds config_version: $heldVersion -- bumping to $nextVersion"

Copy-Item "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" $local -Force
$env:CONFIG_VERSION             = "$nextVersion"
$env:AI_BROKER_ENABLED          = "1"
$env:HEARTBEAT_INTERVAL_SECONDS = "60"
Remove-Item Env:\DELAYED_CONFIG_VERSION -ErrorAction SilentlyContinue
Remove-Item Env:\DELAYED_CONFIG_VERSION_AFTER_SECONDS -ErrorAction SilentlyContinue
Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
    -ArgumentList "-u", $local, "--port", "8080" `
    -RedirectStandardOutput "C:\ai-broker-test\device-plane.out" `
    -RedirectStandardError  "C:\ai-broker-test\device-plane.err" `
    -WindowStyle Hidden
Start-Sleep -Seconds 3
$cfg = curl.exe -s http://127.0.0.1:8080/endpoint/v1/config
Write-Host "  /config now serves: $cfg"

$beforeCount = (Select-String -Path $daemon -Pattern "launched ai-broker-mon in the user session" -ErrorAction SilentlyContinue |
                Measure-Object).Count
Write-Host "  prior 'launched ... in the user session' lines: $beforeCount"
Write-Host "  waiting up to 90s for the daemon to pick it up and (re)drop the broker..." -ForegroundColor Cyan
$droppedInUserSession = $false
for ($i = 1; $i -le 18; $i++) {
    Start-Sleep -Seconds 5
    $now = (Select-String -Path $daemon -Pattern "launched ai-broker-mon in the user session" -ErrorAction SilentlyContinue |
            Measure-Object).Count
    if ($now -gt $beforeCount) { $droppedInUserSession = $true; break }
    Write-Host ("  +{0,3}s  waiting (count still {1})" -f ($i * 5), $now)
}

Write-Host ""
if ($droppedInUserSession) {
    Write-Host "VERDICT: PASS -- reconcile re-dropped a broker into the user session after login" -ForegroundColor Green
} else {
    $stillSystem = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
    if ($stillSystem) {
        Write-Host "VERDICT: a broker is STILL RUNNING and nothing new was dropped --" -ForegroundColor Red
        Write-Host "  possible confirmation of the open question: reconcile() only replaces a" -ForegroundColor Red
        Write-Host "  DEAD broker, never a misplaced-but-alive one." -ForegroundColor Red
    } else {
        Write-Host "VERDICT: no broker running at all and no fresh drop seen -- inspect section 2" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== final snapshot ===" -ForegroundColor Cyan
Get-Process ai-broker-mon -ErrorAction SilentlyContinue | Select-Object Id, SI | Format-Table -AutoSize
Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue | Select-Object OwningProcess

Write-Host ""
Write-Host "=== OPTIONAL -- run from the ELEVATED window if a broker is still running ===" -ForegroundColor Cyan
Write-Host '    Get-Process ai-broker-mon -IncludeUserName | Select-Object Id,UserName,SI'
