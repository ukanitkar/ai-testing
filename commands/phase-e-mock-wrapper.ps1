# Wrapper the scheduled task actually runs (as SYSTEM). Kept as its own file
# rather than inline in the /tr string, since schtasks' quoting for a nested
# powershell -Command gets unreliable fast; a file sidesteps that entirely.
#
# Env vars are baked in as literals by the setup script that writes this file
# (a scheduled task does not inherit the creating session's env), rather than
# passed at invocation.

New-Item -ItemType Directory -Path "C:\ai-broker-test" -Force | Out-Null

$env:CONFIG_VERSION                       = "__BASE_VERSION__"
$env:DELAYED_CONFIG_VERSION               = "__DELAYED_VERSION__"
$env:DELAYED_CONFIG_VERSION_AFTER_SECONDS = "__DELAY_SECONDS__"
$env:AI_BROKER_ENABLED                    = "1"
$env:HEARTBEAT_INTERVAL_SECONDS           = "60"

& "C:\Program Files\Python312\python.exe" "C:\Users\umesh\work\dev_device_plane.py" --port 8080 `
    *> "C:\ai-broker-test\device-plane-scheduled.log"
