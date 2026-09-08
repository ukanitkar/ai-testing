<#
.SYNOPSIS
    End-to-end test for Claude Desktop + Claude Code wiring.

.DESCRIPTION
    Detection tier always runs. Wiring tier (-Live) asserts:
      - ~\.claude.json            mcpServers.zax  {command,args,env,type,alwaysLoad}
      - ~\.claude\settings.json   env.ANTHROPIC_BASE_URL -> loopback
      - %APPDATA%\Claude\claude_desktop_config.json  mcpServers.zax  (Desktop channel;
        only targeted if that folder exists — see agent_configs.rs's `Resolved::ClaudeUserData`,
        which only resolves roots already present on disk)

    Ground truth: ai-gateway/util/src/agent_configs.rs AGENTS["claude"].
#>
param([switch] $Live, [switch] $KeepLogs, [int] $Rescan = 3)
. "$PSScriptRoot\common-agents.ps1"

Invoke-AgentE2E -AgentId 'claude' -Live:$Live -KeepLogs:$KeepLogs -Rescan $Rescan `
    -FixtureSetup {
        param($AgentHome)
        # Claude Code's own marker.
        New-Item -ItemType File -Force -Path (Join-Path $AgentHome '.claude.json') | Out-Null
        # Claude Desktop app-install marker (mirrors integration.ps1's fixture).
        $claudeApp = Join-Path $AgentHome 'AppData\Local\AnthropicClaude\app-1.0.0-fixture'
        Ensure-Dir $claudeApp
        Set-Content -Path (Join-Path $claudeApp 'claude.exe') -Value 'stub' -Encoding ascii
        # Claude Desktop's config-data root — only a root that EXISTS is
        # targeted by the ClaudeUserData resolver, so create it empty.
        Ensure-Dir (Join-Path $AgentHome 'AppData\Roaming\Claude')
    } `
    -WiringCheck {
        param($AgentHome)

        Invoke-ACheck "~\.claude.json has mcpServers.zax with type+alwaysLoad" {
            $p = Join-Path $AgentHome '.claude.json'
            if (-not (Test-Path $p)) { return $false }
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            $zax = Get-JsonPath $doc @('mcpServers', 'zax')
            $null -ne $zax -and $null -ne $zax.command -and $null -ne $zax.type -and $null -ne $zax.alwaysLoad
        }

        Invoke-ACheck "~\.claude\settings.json env.ANTHROPIC_BASE_URL is a loopback URL" {
            $p = Join-Path $AgentHome '.claude\settings.json'
            if (-not (Test-Path $p)) { return $false }
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            Test-IsLoopbackUrl (Get-JsonPath $doc @('env', 'ANTHROPIC_BASE_URL'))
        }

        $desktopCfg = Join-Path $AgentHome 'AppData\Roaming\Claude\claude_desktop_config.json'
        if (Test-Path $desktopCfg) {
            Invoke-ACheck "Claude Desktop's claude_desktop_config.json has mcpServers.zax" {
                $doc = Get-Content -Raw $desktopCfg | ConvertFrom-Json
                $null -ne (Get-JsonPath $doc @('mcpServers', 'zax'))
            }
        } else {
            Skip-ACheck "Claude Desktop's claude_desktop_config.json" "file never appeared — resolver found no existing Roaming\Claude root to target"
        }
    }

Complete-AgentRun
