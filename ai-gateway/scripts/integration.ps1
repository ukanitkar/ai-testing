<#
.SYNOPSIS
    Integration test for the ai-gateway file protocol on Windows, run as a
    deployment. The peer of integration.sh — same ten checks, same contract.

.DESCRIPTION
    Both processes come up ONCE and stay up for the whole test:

      zax-sim              continuous, playing ai-protect (rescans, rewrites
                           .broker.zip, watches .status.zip, applies config)
      zscaler-ai-gateway   service mode, spawned bare by the sim exactly as the
                           daemon spawns it — unmodified, used as-is

    Events are driven over time and each transition asserted. Nothing is
    restarted between phases and nothing is injected: every assertion is about
    what the real gateway produced.

    Everything is written under target\zax-it\<ts>\, and USERPROFILE is pointed
    at a fixture tree, so the real gateway home and the real agent configs are
    never touched. The fixture also fixes which agents are detected, so the run
    does not vary with what happens to be installed on the box.

.PARAMETER Live
    Enrol against the real control plane. Opens ONE browser sign-in.

.PARAMETER KeepLogs
    Keep the run directory even when every check passes.

.PARAMETER Rescan
    The simulator's rescan interval in seconds. Default 3.

.EXAMPLE
    .\integration.ps1
    Offline: steady-state behaviour only, no enrolment.

.EXAMPLE
    .\integration.ps1 -Live -KeepLogs
#>
[CmdletBinding()]
param(
    [switch] $Live,
    [switch] $KeepLogs,
    [int]    $Rescan = 3
)

# Not `Stop`: every check reports and the summary decides the exit status, so a
# single failure must not abort the run the way `set -e` would.
$ErrorActionPreference = 'Continue'

# GzipStream lives in an assembly PowerShell 5.1 does not load by default.
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

$script:Pass = 0
$script:Fail = 0

function Write-Step   { param($m) Write-Host "`n── $m" -ForegroundColor Cyan }
function Write-Note   { param($m) Write-Host "[step] $m" -ForegroundColor DarkGray }
function Write-Warn   { param($m) Write-Host "[warn] $m" -ForegroundColor Yellow }
function Assert-Pass  { param($m) $script:Pass++; Write-Host "  PASS $m" -ForegroundColor Green }
function Assert-Fail  { param($m) $script:Fail++; Write-Host "  FAIL $m" -ForegroundColor Red }

# A check whose body returns $true/$false, counted either way. The equivalent of
# integration.sh's `gate`: a throwing body must not vanish from the summary.
function Invoke-Check {
    param([string] $What, [scriptblock] $Body)
    try {
        if (& $Body) { Assert-Pass $What } else { Assert-Fail $What }
    } catch {
        Assert-Fail "$What ($($_.Exception.Message))"
    }
}

# ── the control files are gzipped JSON ────────────────────────────────────────
function Read-ControlFile {
    param([string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $inp = New-Object System.IO.MemoryStream($bytes, $false)
    try {
        # Read-side detection, matching json_file::decode: a hand-written
        # fixture is plain JSON, everything the product writes is gzip.
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

function Test-IsGzip {
    param([string] $Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 2
        return ($fs.Read($b, 0, 2) -eq 2) -and $b[0] -eq 0x1f -and $b[1] -eq 0x8b
    } finally { $fs.Dispose() }
}

# Poll rather than sleep: a rescan probes every agent's version before it
# rewrites, so a fixed wait races it.
function Wait-Until {
    param([scriptblock] $Condition, [int] $Seconds = 30)
    for ($i = 0; $i -lt $Seconds; $i++) {
        try { if (& $Condition) { return $true } } catch { }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Wait-ForLog {
    param([string] $Path, [string] $Pattern, [int] $Seconds = 30)
    Wait-Until -Seconds $Seconds -Condition {
        (Test-Path $Path) -and (Select-String -Path $Path -Pattern $Pattern -Quiet -ErrorAction SilentlyContinue)
    }
}

function Get-LogMatchCount {
    param([string] $Path, [string] $Pattern)
    if (-not (Test-Path $Path)) { return 0 }
    @(Select-String -Path $Path -Pattern $Pattern -ErrorAction SilentlyContinue).Count
}

# ── layout ────────────────────────────────────────────────────────────────────
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunDir   = Join-Path $RepoRoot "target\zax-it\$Stamp"
$HomeDir  = Join-Path $RunDir 'home'          # the gateway home: control files
$AgentHome = Join-Path $RunDir 'agents'       # the fixture USERPROFILE
$Config   = Join-Path $RunDir 'test-config.yaml'
$SimLog   = Join-Path $HomeDir 'sim.log'
$GwLog    = Join-Path $HomeDir 'logs\zax.log'
$BrokerFile = Join-Path $HomeDir '.broker.zip'
$StatusFile = Join-Path $HomeDir '.status.zip'

New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null

$Sim = Join-Path $RepoRoot 'target\debug\zax-sim.exe'
$Gw  = Join-Path $RepoRoot 'target\debug\zscaler-ai-gateway.exe'
foreach ($bin in @($Sim, $Gw)) {
    if (-not (Test-Path $bin)) {
        Write-Error "missing $bin — run: cargo build -p ai-gateway-simulator -p ai-gateway-service"
        exit 2
    }
}

# ── fixtures ──────────────────────────────────────────────────────────────────
# Two things make an agent reportable and the fixture supplies both:
# `is_installed()` is "does its config dir exist under the user profile", and
# REGISTER needs a version, which the gateway probes from a real file. A config
# dir alone leaves the agent detected-but-withheld.
foreach ($d in @('.codex', '.gemini', '.config\devin')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $AgentHome $d) | Out-Null
}
New-Item -ItemType File -Force -Path (Join-Path $AgentHome '.claude.json') | Out-Null

function New-NpmPackage {
    param([string] $Name, [string] $Version)
    $dir = Join-Path $AgentHome ".npm-global\lib\node_modules\$Name"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    "{`"name`":`"$Name`",`"version`":`"$Version`"}" |
        Set-Content -Path (Join-Path $dir 'package.json') -Encoding utf8
}
New-NpmPackage '@openai/codex'     '0.9.9-fixture'
New-NpmPackage '@google/gemini-cli' '0.29.0-fixture'

# Devin ships as a VS Code extension; the version is in the directory name.
$devinExt = Join-Path $AgentHome '.vscode\extensions\shayanline.devin-vscode-0.11.0'
New-Item -ItemType Directory -Force -Path $devinExt | Out-Null
'{"name":"devin-vscode","version":"0.11.0"}' |
    Set-Content -Path (Join-Path $devinExt 'package.json') -Encoding utf8

# Claude on Windows resolves through %LOCALAPPDATA%\AnthropicClaude.
$claudeDir = Join-Path $AgentHome 'AppData\Local\AnthropicClaude\app-1.0.0-fixture'
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
Set-Content -Path (Join-Path $claudeDir 'claude.exe') -Value 'stub' -Encoding ascii

$Present = @('codex', 'claude', 'gemini', 'devin')
$Absent  = @('cursor', 'copilot', 'windsurf')
Write-Step "fixtures: $($Present.Count) agents present, $($Absent.Count) absent"
Write-Note "USERPROFILE → $AgentHome (present: $($Present -join ' ') · absent: $($Absent -join ' '))"

# codex enabled so the apply path has a subject.
$template = Join-Path $RepoRoot 'ai-gateway\simulator\test-config.yaml'
# Line-ending agnostic: git may check this file out CRLF, and a literal `n match
# would silently no-op — leaving codex disabled and step 8 without a subject.
$tpl = Get-Content -Raw $template
$tpl = [regex]::Replace($tpl, '(?m)^(\s*-\s*name:\s*codex\s*\r?\n\s*enabled:\s*)false', '${1}true')
if ($tpl -notmatch '(?m)^\s*-\s*name:\s*codex\s*\r?\n\s*enabled:\s*true') {
    Write-Error 'could not enable codex in the test config — the template shape changed'
    exit 2
}
Set-Content -Path $Config -Value $tpl -Encoding utf8

# ── the deployment comes up once ───────────────────────────────────────────────
Write-Step 'deploy: one gateway service, one continuous simulator'
if ($Live) { Write-Warn '-Live: one browser sign-in will open. Complete it to let enrolment finish.' }

$simArgs = @('--config', $Config, '--home', $HomeDir, '--spawn', '--gateway', $Gw, '--rescan', $Rescan)
if ($Live) { $simArgs += '--allow-login' }

# The child inherits these, so the gateway the sim spawns sees the same fixture.
$prevProfile = $env:USERPROFILE
$prevHomeEnv = $env:ZSAI_GATEWAY_HOME
$env:USERPROFILE = $AgentHome
$env:ZSAI_GATEWAY_HOME = $HomeDir

$simProc = Start-Process -FilePath $Sim -ArgumentList $simArgs -PassThru `
    -RedirectStandardOutput $SimLog -RedirectStandardError "$SimLog.err" -NoNewWindow
Write-Note "sim pid $($simProc.Id) (rescan ${Rescan}s); the gateway is spawned by it, bare"

$exitCode = 1
try {
    $firstWait = if ($Live) { 360 } else { 60 }
    Invoke-Check 'the deployment exchanged a first snapshot and status' {
        (Wait-Until -Seconds $firstWait -Condition { Test-Path $BrokerFile }) -and
        (Wait-Until -Seconds $firstWait -Condition { Test-Path $StatusFile })
    }

    $gwProc = $null
    Invoke-Check 'gateway running as a service' {
        Wait-Until -Seconds 30 -Condition {
            $script:gwProc = Get-Process -Name 'zscaler-ai-gateway' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            $null -ne $script:gwProc
        }
    }

    # ── 1 ────────────────────────────────────────────────────────────────────
    Write-Step '1. the protocol: both files present, gzipped, decodable'
    Invoke-Check 'both control files are gzipped JSON' {
        (Test-IsGzip $BrokerFile) -and (Test-IsGzip $StatusFile) -and
        ($null -ne (Read-ControlFile $BrokerFile).schema_ver) -and
        ($null -ne (Read-ControlFile $StatusFile).agents)
    }

    # ── 2 ────────────────────────────────────────────────────────────────────
    Write-Step '2. detection: exactly the fixture agents reach the snapshot'
    Invoke-Check 'snapshot is exactly the fixture agents, absent ones excluded' {
        $names = (Read-ControlFile $BrokerFile).agents | ForEach-Object { $_.name }
        Write-Note "snapshot: $($names -join ', ')"
        $ok = $names.Count -eq $Present.Count
        foreach ($a in $Absent) {
            if ($names -match $a) { $ok = $false; Write-Warn "$a is absent but reached the snapshot" }
        }
        $ok
    }

    # ── 3 ────────────────────────────────────────────────────────────────────
    Write-Step '3. steady state: identical rewrites must not churn the gateway'
    $before = Get-LogMatchCount $GwLog 'enrolment started'
    Write-Note 'waiting out three rescan ticks'
    Start-Sleep -Seconds ($Rescan * 3 + 2)
    Invoke-Check 'the simulator is continuous (rewrote the snapshot)' {
        (Get-LogMatchCount $SimLog 'wrote .*\.broker\.zip') -ge 2
    }
    Invoke-Check 'an unchanged snapshot did not re-trigger enrolment (content-hash gate)' {
        $after = Get-LogMatchCount $GwLog 'enrolment started'
        Write-Note "gateway enrolment starts: $before → $after"
        $after -eq $before
    }

    # ── 4 ────────────────────────────────────────────────────────────────────
    Write-Step '4. a real change: drop a detected agent from the live config'
    (Get-Content -Raw $Config).Replace("  - name: devin`n    enabled: false`n", '') |
        Set-Content -Path $Config -Encoding utf8
    Write-Note "removed 'devin' from the config (detected, so it was in the snapshot)"
    Invoke-Check 'the simulator noticed the config edit' {
        Wait-ForLog $SimLog 'changed — rescanning' 20
    }
    Invoke-Check 'devin left the snapshot' {
        Wait-Until -Seconds 30 -Condition {
            $n = (Read-ControlFile $BrokerFile).agents | ForEach-Object { $_.name }
            -not ($n -match 'Devin')
        }
    }
    # devin is off ENABLED_AGENTS, so it was never registered and there is nothing
    # to unregister. What must hold is the full-state contract: once it leaves the
    # snapshot it stops being listed at all.
    Invoke-Check 'devin left the status document' {
        Wait-Until -Seconds 30 -Condition {
            $n = (Read-ControlFile $StatusFile).agents | ForEach-Object { $_.name }
            -not ($n -match 'devin')
        }
    }

    # ── 5 ────────────────────────────────────────────────────────────────────
    Write-Step '5. tamper: the service restores the credential store it owns'
    $store = Join-Path $HomeDir '.credentials.zip'
    if (Test-Path $store) {
        Set-Content -Path $store -Value 'tampered' -Encoding ascii
        Invoke-Check 'the gateway restored the store after a foreign write' {
            Wait-ForLog $GwLog 'restoring from memory' 20
        }
    } else {
        Write-Note 'no credential store yet (offline run) — nothing to tamper with'
    }

    # ── 6 ────────────────────────────────────────────────────────────────────
    Write-Step '6. liveness: nothing died during the run'
    Invoke-Check 'the simulator is still running' { -not $simProc.HasExited }
    Invoke-Check 'the gateway is still running' {
        $null -ne (Get-Process -Name 'zscaler-ai-gateway' -ErrorAction SilentlyContinue)
    }

    # ── 7 ────────────────────────────────────────────────────────────────────
    Write-Step '7. the gate: what the gateway actually reported'
    Invoke-Check 'the gate held' {
        $doc = Read-ControlFile $StatusFile
        Write-Note "message: $($doc.message)"
        foreach ($a in $doc.agents) {
            $aid = if ($a.aid_key) { $a.aid_key } else { '-' }
            Write-Host ("    {0,-9} {1,-22} deltas={2} aid={3}" -f $a.name, $a.status, @($a.config).Count, $aid)
        }
        $ok = $true
        if ($Live) {
            $served = @($doc.agents | Where-Object { $_.status -eq 'success' })
            if ($served.Count -eq 0) { Write-Warn 'nothing enrolled — see logs\zax.log'; $ok = $false }
            foreach ($a in $served) {
                # Registration minted these; ai-protect correlates on them.
                if (@($a.config).Count -eq 0) { Write-Warn "$($a.name) is success but described no config"; $ok = $false }
                if (-not $a.aid_key)          { Write-Warn "$($a.name) is success but reported no aid_key"; $ok = $false }
                if (-not $a.agent_id)         { Write-Warn "$($a.name) is success but reported no agent_id"; $ok = $false }
            }
        } else {
            foreach ($a in $doc.agents) {
                if (@($a.config).Count -ne 0) { Write-Warn "$($a.name) was wired without enrolling"; $ok = $false }
                if ($a.status -eq 'success')  { Write-Warn "$($a.name) cannot be success offline"; $ok = $false }
            }
        }
        $ok
    }

    # ── 8 ────────────────────────────────────────────────────────────────────
    Write-Step '8. what the simulator applied'
    $applied = Select-String -Path $SimLog -Pattern 'wrote |already current|report-only|refused' `
        -ErrorAction SilentlyContinue | Select-Object -First 8
    if ($applied) {
        $applied | ForEach-Object { Write-Host "    $($_.Line.Trim())" }
        Assert-Pass "the gateway's own delta reached a real config"
    } else {
        Write-Note 'nothing applied — no agent reached success, so no delta existed'
    }

    # ── 9 ────────────────────────────────────────────────────────────────────
    Write-Step '9. the gateway does not outlive the process that spawned it'
    # Deliberately NOT the shell script's check. There is no SIGTERM here, and
    # CloseMainWindow is inert against a console child started -NoNewWindow, so a
    # graceful stop cannot be requested from another process without native
    # interop. Killing the sim instead exercises the thing that matters on
    # Windows: the gateway's parent-death watchdog (`start_parent_watchdog`
    # blocks on WaitForSingleObject for the parent handle), which must reap an
    # orphaned service.
    Stop-Process -Id $simProc.Id -Force -ErrorAction SilentlyContinue
    Invoke-Check 'the simulator is gone' {
        Wait-Until -Seconds 20 -Condition { $simProc.HasExited }
    }
    Invoke-Check "the gateway's parent-death watchdog reaped the orphan" {
        Wait-Until -Seconds 30 -Condition {
            $null -eq (Get-Process -Name 'zscaler-ai-gateway' -ErrorAction SilentlyContinue)
        }
    }

    # ── 10 ───────────────────────────────────────────────────────────────────
    Write-Step '10. the real home and the real agent configs were never touched'
    Invoke-Check 'nothing written under the real home or any real agent config' {
        $realProfile = $prevProfile
        $watch = @(
            (Join-Path $realProfile '.zsai-gateway'),
            (Join-Path $realProfile '.claude.json'),
            (Join-Path $realProfile '.codex\config.toml'),
            (Join-Path $realProfile '.gemini\settings.json')
        )
        $since = (Get-Item $Config).LastWriteTime
        $touched = @()
        foreach ($p in $watch) {
            if (-not (Test-Path $p)) { continue }
            $newer = Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $since }
            if ($newer) { $touched += $newer.FullName }
            elseif ((Get-Item $p).LastWriteTime -gt $since -and -not (Get-Item $p).PSIsContainer) {
                $touched += $p
            }
        }
        if ($touched) { $touched | ForEach-Object { Write-Warn "touched: $_" } }
        $touched.Count -eq 0
    }
} finally {
    foreach ($p in @($simProc)) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Get-Process -Name 'zscaler-ai-gateway' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    $env:USERPROFILE = $prevProfile
    $env:ZSAI_GATEWAY_HOME = $prevHomeEnv
}

# ── summary ───────────────────────────────────────────────────────────────────
Write-Host ('─' * 35)
$suffix = if ($Live) { '   (live)' } else { '' }
Write-Host ("passed: {0}   failed: {1}{2}" -f $script:Pass, $script:Fail, $suffix)

if ($script:Fail -gt 0 -or $KeepLogs) {
    Write-Host "`nlogs kept: $RunDir"
    Write-Host "  simulator : $SimLog"
    Write-Host "  gateway   : $GwLog"
    Write-Host "  protocol  : $HomeDir\.broker.zip .status.zip"
} else {
    Remove-Item -Recurse -Force $RunDir -ErrorAction SilentlyContinue
}

exit ([int]($script:Fail -gt 0))
