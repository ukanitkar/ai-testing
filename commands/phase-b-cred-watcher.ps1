# Phase B, item 1 -- credential refresh, live on Windows.
# Run in the REGULAR umesh window (it only reads daemon.log + the broker's
# own sidecar file; no elevation needed).
#
# WHAT CHANGED FROM THE OLD TEST: there is no more `credential-request` flag
# file, and no more PushCredential/CredentialApplied control message. The
# broker recomputes `status.json.credential_requested` fresh on every tick --
# a pure function of the cached user-JWT sidecar's expiry vs now
# (CredentialManager::credential_requested, `REFRESH_BUFFER_SECONDS` = 300) --
# and ai-protect's status_file_watcher edge-triggers a refetch + broker.json
# rewrite the moment that field flips false -> true. There is nothing left to
# "touch"; instead this test AGES the cached credential directly and watches
# both sides react to the resulting flip.
#
# Expect the pushed credential itself to still land empty afterward:
# zax_user_credential::fetch is still a daemon-side stub. What's being proven
# is that the EDGE-TRIGGER fires and a broker.json rewrite actually happens,
# not that a real credential lands.

$sidecar   = "C:\Users\umesh\.ai-broker\.credentials.json"
$brokerLog = "C:\Users\umesh\.ai-broker\logs\zax.log"
$testDir   = "C:\ai-broker-test"

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

# ---- 1. Is the status.json watcher even running, and on which path? ------
Write-Host "=== daemon: status.json watcher startup line ===" -ForegroundColor Cyan
$startup = Read-DaemonLog -Pattern "status.json watcher now polling" | Select-Object -Last 1
if ($startup) {
    Write-Host "  $($startup.Trim())"
} else {
    Write-Host "  not found -- the watcher never started (is the broker running?)" -ForegroundColor Red
    exit 1
}

# ---- 2. Baseline, then age the cached credential --------------------------
Write-Host ""
Write-Host "=== forcing credential_requested: false -> true ===" -ForegroundColor Cyan
if (-not (Test-Path $sidecar)) {
    Write-Host "  FAIL: no sidecar at $sidecar yet -- let the broker complete one real OIDC round first" -ForegroundColor Red
    exit 1
}
$original = Get-Content $sidecar -Raw
Write-Host "  backed up the current sidecar in memory before aging it"

$beforeReq = (Read-DaemonLog -Pattern "requests a fresh credential").Count

# Age it: set zax_expires_at to right now. credential_requested is
# `exp - REFRESH_BUFFER_SECONDS(300) <= now`, so any exp <= now+300 already
# counts -- "now" makes the intent unambiguous without needing negative math.
$doc = $original | ConvertFrom-Json
$nowEpoch = [int][double]::Parse((Get-Date -UFormat %s))
$doc.zax_expires_at = $nowEpoch
$doc | ConvertTo-Json | Set-Content -Path $sidecar -Encoding ascii
Write-Host "  rewrote zax_expires_at = $nowEpoch (i.e. 'expires right now')" -ForegroundColor Green

# ---- 3. Wait for both sides' 3s polls to catch up -------------------------
# Two independent 3s ticks are in the path here: the broker's own
# AgentManager::apply recomputing status.json, then ai-protect's own
# status_file_watcher noticing status.json changed -- so allow a bit more
# slack than the old single-watcher test did.
Write-Host ""
Write-Host "=== waiting for both sides' pollers (allowing 30s) ===" -ForegroundColor Cyan
$fired = $false
for ($i = 1; $i -le 10; $i++) {
    Start-Sleep -Seconds 3
    $now = (Read-DaemonLog -Pattern "requests a fresh credential").Count
    Write-Host ("  +{0,2}s  observed-count={1} (was {2})" -f ($i*3), $now, $beforeReq)
    if ($now -gt $beforeReq) { $fired = $true; break }
}

# ---- 4. Verdict -------------------------------------------------------------
Write-Host ""
if ($fired) {
    Write-Host "VERDICT: PASS -- ai-protect noticed the flip and rewrote broker.json" -ForegroundColor Green
} else {
    Write-Host "VERDICT: FAIL -- no 'requests a fresh credential' line appeared within 30s" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== daemon side ===" -ForegroundColor Cyan
Read-DaemonLog -Pattern "status.json .. ready|requests a fresh credential|wrote " -Tail 30 |
    Select-Object -Last 6

Write-Host ""
Write-Host "=== broker side (should show credential_requested going true, then the fresh push arriving) ===" -ForegroundColor Cyan
Get-Content $brokerLog -Tail 30 -ErrorAction SilentlyContinue |
    Select-String "credential changed in broker.json|broker.json carries a user credential" | Select-Object -Last 5

# ---- 5. Restore the real sidecar so later steps get a fresh, valid credential
Write-Host ""
Write-Host "=== restoring the original sidecar ===" -ForegroundColor Cyan
Set-Content -Path $sidecar -Value $original -Encoding ascii
Write-Host "  restored" -ForegroundColor Green

if (-not $fired) { exit 1 }
exit 0
