# One entry point for a comprehensive ai-gateway test pass on Windows.
#
# Runs everything that's actually wired up today; clearly reports what it
# skipped so "all green" never quietly means "we didn't check that."
#
# Usage:
#   .\run-all.ps1              offline pass (build, baseline, integration, teardown)
#   .\run-all.ps1 -Live        also run integration's --live enrolment pass
#   .\run-all.ps1 -SkipBuild   skip the cargo build/test/clippy step (faster
#                              re-run once you've already built once)
#
# $env:AI_PROTECT_ROOT can override which ai-protect checkout this targets
# (see ai-gateway\scripts\common.ps1) — defaults to the sibling ai-protect
# checkout next to this ai-testing repo.

param(
    [switch]$Live,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Continue'
$Scripts = Join-Path $PSScriptRoot 'ai-gateway\scripts'

$Pass = 0
$Fail = 0
$Skip = 0
$Results = @()

function Run-Phase {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ""
    Write-Host "════ $Name ════" -ForegroundColor White
    & $Body
    if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
        $script:Results += "PASS  $Name"
        $script:Pass++
    } else {
        $script:Results += "FAIL  $Name"
        $script:Fail++
    }
}

function Skip-Phase {
    param([string]$Name, [string]$Why)
    Write-Host "SKIP  $Name — $Why" -ForegroundColor Yellow
    $script:Results += "SKIP  $Name — $Why"
    $script:Skip++
}

# ---- wired up and running today --------------------------------------------
if ($SkipBuild) {
    Skip-Phase "build (cargo build/test/clippy)" "-SkipBuild passed"
} else {
    Run-Phase "build (cargo build/test/clippy)" { & "$Scripts\build.ps1" }
}

Run-Phase "baseline (detection + --recover --dry-run)" { & "$Scripts\baseline.ps1" }
Run-Phase "integration (offline)" { & "$Scripts\integration.ps1" }
if ($Live) {
    Run-Phase "integration (--live enrolment)" { & "$Scripts\integration.ps1" -Live }
} else {
    Skip-Phase "integration (--live enrolment)" "pass -Live to run it (needs one browser sign-in)"
}
Run-Phase "teardown (--recover, config restored)" { & "$Scripts\teardown.ps1" }

# ---- not wired up yet — real coverage gaps, not oversights -----------------
# See ai-testing\README.md and the "historical" scripts this repo already
# recovered for what these need to be ported FROM. Each of these was real
# coverage in the old Windows E2E suite; none of them has a working
# replacement yet.
Skip-Phase "MCP leg (--bridge <agent> stdio relay)" `
  "TODO: port commands\phase-c-mcp-stdio.ps1 to the new --bridge flag"
Skip-Phase "TLS + per-install-token gate on the LLM proxy" `
  "TODO: needs a harness against a live --service instance's proxy port (no more standalone --llm-proxy)"
Skip-Phase "protocol schema-version mismatch (negative case)" `
  "TODO: port commands\phase-c-protocol-mismatch.ps1 to .broker.zip's gzipped schema_ver field"
Skip-Phase "config-delta allowlist defense (negative case)" `
  "TODO: port commands\phase-b-config-apply.ps1's negative half to the new AgentStatus.config shape"
Skip-Phase "secure_file ACL-at-rest spot check" `
  "TODO: port commands\phase-a-acl.ps1 to the current file names under ~\.zsai-gateway"
Skip-Phase "--recover self-heal-gap timing" `
  "TODO: verify ai-gateway\scripts\dev_device_plane.py still matches the daemon's settings-frame mechanism, then port commands\phase-d-recover.ps1's timing assertion"
Skip-Phase "Windows privilege-drop / SYSTEM-service boundary" `
  "TODO: needs the actual Windows service installed (this VM/laptop can run it, but the script needs porting first) — see commands\run-e2e-suite.ps1 (historical) for what this covered"

# ---- summary ----------------------------------------------------------------
Write-Host ""
Write-Host "════ summary ════" -ForegroundColor White
foreach ($r in $Results) {
    if ($r.StartsWith("PASS")) { Write-Host $r -ForegroundColor Green }
    elseif ($r.StartsWith("FAIL")) { Write-Host $r -ForegroundColor Red }
    else { Write-Host $r -ForegroundColor Yellow }
}
Write-Host ""
Write-Host "passed: $Pass   failed: $Fail   skipped: $Skip"
exit $(if ($Fail -eq 0) { 0 } else { 1 })
