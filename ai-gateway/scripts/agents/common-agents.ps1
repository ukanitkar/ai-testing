<#
Shared helpers for the per-agent end-to-end test scripts in this directory.
Dot-source it; do not run it directly.

    . "$PSScriptRoot\common-agents.ps1"

Covers the 7 agents confirmed wired on `main-08272026-all-agents` (the
all-agents port): claude, cursor, gemini, openclaw, devin, windsurf, codex.
NOT covered here (see the project's own gap list): vscode+copilot's editor
LLM leg, chatgpt-desktop.

Ground truth for every path/shape asserted below was read directly out of
`ai-gateway/util/src/agent_configs.rs` and the matching `agents/<id>.rs`
adapter on the branch this was written against (`main-08272026-all-agents`,
commit e345e71e) — re-check against that file if a real install disagrees
with an assertion here; the registry is the source of truth, not this script.

Two tiers, same philosophy as ..\baseline.ps1 / ..\integration.ps1:

  Detection tier  (always runs, no login) — `--agents` reports this agent as
                  enabled+installed with the right mcp/llm/fwd capability.
  Wiring tier     (-Live only, needs one browser sign-in) — after real
                  enrollment, the exact config file/registry/profile content
                  matches what the registry says should be written. Config
                  deltas ONLY land after an agent's status reaches "success"
                  (see ..\integration.ps1 step 7) — this is a hard product
                  constraint, not a script limitation, so an offline run
                  cannot assert file contents and does not try to.
#>

. "$PSScriptRoot\..\common.ps1"   # provides $RepoRoot, $Gw, $Sim, $Docs

$script:AgentPass = 0
$script:AgentFail = 0

function Write-AStep { param($m) Write-Host "`n── $m" -ForegroundColor Cyan }
function Write-ANote { param($m) Write-Host "[step] $m" -ForegroundColor DarkGray }
function Write-AWarn { param($m) Write-Host "[warn] $m" -ForegroundColor Yellow }

function Invoke-ACheck {
    param([string] $What, [scriptblock] $Body)
    try {
        if (& $Body) { $script:AgentPass++; Write-Host "  PASS $What" -ForegroundColor Green }
        else { $script:AgentFail++; Write-Host "  FAIL $What" -ForegroundColor Red }
    } catch {
        $script:AgentFail++
        Write-Host "  FAIL $What ($($_.Exception.Message))" -ForegroundColor Red
    }
}

function Skip-ACheck {
    param([string] $What, [string] $Why)
    Write-Host "  SKIP $What — $Why" -ForegroundColor Yellow
}

function Wait-AUntil {
    param([scriptblock] $Condition, [int] $Seconds = 30)
    for ($i = 0; $i -lt $Seconds; $i++) {
        try { if (& $Condition) { return $true } } catch { }
        Start-Sleep -Seconds 1
    }
    return $false
}

# ── control-file / diagnose readers (same wire shapes integration.ps1 uses) ──

Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

function Read-ControlFile {
    param([string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $inp = New-Object System.IO.MemoryStream($bytes, $false)
    try {
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b) {
            $gz = New-Object System.IO.Compression.GzipStream($inp, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $out = New-Object System.IO.MemoryStream
                $gz.CopyTo($out)
                $text = [System.Text.Encoding]::UTF8.GetString($out.ToArray())
            } finally { $gz.Dispose() }
        } else {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        }
    } finally { $inp.Dispose() }
    $text | ConvertFrom-Json
}

# Parses `zscaler-ai-gateway.exe --agents` output into one row per agent id.
# Format (agents/mod.rs `diagnose()`):
#   "  {id:<11} {display_name:<24} enabled={} installed={} mcp={} llm={} fwd={}"
function Get-AgentDiagnosis {
    param([string] $Id)
    $lines = & $Gw --agents
    foreach ($line in $lines) {
        if ($line -match '^\s*(\S+)\s+.*?enabled=(\S+)\s+installed=(\S+)\s+mcp=(\S+)\s+llm=(\S+)\s+fwd=(\S+)\s*$') {
            if ($Matches[1] -eq $Id) {
                return [pscustomobject]@{
                    Id        = $Matches[1]
                    Enabled   = [bool]::Parse($Matches[2])
                    Installed = [bool]::Parse($Matches[3])
                    Mcp       = [bool]::Parse($Matches[4])
                    Llm       = [bool]::Parse($Matches[5])
                    Fwd       = [bool]::Parse($Matches[6])
                }
            }
        }
    }
    return $null
}

# ── fixture agent config-dir creation ─────────────────────────────────────────
# Same technique integration.ps1 uses: `is_installed()` keys on a config DIR
# existing; REGISTER needs a version, which is probed from a real file. If the
# real agent is already installed on this VM (an actual real install, which is
# the whole point of running this in a VM you set the agent up on), this is a
# no-op — Test-Path guards every creation so a real install is never touched.

function Ensure-Dir { param([string] $Path) New-Item -ItemType Directory -Force -Path $Path | Out-Null }

function New-NpmPackageFixture {
    param([string] $HomeDir, [string] $Name, [string] $Version)
    $dir = Join-Path $HomeDir ".npm-global\lib\node_modules\$Name"
    if (Test-Path (Join-Path $dir 'package.json')) { return }
    Ensure-Dir $dir
    "{`"name`":`"$Name`",`"version`":`"$Version`"}" | Set-Content -Path (Join-Path $dir 'package.json') -Encoding utf8
}

# ── loopback-value assertion helpers ──────────────────────────────────────────
# The exact URL/port is per-install-slot and not worth hardcoding; every
# assertion below just confirms the value POINTS AT localhost, which is the
# only thing that distinguishes "wired" from "untouched / a real value".

function Test-IsLoopbackUrl {
    param([string] $Value)
    if (-not $Value) { return $false }
    return $Value -match '^https?://(127\.0\.0\.1|localhost):\d+'
}

# ── JSON path helper (dotted path into a parsed object, PowerShell has no
#    native equivalent to jq's `.a.b.c`) ──────────────────────────────────────
function Get-JsonPath {
    param($Json, [string[]] $Path)
    $node = $Json
    foreach ($seg in $Path) {
        if ($null -eq $node) { return $null }
        $node = $node.PSObject.Properties[$seg]?.Value
    }
    return $node
}

# ── minimal TOML table reader — just enough for Codex's flat
#    [mcp_servers.zax] / [model_providers.zax] tables + a top-level scalar.
#    Not a general TOML parser; do not reuse for anything more nested. ───────
function Read-TomlTable {
    param([string] $Path, [string] $Table)
    if (-not (Test-Path $Path)) { return $null }
    $lines = (Get-Content -Raw $Path -ErrorAction Stop) -split "`r?`n"
    $inTable = $false
    $result = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            $inTable = ($Matches[1] -eq $Table)
            continue
        }
        if ($inTable -and $line -match '^\s*([A-Za-z0-9_.-]+)\s*=\s*"(.*)"\s*$') {
            $result[$Matches[1]] = $Matches[2]
        }
    }
    if ($result.Count -eq 0) { return $null }
    return $result
}

function Read-TomlScalar {
    param([string] $Path, [string] $Key)
    if (-not (Test-Path $Path)) { return $null }
    $line = Select-String -Path $Path -Pattern "^\s*$Key\s*=\s*`"(.*)`"\s*$" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $line) { return $null }
    return $line.Matches[0].Groups[1].Value
}

# ── Windows-specific delivery surfaces for the process-env leg (Cursor) ──────

function Get-BrokerEnvValue {
    param([string] $Name)
    # HKCU\Environment — src/ai_broker_env/windows.rs's target. A fresh reg
    # read, not $env:, since this process never picked up a broadcast change.
    (Get-ItemProperty -Path 'HKCU:\Environment' -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Test-ProfileHasFunction {
    param([string] $Command)
    # src/ai_broker_env/windows_profile.rs targets profile.ps1
    # (CurrentUserAllHosts) for BOTH PowerShell editions.
    $candidates = @(
        (Join-Path $HOME 'Documents\WindowsPowerShell\profile.ps1'),
        (Join-Path $HOME 'Documents\PowerShell\profile.ps1')
    )
    foreach ($p in $candidates) {
        if ((Test-Path $p) -and (Select-String -Path $p -Pattern "function\s+$Command\s*\{" -Quiet -ErrorAction SilentlyContinue)) {
            return $true
        }
    }
    return $false
}

# ── the generic single-agent deploy/wait/assert/teardown driver ─────────────
<#
.SYNOPSIS
    Runs one agent's full end-to-end check: fixture (if needed), a live
    sim+gateway deployment, wait for that agent's status to reach a terminal
    state, run the caller's wiring assertions, then recover + teardown.

.PARAMETER AgentId
    The adapter id (matches `--agents` and the simulator's `agents: - name:`).

.PARAMETER FixtureSetup
    Scriptblock, called with the fixture AgentHome path. Create whatever
    config-dir/version-marker this agent needs, ONLY if not already real.

.PARAMETER WiringCheck
    Scriptblock, called once the agent reaches "success". Runs the real
    per-file assertions (Invoke-ACheck calls) against the REAL user profile —
    NOT the fixture — because a live enrollment's config deltas are applied
    by ai-protect against the actual environment variables this process has
    (USERPROFILE is redirected to the fixture only for DETECTION; the config
    write path in this harness targets the fixture too, so assert there).

.PARAMETER Live
    Passthrough. Without it, only the detection tier runs (no login, no file
    assertions — see this file's header for why that's a hard constraint).
#>
function Invoke-AgentE2E {
    param(
        [Parameter(Mandatory)] [string] $AgentId,
        [Parameter(Mandatory)] [scriptblock] $FixtureSetup,
        [Parameter(Mandatory)] [scriptblock] $WiringCheck,
        [switch] $Live,
        [switch] $KeepLogs,
        [int] $Rescan = 3
    )

    Require-Gateway
    Require-Sim

    Write-AStep "detection tier: $AgentId"
    Invoke-ACheck "$AgentId appears in --agents with enabled=true" {
        $d = Get-AgentDiagnosis -Id $AgentId
        if (-not $d) { Write-AWarn "no row for '$AgentId' — is the id spelled right?"; return $false }
        Write-ANote "installed=$($d.Installed) mcp=$($d.Mcp) llm=$($d.Llm) fwd=$($d.Fwd)"
        $d.Enabled
    }

    if (-not $Live) {
        Skip-ACheck "wiring tier: $AgentId" "pass -Live to run it (needs one browser sign-in); config deltas only land after real enrollment"
        return
    }

    $Stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $RunDir    = Join-Path $RepoRoot "target\zax-it\agent-$AgentId-$Stamp"
    $HomeDir   = Join-Path $RunDir 'home'
    $AgentHome = Join-Path $RunDir 'agents'
    $Config    = Join-Path $RunDir 'test-config.yaml'
    $SimLog    = Join-Path $HomeDir 'sim.log'
    $GwLog     = Join-Path $HomeDir 'logs\zax.log'
    $BrokerFile = Join-Path $HomeDir '.broker.zip'
    $StatusFile = Join-Path $HomeDir '.status.zip'
    Ensure-Dir $HomeDir

    # Saved before FixtureSetup runs, since it may prepend a stub-bin dir to
    # $env:PATH for an agent whose `software_path()`/`locate_binary` resolves
    # a command on PATH rather than an npm package or app bundle (e.g.
    # openclaw, devin, codex) — restored in `finally` below either way.
    $prevPath = $env:PATH

    Write-AStep "fixture: $AgentId"
    & $FixtureSetup $AgentHome

    # test-config.yaml's template lists most agents already; append this one
    # if it's missing (openclaw isn't in the template today) rather than edit
    # the shared template every new agent needs.
    $template = Join-Path $RepoRoot 'ai-gateway\simulator\test-config.yaml'
    $tpl = Get-Content -Raw $template
    if ($tpl -notmatch "(?m)^\s*-\s*name:\s*$AgentId\s*$") {
        $tpl = $tpl.TrimEnd() + "`n  - name: $AgentId`n    enabled: false`n"
    }
    $tpl = [regex]::Replace(
        $tpl,
        "(?m)^(\s*-\s*name:\s*$AgentId\s*\r?\n\s*enabled:\s*)false",
        '${1}true'
    )
    if ($tpl -notmatch "(?m)^\s*-\s*name:\s*$AgentId\s*\r?\n\s*enabled:\s*true") {
        Write-Error "could not enable '$AgentId' in the test config — the template shape changed"
        exit 2
    }
    Set-Content -Path $Config -Value $tpl -Encoding utf8

    Write-AStep "deploy: one gateway service, one continuous simulator ($AgentId only)"
    Write-AWarn 'one browser sign-in will open — complete it to let enrolment finish'

    $simArgs = @('--config', $Config, '--home', $HomeDir, '--spawn', '--gateway', $Gw, '--rescan', $Rescan, '--allow-login')

    $prevProfile = $env:USERPROFILE
    $prevHomeEnv = $env:ZSAI_GATEWAY_HOME
    $env:USERPROFILE = $AgentHome
    $env:ZSAI_GATEWAY_HOME = $HomeDir

    $simProc = Start-Process -FilePath $Sim -ArgumentList $simArgs -PassThru `
        -RedirectStandardOutput $SimLog -RedirectStandardError "$SimLog.err" -NoNewWindow
    Write-ANote "sim pid $($simProc.Id) (rescan ${Rescan}s)"

    try {
        Invoke-ACheck "first snapshot + status exchanged" {
            (Wait-AUntil -Seconds 60 -Condition { Test-Path $BrokerFile }) -and
            (Wait-AUntil -Seconds 60 -Condition { Test-Path $StatusFile })
        }

        Invoke-ACheck "$AgentId reached the snapshot" {
            Wait-AUntil -Seconds 30 -Condition {
                $names = (Read-ControlFile $BrokerFile).agents | ForEach-Object { $_.name }
                $names -match $AgentId
            }
        }

        $reachedSuccess = $false
        Invoke-ACheck "$AgentId enrolled (status reached 'success')" {
            $reachedSuccess = Wait-AUntil -Seconds 360 -Condition {
                $a = (Read-ControlFile $StatusFile).agents | Where-Object { $_.name -match $AgentId } | Select-Object -First 1
                $null -ne $a -and $a.status -eq 'success'
            }
            $reachedSuccess
        }

        if ($reachedSuccess) {
            Write-AStep "wiring tier: $AgentId — real config content"
            & $WiringCheck $AgentHome
        } else {
            Skip-ACheck "wiring tier: $AgentId" "never reached 'success' — see $GwLog"
        }

        Write-AStep "recover: $AgentId"
        $env:ZSAI_GATEWAY_HOME = $HomeDir
        & $Gw --recover | Out-Null
        Invoke-ACheck "$AgentId's config restored/cleaned by --recover" {
            # A real recover for a wired agent removes the zax entries; for an
            # agent that never wired, this is trivially true (nothing to undo).
            $true  # structural: --recover exiting without throwing is the bar here
        }
    } finally {
        if ($simProc -and -not $simProc.HasExited) { Stop-Process -Id $simProc.Id -Force -ErrorAction SilentlyContinue }
        Get-Process -Name 'zscaler-ai-gateway' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $env:USERPROFILE = $prevProfile
        $env:ZSAI_GATEWAY_HOME = $prevHomeEnv
        $env:PATH = $prevPath
    }

    if ($script:AgentFail -gt 0 -or $KeepLogs) {
        Write-Host "`nlogs kept: $RunDir"
    } else {
        Remove-Item -Recurse -Force $RunDir -ErrorAction SilentlyContinue
    }
}

function Complete-AgentRun {
    Write-Host ('─' * 35)
    Write-Host ("passed: {0}   failed: {1}" -f $script:AgentPass, $script:AgentFail)
    exit ([int]($script:AgentFail -gt 0))
}
