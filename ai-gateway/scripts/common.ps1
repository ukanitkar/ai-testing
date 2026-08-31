# Shared environment for the ai-gateway PowerShell test scripts. Dot-source
# it; do not run it directly.
#   . "$PSScriptRoot\common.ps1"

# Resolve the ai-protect checkout these scripts actually build/test against.
# Three cases, same as common.sh's bash version:
#   1. $env:AI_PROTECT_ROOT set explicitly -- always wins, e.g. a laptop where
#      ai-protect and ai-testing aren't laid out as siblings.
#   2. Running from a REAL ai-protect checkout (this script's own canonical
#      home, ai-protect\ai-gateway\scripts\) -- two levels up is the repo
#      root; confirmed by finding the ai-warden package there, not just any
#      Cargo.toml.
#   3. Running from the ai-testing mirror (ai-testing\ai-gateway\scripts\) --
#      ai-testing and ai-protect are siblings under ...\integration\, so go
#      up to that shared parent and across.
if ($env:AI_PROTECT_ROOT) {
    $RepoRoot = $env:AI_PROTECT_ROOT
} else {
    $candidate = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $cargoToml = Join-Path $candidate 'Cargo.toml'
    if ((Test-Path $cargoToml) -and (Select-String -Path $cargoToml -Pattern '^name = "ai-warden"' -Quiet)) {
        $RepoRoot = $candidate
    } else {
        $RepoRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $candidate)) 'ai-protect'
    }
}
if (-not (Test-Path (Join-Path $RepoRoot 'Cargo.toml'))) {
    Write-Error "no ai-protect checkout found at $RepoRoot -- set `$env:AI_PROTECT_ROOT to override"
    exit 2
}

$Gw  = Join-Path $RepoRoot 'target\debug\zscaler-ai-gateway.exe'
$Sim = Join-Path $RepoRoot 'target\debug\zax-sim.exe'
$Docs = Join-Path $RepoRoot 'ai-gateway\docs'

function Require-Gateway {
    if (-not (Test-Path $Gw)) { Write-Error "no gateway binary at $Gw — run .\build.ps1 first"; exit 2 }
}
function Require-Sim {
    if (-not (Test-Path $Sim)) { Write-Error "no simulator at $Sim — run .\build.ps1 first"; exit 2 }
}
