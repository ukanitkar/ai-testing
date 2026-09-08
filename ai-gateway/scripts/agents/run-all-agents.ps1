<#
.SYNOPSIS
    Runs all 7 per-agent end-to-end tests (the ones confirmed wired on
    main-08272026-all-agents) and reports one PASS/FAIL/SKIP summary.

.DESCRIPTION
    Covers: claude, cursor, gemini, openclaw, devin, windsurf, codex.
    Deliberately NOT here (real coverage gaps, not oversights — see the
    project's own minimum-agent-set review):
      - vscode+copilot's editor-side LLM leg (`http.proxy` never wired — see
        vscode.rs/copilot.rs's own doc comments, which point at each other)
      - chatgpt-desktop (ambiguous whether that means the standalone consumer
        app with server-side Connectors, or the renamed Codex-in-ChatGPT.app
        surface the `codex` adapter's config-dir-keyed wiring already reaches)

    Each test runs in its OWN PowerShell process (not dot-sourced), because
    every per-agent script ends by calling `exit` — dot-sourcing 7 scripts
    that each call `exit` into one session would kill this orchestrator after
    the first one.

.PARAMETER Live
    Passed through to every per-agent script. Without it, only the fast,
    no-login detection tier runs for all 7 (~agents shows enabled+installed).
    With it, EACH agent's wiring tier runs its OWN live deployment and its
    OWN browser sign-in — this is 7 separate logins in a full run, one per
    agent, not one shared login. Run a single agent's script directly
    (.\test-cursor.ps1 -Live) if you only want to sign in once for one agent.

.EXAMPLE
    .\run-all-agents.ps1
    Detection-only pass across all 7, no login.

.EXAMPLE
    .\run-all-agents.ps1 -Live -KeepLogs
    Full wiring verification for all 7, one browser sign-in per agent.
#>
param([switch] $Live, [switch] $KeepLogs, [int] $Rescan = 3)

$ErrorActionPreference = 'Continue'
$Agents = @('claude', 'cursor', 'gemini', 'openclaw', 'devin', 'windsurf', 'codex')

$Pass = 0
$Fail = 0
$Results = @()

foreach ($a in $Agents) {
    Write-Host ""
    Write-Host "════ $a ════" -ForegroundColor White
    $scriptPath = Join-Path $PSScriptRoot "test-$a.ps1"
    $psArgs = @('-NoProfile', '-File', $scriptPath, '-Rescan', $Rescan)
    if ($Live) { $psArgs += '-Live' }
    if ($KeepLogs) { $psArgs += '-KeepLogs' }

    & powershell.exe @psArgs
    if ($LASTEXITCODE -eq 0) {
        $Results += "PASS  $a"
        $Pass++
    } else {
        $Results += "FAIL  $a"
        $Fail++
    }
}

Write-Host ""
Write-Host "════ summary ════" -ForegroundColor White
foreach ($r in $Results) {
    if ($r.StartsWith('PASS')) { Write-Host $r -ForegroundColor Green }
    else { Write-Host $r -ForegroundColor Red }
}
Write-Host ""
$suffix = if ($Live) { '   (live — one login per agent)' } else { '   (detection-only — pass -Live for real wiring checks)' }
Write-Host ("passed: {0}   failed: {1}{2}" -f $Pass, $Fail, $suffix)

if (-not $Live) {
    Write-Host ""
    Write-Host "NOTE: Cursor's LLM leg (process-env) and OpenClaw's full wiring cannot" -ForegroundColor Yellow
    Write-Host "be exercised even with -Live via this simulator-based harness / without a" -ForegroundColor Yellow
    Write-Host "real openclaw binary on PATH — see each script's own header for why." -ForegroundColor Yellow
}

exit ([int]($Fail -gt 0))
