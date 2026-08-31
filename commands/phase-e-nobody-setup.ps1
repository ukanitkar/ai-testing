# Phase E, PART 1 (v2) -- run BEFORE logging off.
#
# The first attempt at this test raced the daemon's own heartbeat: the mock
# was bumped to a new version immediately, and the daemon's ~60s heartbeat
# cadence picked it up before there was time to read instructions and log
# off. reconcile() found the broker still alive and correctly did nothing --
# so the fallback path was never actually exercised, and it looked like
# "NOT FOUND" for reasons that had nothing to do with the product.
#
# Fix: the mock now has a BUILT-IN delay (see dev_device_plane.py's
# DELAYED_CONFIG_VERSION / DELAYED_CONFIG_VERSION_AFTER_SECONDS), so the
# version switch happens on the mock's own clock, with NO further command
# needed after this script exits. 150 seconds is a generous, race-free
# window to read this output and log off -- there is no way for the switch
# to land before that, no matter how long reading/typing takes.
#
# What SHOULD happen once the delayed version lands with nobody on the
# console (confirmed by reading ai_broker_launch.rs before testing anything):
#   1. reconcile(true) reaps the broker (session torn down by the logoff, so
#      has_exited() should read true) -> guard = None
#   2. spawn_broker() -> spawn_broker_as_console_user() finds no active
#      session -> returns Ok(None)
#   3. logs exactly:
#        [ai-broker] no interactive session; starting ai-broker-mon as the
#        daemon (SYSTEM) -- user OIDC/config unavailable until a user logs in
#        and reconcile re-runs
#   4. falls back to a plain daemon-context spawn (SYSTEM/session 0); its
#      broker_home() also has no console user to resolve, so it falls
#      through to discovery::user_home() -- %USERPROFILE% with no
#      SUDO_USER-style override on Windows -- landing on systemprofile. This
#      is the EXPECTED degraded mode here (the warning says so explicitly),
#      not the systemprofile bug fixed on day 1.
#   5. that broker attempts interactive OIDC with no desktop to open a
#      browser on; oidc.rs has a bounded deadline, after which it errors out
#      and the process exits.

Write-Host "=== current state ===" -ForegroundColor Cyan
Get-Process ai-broker-mon -ErrorAction SilentlyContinue | Select-Object Id, SI | Format-Table -AutoSize
Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue | Select-Object OwningProcess

$daemon = "C:\ProgramData\ZscalerAIProtect\daemon.log"
$heldVersion = 0
$lastFetch = Select-String -Path $daemon -Pattern "config_version (\d+) differs from held" -ErrorAction SilentlyContinue |
             Select-Object -Last 1
if ($lastFetch -and ($lastFetch.Line -match "config_version (\d+) differs from held")) {
    $heldVersion = [int]$Matches[1]
}
$delayedVersion = $heldVersion + 1
Write-Host "  daemon currently holds config_version: $heldVersion"
Write-Host "  will delay-switch to: $delayedVersion"

$local = "C:\Users\umesh\work\dev_device_plane.py"
Copy-Item "\\tsclient\Z\ai-gateway\scripts\dev_device_plane.py" $local -Force

Write-Host ""
Write-Host "=== starting the mock: unchanged version now, switches itself after 150s ===" -ForegroundColor Cyan
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$env:CONFIG_VERSION                          = "$heldVersion"
$env:DELAYED_CONFIG_VERSION                  = "$delayedVersion"
$env:DELAYED_CONFIG_VERSION_AFTER_SECONDS    = "150"
$env:AI_BROKER_ENABLED                       = "1"
$env:HEARTBEAT_INTERVAL_SECONDS              = "60"
Start-Process -FilePath "C:\Program Files\Python312\python.exe" `
    -ArgumentList "-u", $local, "--port", "8080" `
    -RedirectStandardOutput "C:\ai-broker-test\device-plane.out" `
    -RedirectStandardError  "C:\ai-broker-test\device-plane.err" `
    -WindowStyle Hidden
Start-Sleep -Seconds 3
$cfg = curl.exe -s http://127.0.0.1:8080/endpoint/v1/config
Write-Host "  /config serves right now (must be UNCHANGED): $cfg"
if ($cfg -notmatch "`"version`":\s*$heldVersion") {
    Write-Host "  UNEXPECTED -- version changed immediately, aborting" -ForegroundColor Red
    exit 1
}
Write-Host "  confirmed: version will NOT change for 150s from now" -ForegroundColor Green

Write-Host ""
Write-Host "=== ARMED (race-free this time). Log off any time in the next ~2 minutes ===" -ForegroundColor Yellow
Write-Host "  A genuine sign-out, not a disconnect -- is_user_session_state() treats" -ForegroundColor Yellow
Write-Host "  WTSDisconnected as a live user, so closing the RDP window is NOT enough:" -ForegroundColor Yellow
Write-Host ""
Write-Host "    shutdown /l" -ForegroundColor Cyan
Write-Host ""
Write-Host "  (shutdown /l logs off only -- the VM keeps running)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Wait ~5-6 minutes total before reconnecting: 150s until the version" -ForegroundColor Yellow
Write-Host "switches + up to 60s for the next heartbeat + time for the fallback" -ForegroundColor Yellow
Write-Host "broker's OIDC attempt to time out. Then reconnect and run:" -ForegroundColor Yellow
Write-Host '  powershell -ExecutionPolicy Bypass -File "\\tsclient\Z\commands\phase-e-nobody-check.ps1"' -ForegroundColor Cyan
