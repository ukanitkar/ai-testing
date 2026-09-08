<#
.SYNOPSIS
    End-to-end test for Devin CLI wiring.

.DESCRIPTION
    Detection tier always runs. Wiring tier (-Live) asserts:
      - %APPDATA%\devin\mcp_config.json   mcpServers.zax  {command,args,env,type,alwaysLoad}
      - %APPDATA%\devin\config.json        proxy.url -> loopback, proxy.mode == "manual"
        (Devin's documented schema has NO `env` block at all; the real
        redirect is a top-level `proxy` object — `mode: "manual"` MUST
        accompany `url` or Devin ignores it, per devin.rs's own doc comment
        correcting an earlier, wrong `env.ANTHROPIC_BASE_URL` assumption)

    ⚠️ devin.rs flags NO documented CA-trust key for Devin at all — if
    Devin's HTTP client rejects the intercepting cert, the leg fails closed
    (broken LLM calls) with no config-side fix. This script cannot verify
    that live (needs a real completion to actually round-trip); it only
    confirms the proxy pointer was delivered.

    Ground truth: ai-gateway/util/src/agent_configs.rs AGENTS["devin"],
    ai-gateway/agent-manager/src/agents/devin.rs.
#>
param([switch] $Live, [switch] $KeepLogs, [int] $Rescan = 3)
. "$PSScriptRoot\common-agents.ps1"

Invoke-AgentE2E -AgentId 'devin' -Live:$Live -KeepLogs:$KeepLogs -Rescan $Rescan `
    -FixtureSetup {
        param($AgentHome)
        # Devin ships as a VS Code extension; the version is in the dir name
        # (mirrors ..\integration.ps1's own fixture for this exact agent).
        $devinExt = Join-Path $AgentHome '.vscode\extensions\shayanline.devin-vscode-0.11.0'
        Ensure-Dir $devinExt
        '{"name":"devin-vscode","version":"0.11.0"}' | Set-Content -Path (Join-Path $devinExt 'package.json') -Encoding utf8
        Ensure-Dir (Join-Path $AgentHome 'AppData\Roaming\devin')
    } `
    -WiringCheck {
        param($AgentHome)

        Invoke-ACheck "%APPDATA%\devin\mcp_config.json has mcpServers.zax with type+alwaysLoad" {
            $p = Join-Path $AgentHome 'AppData\Roaming\devin\mcp_config.json'
            if (-not (Test-Path $p)) { return $false }
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            $zax = Get-JsonPath $doc @('mcpServers', 'zax')
            $null -ne $zax -and $null -ne $zax.command -and $null -ne $zax.type -and $null -ne $zax.alwaysLoad
        }

        Invoke-ACheck "%APPDATA%\devin\config.json proxy.url is loopback AND proxy.mode == manual" {
            $p = Join-Path $AgentHome 'AppData\Roaming\devin\config.json'
            if (-not (Test-Path $p)) { return $false }
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            (Test-IsLoopbackUrl (Get-JsonPath $doc @('proxy', 'url'))) -and
            ((Get-JsonPath $doc @('proxy', 'mode')) -eq 'manual')
        }

        Invoke-ACheck "%APPDATA%\devin\config.json has no env block (Devin's schema has none)" {
            $p = Join-Path $AgentHome 'AppData\Roaming\devin\config.json'
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            $null -eq (Get-JsonPath $doc @('env'))
        }
    }

Complete-AgentRun
