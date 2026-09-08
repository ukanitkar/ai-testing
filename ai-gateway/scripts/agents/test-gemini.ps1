<#
.SYNOPSIS
    End-to-end test for Gemini CLI wiring.

.DESCRIPTION
    Detection tier always runs. Wiring tier (-Live) asserts:
      - ~\.gemini\settings.json   mcpServers.zax  {command,args,env}
      - and explicitly that NO llm delta exists — gemini.rs's own doc
        comment: no base-URL knob, no proxy knob either (`settings.schema.json`
        has no `proxy` property at any level). `fwd=true` in --agents is
        best-effort listener binding only (empty `proxy_key`), never delivered
        as config. A future real-daemon harness could still confirm nothing
        broke this MCP-only posture; there's no LLM leg to add on Windows since
        there's no delivery surface (config-file or process-env) declared for
        it at all.

    Ground truth: ai-gateway/util/src/agent_configs.rs AGENTS["gemini"],
    ai-gateway/agent-manager/src/agents/gemini.rs.
#>
param([switch] $Live, [switch] $KeepLogs, [int] $Rescan = 3)
. "$PSScriptRoot\common-agents.ps1"

Invoke-AgentE2E -AgentId 'gemini' -Live:$Live -KeepLogs:$KeepLogs -Rescan $Rescan `
    -FixtureSetup {
        param($AgentHome)
        New-NpmPackageFixture -HomeDir $AgentHome -Name '@google/gemini-cli' -Version '0.29.0-fixture'
        Ensure-Dir (Join-Path $AgentHome '.gemini')
    } `
    -WiringCheck {
        param($AgentHome)

        Invoke-ACheck "~\.gemini\settings.json has mcpServers.zax" {
            $p = Join-Path $AgentHome '.gemini\settings.json'
            if (-not (Test-Path $p)) { return $false }
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            $zax = Get-JsonPath $doc @('mcpServers', 'zax')
            $null -ne $zax -and $null -ne $zax.command
        }

        Invoke-ACheck "~\.gemini\settings.json has no LLM delta at all (no knob exists)" {
            $p = Join-Path $AgentHome '.gemini\settings.json'
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            ($null -eq (Get-JsonPath $doc @('env'))) -and ($null -eq (Get-JsonPath $doc @('proxy')))
        }
    }

Complete-AgentRun
