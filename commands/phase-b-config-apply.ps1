# Phase B, item 2 -- config-delta apply, live on Windows.
# Run in the REGULAR umesh window.
#
# WHAT CHANGED FROM THE OLD TEST: the single-writer staged-ZIP apply
# (config-staging/*.zip, manifest.json, Compress-Archive) is retired entirely
# -- there is no ZIP, no manifest, no config-staging/ directory anymore. The
# broker now reports a `ConfigDelta{file, setting}` inside status.json (one
# per agent, in `agents[].config[]`); ai-protect's status_file_watcher merges
# it into the real file via apply_config_delta -- generically for TOML or
# JSON targets, preserving every path the delta doesn't mention. This is
# STILL the one code path that exercises the Windows ownership reassignment
# (SetSecurityInfo) inside write_atomic_under that unit tests can only SKIP
# without SeRestorePrivilege -- only WHAT feeds it changed, not that fact.
#
# CAUTION: the allowlist (is_allowed_agent_config) permits exactly ONE
# target, .codex/config.toml -- the same one codex's real registration
# already writes a delta for. This script backs it up and restores it.
#
# Two parts:
#   1. POSITIVE, fully live, no staging needed at all: codex is accepted by
#      default, so the already-running broker (from Step 2) is ALREADY
#      producing a real ConfigDelta for it on every tick. This just observes
#      that side effect landed correctly -- content, and ownership.
#   2. NEGATIVE, needs a hand-crafted status.json: no real adapter code path
#      ever emits a delta naming something outside the allowlist, so the
#      only way to exercise the allowlist's DEFENSE is to feed the daemon a
#      malicious one directly. Since status.json is a single full-snapshot
#      file the live broker rewrites every 3s, briefly stopping just the
#      ai-broker-mon PROCESS (not the service -- restarting the service
#      needs elevation this script deliberately doesn't have; killing a
#      same-user process doesn't, per phase-d-recover.ps1's own finding)
#      avoids racing that overwrite. Bringing the broker back afterward reuses
#      that same script's technique: bump CONFIG_VERSION on the mock device
#      plane so ai-protect's reconcile() respawns it on the next heartbeat --
#      restarting the broker is NOT on any timer, so this is the only
#      unelevated way to ask for it back.

$codex      = "C:\Users\umesh\.codex\config.toml"
$work       = "C:\ai-broker-test\cfgapply"
$testDir    = "C:\ai-broker-test"
$statusFile = "C:\Users\umesh\.ai-broker\status.json"
$marker     = "ZS_CFG_APPLY_TEST_$(Get-Random)"

New-Item -ItemType Directory -Path $work -Force | Out-Null

# daemon.log lives under C:\ProgramData\ZscalerAIProtect, which is
# SYSTEM/Administrators-only (windows_security::allow_system_admins_traverse_only)
# -- this REGULAR umesh window can't read it directly, so route through the
# elevated helper's "read-daemon-log" action instead. Standalone copy of
# run-e2e-suite.ps1's Read-DaemonLog: this script runs as its own process
# (`& $script`), not dot-sourced, so it has no access to that scope.
function Read-DaemonLog {
    param([string]$Pattern = "", [int]$Tail = 0, [int]$TimeoutSeconds = 20)
    $id       = [guid]::NewGuid().ToString()
    $reqFile  = "$testDir\elevated-request.json"
    $respFile = "$testDir\elevated-response-$id.json"
    @{ id = $id; action = "read-daemon-log"; pattern = $Pattern; tail = $Tail } |
        ConvertTo-Json | Set-Content -Path $reqFile -Encoding ascii
    $elapsed = 0
    while (-not (Test-Path $respFile) -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
    }
    if (-not (Test-Path $respFile)) {
        Write-Host "  [read-daemon-log] TIMEOUT -- is run-e2e-suite-elevated-helper.ps1 running?" -ForegroundColor Red
        return @()
    }
    $resp = Get-Content $respFile -Raw | ConvertFrom-Json
    Remove-Item $respFile -Force -ErrorAction SilentlyContinue
    if (-not $resp.ok) {
        Write-Host "  [read-daemon-log] $($resp.note)" -ForegroundColor Yellow
        return @()
    }
    return @($resp.lines)
}

# ---- 1. Back up the real Codex config -------------------------------------
$backup = "$work\config.toml.backup"
if (Test-Path $codex) {
    Copy-Item $codex $backup -Force
    Write-Host "backed up existing .codex\config.toml ($((Get-Item $codex).Length) bytes)" -ForegroundColor Green
} else {
    Write-Host "no existing .codex\config.toml to back up" -ForegroundColor Yellow
    Remove-Item $backup -ErrorAction SilentlyContinue
}

# ---- 2. POSITIVE: the live delta for codex, already happening -------------
Write-Host ""
Write-Host "=== POSITIVE: observe the already-live ConfigDelta apply for codex ===" -ForegroundColor Cyan
Write-Host "  (codex is accepted by default -- Step 2's already-running broker keeps" -ForegroundColor DarkCyan
Write-Host "   producing this delta every tick; nothing to stage here)" -ForegroundColor DarkCyan

$appliedBefore = (Read-DaemonLog -Pattern "applied config delta .*for agent 'codex'").Count
# Nudge a fresh delta into being visible on this run: touching codex's config
# so this run's own apply is unambiguous rather than relying on one from
# minutes ago still being the most recent daemon.log line.
if (Test-Path $codex) { (Get-Item $codex).LastWriteTime = Get-Date }

$seen = $false
for ($i = 1; $i -le 7; $i++) {
    Start-Sleep -Seconds 3
    $now = (Read-DaemonLog -Pattern "applied config delta .*for agent 'codex'").Count
    if ($now -gt $appliedBefore -or (Test-Path $codex)) { $seen = $true }
    Write-Host ("  +{0,2}s  applied-count={1} (was {2})" -f ($i*3), $now, $appliedBefore)
}

$positivePass = $false
if (Test-Path $codex) {
    $body = Get-Content $codex -Raw
    $hasZax = $body -match "mcp_servers\.zax"
    Write-Host ("  .codex\config.toml has [mcp_servers.zax]: {0}" -f $hasZax) -ForegroundColor $(if ($hasZax) { "Green" } else { "Red" })
    $acl = Get-Acl $codex
    $ownerOk = ($acl.Owner -ieq "EC2AMAZ-VRAE5E8\umesh")
    Write-Host "  owner: $($acl.Owner)  <-- the SetSecurityInfo reassignment" -ForegroundColor $(if ($ownerOk) { "Green" } else { "Red" })
    $positivePass = $hasZax -and $ownerOk
} else {
    Write-Host "  FAIL: .codex\config.toml does not exist -- the delta never landed" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== daemon log: the apply line itself ===" -ForegroundColor Cyan
Read-DaemonLog -Pattern "applied config delta .*for agent 'codex'" -Tail 40 | Select-Object -Last 3

# ---- 3. NEGATIVE: non-allowlisted target must be refused -------------------
Write-Host ""
Write-Host "=== NEGATIVE: target .ssh/authorized_keys (must be REFUSED) ===" -ForegroundColor Cyan
$evil = "C:\Users\umesh\.ssh\authorized_keys"
$evilExisted = Test-Path $evil

Write-Host "  briefly stopping ai-broker-mon (NOT the daemon) so this hand-crafted" -ForegroundColor DarkCyan
Write-Host "  status.json survives long enough for the daemon to poll it..." -ForegroundColor DarkCyan
Get-Process ai-broker-mon -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

$failBefore = (Read-DaemonLog -Pattern "config delta .*failed").Count

$malicious = @{
    ready               = $true
    proxy_base_url      = $null
    message             = "test-injected"
    credential_requested = $false
    agents = @(@{
        agent  = "codex"
        status = "success"
        config = @(@{ file = ".ssh/authorized_keys"; setting = @{ dummy = "ssh-rsa AAAA_SHOULD_NEVER_BE_WRITTEN" } })
        message = "test-injected malicious delta"
    })
} | ConvertTo-Json -Depth 6
Set-Content -Path $statusFile -Value $malicious -Encoding ascii
Write-Host "  wrote a status.json naming .ssh/authorized_keys; waiting for the daemon's poll..."

$rejected = $false
for ($i = 1; $i -le 5; $i++) {
    Start-Sleep -Seconds 3
    $now = (Read-DaemonLog -Pattern "config delta .*failed").Count
    if ($now -gt $failBefore) { $rejected = $true; break }
}

if ($rejected) {
    Write-Host "  PASS: daemon logged a failed apply (allowlist rejected it)" -ForegroundColor Green
    Read-DaemonLog -Pattern "config delta .*failed" -Tail 20 | Select-Object -Last 2
} else {
    Write-Host "  UNEXPECTED: no 'config delta ... failed' line appeared" -ForegroundColor Red
}
$evilCreated = $false
if (Test-Path $evil) {
    if ($evilExisted) { Write-Host "  (( .ssh\authorized_keys already existed before this test -- not a new write, ignore )) " -ForegroundColor Yellow }
    else { Write-Host "  SERIOUS: $evil was CREATED -- the allowlist did not defend" -ForegroundColor Red; $evilCreated = $true }
} else {
    Write-Host "  confirmed: $evil was NOT created" -ForegroundColor Green
}

# ---- 4. Restore ------------------------------------------------------------
Write-Host ""
Write-Host "=== restoring ===" -ForegroundColor Cyan
if (Test-Path $backup) {
    Copy-Item $backup $codex -Force
    Write-Host "  .codex\config.toml restored from backup" -ForegroundColor Green
} else {
    Remove-Item $codex -ErrorAction SilentlyContinue
    Write-Host "  removed the test-written config (there was no original)" -ForegroundColor Green
}
Write-Host "  broker respawn is NOT on any timer (reconcile() only fires from a NEW" -ForegroundColor DarkCyan
Write-Host "  settings frame) -- bumping CONFIG_VERSION on the mock device plane to ask" -ForegroundColor DarkCyan
Write-Host "  for one, same technique phase-d-recover.ps1 uses..." -ForegroundColor DarkCyan
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$env:CONFIG_VERSION = [string](Get-Random -Maximum 100000)  # just needs to differ from whatever was last served
$env:AI_BROKER_ENABLED = "1"; $env:HEARTBEAT_INTERVAL_SECONDS = "60"
Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
    -ArgumentList "-u", "C:\Users\umesh\work\dev_device_plane.py", "--port", "8080" `
    -RedirectStandardOutput "C:\ai-broker-test\device-plane.out" -RedirectStandardError "C:\ai-broker-test\device-plane.err" `
    -WindowStyle Hidden

$respawned = $false
for ($i = 1; $i -le 14; $i++) {
    Start-Sleep -Seconds 5
    if (Get-Process ai-broker-mon -ErrorAction SilentlyContinue) { $respawned = $true; break }
    Write-Host ("  +{0,3}s  still waiting for respawn" -f ($i * 5))
}
if ($respawned) {
    Write-Host "  broker respawned -- it will overwrite status.json (and re-wire codex) on its own next tick" -ForegroundColor Green
} else {
    Write-Host "  FAIL: broker did not respawn within 70s -- later steps that need a live broker will likely fail" -ForegroundColor Red
}

if (-not ($positivePass -and $rejected -and (-not $evilCreated) -and $respawned)) { exit 1 }
exit 0
