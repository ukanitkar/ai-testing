# Baseline. Writes nothing: proves recovery works before you need it, and
# shows what the gateway detects on this machine.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
Require-Gateway

Write-Host "[step] agents this machine has" -ForegroundColor Cyan
& $Gw --agents

Write-Host "[step] recovery dry run" -ForegroundColor Cyan
& $Gw --recover --dry-run

Write-Host "[ok] baseline clean — expect 'Nothing to repair'" -ForegroundColor Green
