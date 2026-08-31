# Teardown. Reverses this product's config edits.
# Surgical: removes only the keys we write, so live state in an agent's config
# (project history, sessions) survives. Exits non-zero if anything is left
# unrepaired, so it works as a test gate. Does NOT undo tenant-side agent
# registration.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
Require-Gateway

Write-Host "[step] teardown (--recover)" -ForegroundColor Cyan

# Stop the gateway and any simulator first, so recover sees clean process/port state.
Get-Process zax-sim -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process zscaler-ai-gateway -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

Write-Host "[step] dry-run (what it would do):" -ForegroundColor Cyan
& $Gw --recover --dry-run

Write-Host "[step] applying recovery:" -ForegroundColor Cyan
& $Gw --recover
if ($LASTEXITCODE -eq 0) {
    Write-Host "[ok] teardown complete — config restored (exit 0)" -ForegroundColor Green
    exit 0
} else {
    Write-Error "recover reported unrepaired items (exit $LASTEXITCODE) — see output above"
    exit 1
}
