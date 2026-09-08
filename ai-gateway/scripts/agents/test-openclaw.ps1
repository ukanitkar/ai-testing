<#
.SYNOPSIS
    End-to-end test for OpenClaw wiring.

.DESCRIPTION
    Detection tier always runs. Wiring tier (-Live) asserts:
      - ~\.openclaw\openclaw.json   mcp.servers.zax (nested 2 levels deep —
        confirmed against openclaw.rs's own MCP_CONTAINER const)
      - ~\.openclaw\openclaw.json   models.providers.anthropic.baseUrl -> loopback
        (nested JsonPath, strict JSON — a JSONC/commented file is refused
        rather than clobbered; confirmed against openclaw.rs's own LLM_PATH
        const. openclaw.rs's own header flags this path as UNVERIFIED against
        a live install for whether it really overrides the built-in
        `anthropic` provider — this script can confirm delivery, not that
        OpenClaw's own resolution order actually prefers it.)

    ⚠️ FIXTURE LIMITATION: OpenClaw declares no npm-package / app-bundle /
    VS Code-extension identity source (agents/mod.rs's BinaryHints) — only a
    bare `commands: [openclaw, clawdbot]` PATH lookup. Unlike Claude/Codex/
    Devin/Gemini, there's no clean way to fixture a version-bearing marker
    for it (a hand-written stub .exe carries no real PE version resource).
    So this script only ensures the ~\.openclaw directory exists (enough for
    `is_installed()`); reaching "success" during -Live genuinely needs a
    real openclaw (or clawdbot) binary already on PATH on this VM. If it
    isn't, the shared driver already reports that plainly ("never reached
    'success'") rather than failing silently.

    Ground truth: ai-gateway/util/src/agent_configs.rs AGENTS["openclaw"],
    ai-gateway/agent-manager/src/agents/openclaw.rs.
#>
param([switch] $Live, [switch] $KeepLogs, [int] $Rescan = 3)
. "$PSScriptRoot\common-agents.ps1"

Invoke-AgentE2E -AgentId 'openclaw' -Live:$Live -KeepLogs:$KeepLogs -Rescan $Rescan `
    -FixtureSetup {
        param($AgentHome)
        Ensure-Dir (Join-Path $AgentHome '.openclaw')
        Write-ANote 'no npm/app-bundle/vscode-extension identity source exists for openclaw — a real binary on PATH is needed to reach success'
    } `
    -WiringCheck {
        param($AgentHome)

        Invoke-ACheck "~\.openclaw\openclaw.json has mcp.servers.zax (nested)" {
            $p = Join-Path $AgentHome '.openclaw\openclaw.json'
            if (-not (Test-Path $p)) { return $false }
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            $zax = Get-JsonPath $doc @('mcp', 'servers', 'zax')
            $null -ne $zax -and $null -ne $zax.command
        }

        Invoke-ACheck "~\.openclaw\openclaw.json models.providers.anthropic.baseUrl is a loopback URL" {
            $p = Join-Path $AgentHome '.openclaw\openclaw.json'
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            Test-IsLoopbackUrl (Get-JsonPath $doc @('models', 'providers', 'anthropic', 'baseUrl'))
        }
    }

Complete-AgentRun
