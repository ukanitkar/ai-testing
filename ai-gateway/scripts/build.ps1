# Build and test the workspace. Writes nothing outside target/.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

Write-Host "[step] build + test + clippy (workspace)" -ForegroundColor Cyan
Write-Host "[step] repo: $RepoRoot" -ForegroundColor Cyan

Push-Location $RepoRoot
try {
    cargo build --workspace
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)" }

    cargo test --workspace
    if ($LASTEXITCODE -ne 0) { throw "cargo test failed (exit $LASTEXITCODE)" }

    cargo clippy --workspace --all-targets
    if ($LASTEXITCODE -ne 0) { throw "cargo clippy failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

Write-Host "[ok] build, tests and clippy passed" -ForegroundColor Green
