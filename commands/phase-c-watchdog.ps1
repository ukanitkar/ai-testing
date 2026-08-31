# Phase C, item 1 -- parent-death watchdog (orphan guard).
# Run in the REGULAR umesh window (both processes are umesh-owned, so no
# elevation needed to kill them).
#
# What is under test: common::start_parent_watchdog. The --llm-proxy child
# blocks on OpenProcess + WaitForSingleObject(INFINITE) against its PARENT's
# handle; when the parent dies, the child must exit on its own rather than
# orphaning and squatting on port 8788. Before commit f5c3e367 there was no
# Windows watchdog at all -- an orphaned proxy would hold that port until
# something killed it by hand.
#
# NOTE: this test intentionally kills the broker. Afterwards the service must
# be restarted from the ELEVATED window before any further testing:
#   sc.exe stop AiBrokerTest ; sc.exe start AiBrokerTest

Write-Host "=== before ===" -ForegroundColor Cyan
$all = Get-Process ai-broker-mon -ErrorAction SilentlyContinue
if (-not $all) { Write-Host "no ai-broker-mon running -- start the service first" -ForegroundColor Red; exit 1 }
$all | Select-Object Id, ProcessName, StartTime | Format-Table -AutoSize

# The proxy CHILD is whichever process owns the :8788 listener. The other
# ai-broker-mon is the control-mode broker, i.e. its parent.
$childPid = (Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue).OwningProcess |
            Select-Object -First 1
if (-not $childPid) { Write-Host "nothing listening on 8788 -- is the proxy up?" -ForegroundColor Red; exit 1 }
$parentPid = ($all | Where-Object { $_.Id -ne $childPid } | Select-Object -First 1).Id
if (-not $parentPid) { Write-Host "could not identify a separate parent process" -ForegroundColor Red; exit 1 }

Write-Host "  proxy child (owns :8788) : $childPid" -ForegroundColor Green
Write-Host "  control broker (parent)  : $parentPid" -ForegroundColor Green

# ---- kill ONLY the parent ------------------------------------------------
Write-Host ""
Write-Host "=== killing ONLY the parent ($parentPid); the child must notice ===" -ForegroundColor Cyan
Stop-Process -Id $parentPid -Force
Write-Host "  parent killed"

$childGone = $false
for ($i = 1; $i -le 10; $i++) {
    Start-Sleep -Seconds 2
    $still = Get-Process -Id $childPid -ErrorAction SilentlyContinue
    $port  = Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue
    Write-Host ("  +{0,2}s  child_alive={1}  port_8788_listening={2}" -f ($i*2), [bool]$still, [bool]$port)
    if (-not $still) { $childGone = $true; break }
}

Write-Host ""
$verdictPass = $false
if ($childGone) {
    Write-Host "VERDICT: PASS -- the child exited after its parent died" -ForegroundColor Green
    $port = Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue
    if ($port) {
        Write-Host "  BUT port 8788 is still held by PID $($port.OwningProcess) -- investigate" -ForegroundColor Red
    } else {
        Write-Host "  port 8788 released cleanly" -ForegroundColor Green
        $verdictPass = $true
    }
} else {
    Write-Host "VERDICT: FAIL -- child $childPid ORPHANED (watchdog did not fire)" -ForegroundColor Red
    Write-Host "  it is still holding 8788; kill it by hand:" -ForegroundColor Yellow
    Write-Host "    Stop-Process -Id $childPid -Force"
}

Write-Host ""
Write-Host "=== child's own log (watchdog message, if any) ===" -ForegroundColor Cyan
Get-Content "C:\Users\umesh\.ai-broker\logs\llm-proxy-child.log" -Tail 10 -ErrorAction SilentlyContinue
Get-Content "C:\Users\umesh\.ai-broker\logs\zax.log" -Tail 10 -ErrorAction SilentlyContinue |
    Select-String "watchdog|parent|shutdown|exiting"

Write-Host ""
Write-Host "Restart the service from the ELEVATED window before continuing:" -ForegroundColor Cyan
Write-Host "  sc.exe stop AiBrokerTest ; Start-Sleep -Seconds 3 ; sc.exe start AiBrokerTest"

if (-not $verdictPass) { exit 1 }
exit 0
