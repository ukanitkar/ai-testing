<#
.SYNOPSIS
    End-to-end test for Codex CLI wiring.

.DESCRIPTION
    Detection tier always runs. Wiring tier (-Live) asserts, in
    ~\.codex\config.toml (TOML, not JSON):
      - [mcp_servers.zax]      command = "..."  (Entry::Plain)
      - [model_providers.zax]  name = "zax", base_url -> loopback, wire_api = "responses"
      - top-level               model_provider = "zax"

    `wire_api = "responses"` is asserted literally — codex.rs's own doc
    comment confirms this against Codex's real upstream source (Chat
    Completions was removed entirely; `WireApi` has exactly one variant).

    ⚠️ codex.rs separately flags two UNVERIFIED-from-this-repo risks this
    script cannot check: (1) whether the broker backend genuinely relays
    Responses-shape traffic to a real OpenAI-compatible endpoint, and (2) a
    `CODEX_HOME`-relocated install is not reached by this leg at all (the
    registry only resolves the fixed `~/.codex/config.toml`). This script
    assumes the default, non-relocated path.

    Ground truth: ai-gateway/util/src/agent_configs.rs AGENTS["codex"],
    ai-gateway/agent-manager/src/agents/codex.rs.
#>
param([switch] $Live, [switch] $KeepLogs, [int] $Rescan = 3)
. "$PSScriptRoot\common-agents.ps1"

Invoke-AgentE2E -AgentId 'codex' -Live:$Live -KeepLogs:$KeepLogs -Rescan $Rescan `
    -FixtureSetup {
        param($AgentHome)
        New-NpmPackageFixture -HomeDir $AgentHome -Name '@openai/codex' -Version '0.9.9-fixture'
        Ensure-Dir (Join-Path $AgentHome '.codex')
    } `
    -WiringCheck {
        param($AgentHome)
        $p = Join-Path $AgentHome '.codex\config.toml'

        Invoke-ACheck "~\.codex\config.toml has [mcp_servers.zax] with a command" {
            if (-not (Test-Path $p)) { return $false }
            $t = Read-TomlTable -Path $p -Table 'mcp_servers.zax'
            $null -ne $t -and $t.ContainsKey('command')
        }

        Invoke-ACheck "~\.codex\config.toml has [model_providers.zax] with base_url -> loopback, wire_api = responses" {
            $t = Read-TomlTable -Path $p -Table 'model_providers.zax'
            if (-not $t) { return $false }
            (Test-IsLoopbackUrl $t['base_url']) -and ($t['wire_api'] -eq 'responses') -and ($t['name'] -eq 'zax')
        }

        Invoke-ACheck "~\.codex\config.toml top-level model_provider = zax" {
            (Read-TomlScalar -Path $p -Key 'model_provider') -eq 'zax'
        }
    }

Complete-AgentRun
