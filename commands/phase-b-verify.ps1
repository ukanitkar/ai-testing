# Phase B verify -- confirm the stack came back up correctly after the reboot.
# Run in the REGULAR umesh window. (Process ownership needs elevation to read,
# so that one line is expected to be skipped here; run it from the admin
# window if you want the UserName column.)
#
# This doubles as a free re-verification that last night's broker_home fix
# survives a reboot: the broker should reach ready=true using the CACHED
# credentials in .credentials.json, with no interactive OIDC round at all.

Write-Host "=== processes ===" -ForegroundColor Cyan
$procs = Get-Process ai-broker-mon, zscaler-ai-protect -ErrorAction SilentlyContinue
if ($procs) { $procs | Select-Object Id, ProcessName, SI | Format-Table -AutoSize }
else { Write-Host "  none running" -ForegroundColor Red }

Write-Host "=== port 8788 (the LLM proxy) ===" -ForegroundColor Cyan
$net = netstat -ano | Select-String ":8788"
if ($net) { $net } else { Write-Host "  nothing listening" -ForegroundColor Yellow }

Write-Host ""
Write-Host "=== daemon: broker spawn + status.json readiness ===" -ForegroundColor Cyan
Get-Content "C:\ProgramData\ZscalerAIProtect\daemon.log" -Tail 40 -ErrorAction SilentlyContinue |
    Select-String "launched ai-broker-mon|could not launch ai-broker-mon|status.json .. ready" |
    Select-Object -Last 4

Write-Host ""
Write-Host "=== broker: proxy listening + any OIDC (should NOT need a fresh login) ===" -ForegroundColor Cyan
Get-Content "C:\Users\umesh\.ai-broker\logs\zax.log" -Tail 40 -ErrorAction SilentlyContinue |
    Select-String "proxy listening|launching interactive OIDC|cached|watching .*writing" |
    Select-Object -Last 6

Write-Host ""
Write-Host "What good looks like: daemon SI=0, broker SI=3, 8788 LISTENING," -ForegroundColor Cyan
Write-Host "daemon.log's status.json line showing ready=true, and NO 'launching interactive OIDC' line." -ForegroundColor Cyan
