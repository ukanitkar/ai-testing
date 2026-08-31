# Phase E, PART 2 (v2) -- run AFTER reconnecting (umesh window; unelevated is
# fine except the one optional block at the end).
#
# Verifies the SYSTEM-fallback path fired while nobody was on the console
# (this time via the mock's own built-in delay, not a hand-timed race), then
# forces ANOTHER new settings frame now that a user is logged in again, to
# test the genuinely open question: can reconcile() ever REPLACE an
# already-running-but-misplaced broker, or can it only replace one that has
# actually exited? reconcile()'s reap step is has_exited()-gated -- if the
# SYSTEM-context broker from the fallback is STILL ALIVE (e.g. still inside
# its OIDC deadline) when this new frame lands, reconcile sees
# guard.is_some() && !has_exited() and does NOTHING. There is no "this broker
# is in the wrong session, kill and replace it" path in the code -- only
# "this broker is dead, replace it". That gap, if it manifests, is itself the
# finding.

$daemon = "C:\ProgramData\ZscalerAIProtect\daemon.log"
$local  = "C:\Users\umesh\work\dev_device_plane.py"

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
Write-Host "=== 2. full recent timeline (config fetches + spawn/stop/fallback lines) ===" -ForegroundColor Cyan
Select-String -Path $daemon -Pattern "config_version|launched ai-broker-mon|stopped ai-broker-mon|no interactive session|OidcFailed|could not (launch|start)" |
    Select-Object -Last 15 | ForEach-Object { $_.Line.Trim() }

Write-Host ""
Write-Host "=== 3. current process state ===" -ForegroundColor Cyan
$procs = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
if ($procs) {
    Write-Host "  still running (SI shown; the elevated block below shows UserName):"
    $procs | Select-Object Id, SI | Format-Table -AutoSize
} else {
    Write-Host "  none running -- the SYSTEM-fallback broker already exited (OIDC timeout), as expected"
}
Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue | Select-Object OwningProcess

Write-Host ""
Write-Host "=== 4. forcing a NEW settings frame now that umesh is logged in again ===" -ForegroundColor Cyan
Write-Host "  This is the second half of the test: does reconcile() correctly drop a" -ForegroundColor Yellow
Write-Host "  FRESH broker into the user session now, or does a still-alive SYSTEM" -ForegroundColor Yellow
Write-Host "  broker block it?" -ForegroundColor Yellow

$heldVersion = 0
$lastFetch = Select-String -Path $daemon -Pattern "config_version (\d+) differs from held" -ErrorAction SilentlyContinue |
             Select-Object -Last 1
if ($lastFetch -and ($lastFetch.Line -match "config_version (\d+) differs from held")) {
    $heldVersion = [int]$Matches[1]
}
$nextVersion = $heldVersion + 1
Write-Host "  daemon currently holds config_version: $heldVersion -- bumping to $nextVersion"

Copy-Item "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" $local -Force
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
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
        Write-Host "  DEAD broker, never a misplaced-but-alive one. Confirm ownership below." -ForegroundColor Red
    } else {
        Write-Host "VERDICT: no broker running at all and no fresh drop seen -- inspect the" -ForegroundColor Red
        Write-Host "  timeline in section 2 for what happened." -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== final snapshot ===" -ForegroundColor Cyan
Get-Process ai-broker-mon -ErrorAction SilentlyContinue | Select-Object Id, SI | Format-Table -AutoSize
Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue | Select-Object OwningProcess

Write-Host ""
Write-Host "=== OPTIONAL -- run from the ELEVATED window if a broker is still running ===" -ForegroundColor Cyan
Write-Host "  to see whether it is SYSTEM (a stale fallback) or umesh (a fresh drop):" -ForegroundColor Cyan
Write-Host '    Get-Process ai-broker-mon -IncludeUserName | Select-Object Id,UserName,SI'
