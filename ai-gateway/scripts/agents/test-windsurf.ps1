<#
.SYNOPSIS
    End-to-end test for Windsurf (and its Devin Desktop rebrand) wiring.

.DESCRIPTION
    Detection tier always runs. Wiring tier (-Live) asserts:
      - ~\.codeium\windsurf\mcp_config.json   mcpServers.zax  {command,args,env}
        (branding-agnostic — this path is untouched by the Windsurf->Devin
        Desktop rename)
      - EITHER %APPDATA%\Windsurf\User\settings.json OR
        %APPDATA%\Devin\User\settings.json (Devin-first if BOTH exist — see
        `Resolved::WindsurfUserData` in ai_broker_launch.rs) has
        http.proxy -> loopback (http://, CONNECT-proxy form) AND
        http.proxySupport == "override"

    ⚠️ This is the one adapter with runtime (not compile-time) dispatch
    between two on-disk targets — the fixture below creates ONLY the legacy
    Windsurf userData root, so the resolver has exactly one candidate and the
    Devin-first precedence itself is NOT exercised by this script. If you
    want to verify the Devin-first tie-break specifically, also create
    `<AgentHome>\AppData\Roaming\Devin\User` before running with -Live and
    confirm the assertion below picks the Devin path, not the Windsurf one.

    ⚠️ No CA-trust key exists for either branding (windsurf.rs's own doc:
    VS Code forks trust the OS system cert store instead) — unverified
    against a live install whether that's actually sufficient.

    Ground truth: ai-gateway/util/src/agent_configs.rs AGENTS["windsurf"],
    ai-gateway/agent-manager/src/agents/windsurf.rs,
    src/subscribers/ai_broker_launch.rs (config_delta_targets / Resolved::WindsurfUserData).
#>
param([switch] $Live, [switch] $KeepLogs, [int] $Rescan = 3)
. "$PSScriptRoot\common-agents.ps1"

Invoke-AgentE2E -AgentId 'windsurf' -Live:$Live -KeepLogs:$KeepLogs -Rescan $Rescan `
    -FixtureSetup {
        param($AgentHome)
        # Identity via the codeium.codeium VS Code extension (version in the
        # directory name, same trick as ..\integration.ps1's devin fixture).
        $ext = Join-Path $AgentHome '.vscode\extensions\codeium.codeium-1.0.0-fixture'
        Ensure-Dir $ext
        '{"name":"codeium","version":"1.0.0-fixture"}' | Set-Content -Path (Join-Path $ext 'package.json') -Encoding utf8
        Ensure-Dir (Join-Path $AgentHome '.codeium\windsurf')
        # Legacy Windsurf userData root — the resolver only targets a root
        # that already exists on disk. Create only this one (see header:
        # the Devin-first tie-break itself is not exercised by this fixture).
        Ensure-Dir (Join-Path $AgentHome 'AppData\Roaming\Windsurf\User')
    } `
    -WiringCheck {
        param($AgentHome)

        Invoke-ACheck "~\.codeium\windsurf\mcp_config.json has mcpServers.zax" {
            $p = Join-Path $AgentHome '.codeium\windsurf\mcp_config.json'
            if (-not (Test-Path $p)) { return $false }
            $doc = Get-Content -Raw $p | ConvertFrom-Json
            $zax = Get-JsonPath $doc @('mcpServers', 'zax')
            $null -ne $zax -and $null -ne $zax.command
        }

        Invoke-ACheck "the branded User\settings.json (Windsurf or Devin) has http.proxy + http.proxySupport" {
            $candidates = @(
                (Join-Path $AgentHome 'AppData\Roaming\Devin\User\settings.json'),
                (Join-Path $AgentHome 'AppData\Roaming\Windsurf\User\settings.json')
            )
            $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $found) { Write-AWarn 'neither branded settings.json exists'; return $false }
            Write-ANote "resolved to: $found"
            $doc = Get-Content -Raw $found | ConvertFrom-Json
            # `http.proxy` is a literal DOTTED key (JSON property name
            # containing a dot), not a nested object — index it directly.
            $proxy = $doc.PSObject.Properties['http.proxy']?.Value
            $support = $doc.PSObject.Properties['http.proxySupport']?.Value
            (Test-IsLoopbackUrl $proxy) -and ($support -eq 'override')
        }
    }

Complete-AgentRun
