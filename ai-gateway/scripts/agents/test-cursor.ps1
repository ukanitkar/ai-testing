<#
.SYNOPSIS
    End-to-end test for Cursor wiring.

.DESCRIPTION
    Detection tier always runs. Wiring tier (-Live) asserts:
      - ~\.cursor\mcp.json           mcpServers.zax  {command,args,env}

    ⚠️ IMPORTANT LIMITATION: this script's -Live run drives `zax-sim.exe`, a
    lightweight stand-in for ai-protect's role (see ..\integration.ps1). The
    simulator's apply logic (ai-gateway/simulator/src/apply.rs) implements
    ONLY `ConfigDelta` (file-based Mcp/Llm rendering) — it has no code path
    for `process_env` at all. Cursor's LLM leg is PURE process-env (no config
    file — cursor.rs's `config()` deliberately emits only the MCP leg), and
    that delivery mechanism (HKCU\Environment + a `function cursor-agent`
    profile.ps1 wrapper) lives ONLY in the real ai-protect daemon's
    `src/ai_broker_env/`, which the simulator does not link against.

    So the LLM leg CANNOT be exercised via -Live against the simulator —
    this script SKIPS it there with an explicit reason rather than reporting
    a false FAIL. Verifying it for real needs a separate harness against the
    actually-installed `zscaler-ai-protect` service (MSI-installed on this
    VM), with `ai_broker.enabled`/`ai_broker.process_env` turned on via a
    real or mocked settings.received frame — not built here; flagged as a
    genuine gap, not an oversight. If/when that harness exists, it should
    check:
      - HKCU\Environment: HTTPS_PROXY / HTTP_PROXY (loopback, http:// even
        though the listener is https — CONNECT proxies are addressed over
        plain http), NODE_EXTRA_CA_CERTS (a real path), and the fixed
        literal NODE_USE_ENV_PROXY=1
      - profile.ps1 (both PS editions) carries a `function cursor-agent`
        wrapper — the per-command scoping the flat registry sweep can't
        offer on its own (src/ai_broker_env/windows_profile.rs)

    ⚠️ cursor.rs's own doc comment separately flags the GUI editor's own
    AI-chat panel as UNVERIFIED against these env vars even once delivered —
    a future real-daemon harness can only confirm delivery, not that
    Cursor's chat panel honors it live.

    Ground truth: ai-gateway/util/src/agent_configs.rs AGENTS["cursor"],
    ai-gateway/agent-manager/src/agents/cursor.rs, src/ai_broker_env/windows.rs,
    ai-gateway/simulator/src/apply.rs (confirms the simulator gap).
#>
param([switch] $Live, [switch] $KeepLogs, [int] $Rescan = 3)
. "$PSScriptRoot\common-agents.ps1"

Invoke-AgentE2E -AgentId 'cursor' -Live:$Live -KeepLogs:$KeepLogs -Rescan $Rescan `
    -FixtureSetup {
        param($AgentHome)
        Ensure-Dir (Join-Path $AgentHome '.cursor')
    } `
    -WiringCheck {
        param($AgentHome)

        Invoke-ACheck "~\.cursor\mcp.json has mcpServers.zax" {
            $p = Join-Path $AgentHome '.cursor\mcp.json'
            if (-not (Test-Path $p)) { return $false }
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            $zax = Get-JsonPath $doc @('mcpServers', 'zax')
            $null -ne $zax -and $null -ne $zax.command
        }

        Invoke-ACheck "~\.cursor\mcp.json has NO llm delta (leg rides process-env instead)" {
            $p = Join-Path $AgentHome '.cursor\mcp.json'
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            $null -eq (Get-JsonPath $doc @('env', 'HTTPS_PROXY')) -and $null -eq (Get-JsonPath $doc @('proxyUrl'))
        }

        $reason = "process_env has no path through zax-sim.exe's apply.rs — needs a real-daemon harness, see this script's header"
        Skip-ACheck "HKCU:\Environment HTTPS_PROXY / HTTP_PROXY are loopback" $reason
        Skip-ACheck "HKCU:\Environment NODE_USE_ENV_PROXY = 1" $reason
        Skip-ACheck "HKCU:\Environment NODE_EXTRA_CA_CERTS points at a real file" $reason
        Skip-ACheck "a PowerShell profile.ps1 carries a cursor-agent wrapper function" $reason
    }

Complete-AgentRun
