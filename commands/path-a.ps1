# Step 1 - Path A: direct run, no daemon. Run in umesh's own (non-elevated) session.

# Clear any leftover processes holding the old exes.
Get-Process ai-broker-mon,zscaler-ai-protect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Get-Process ai-broker-mon,zscaler-ai-protect -ErrorAction SilentlyContinue   # must be empty before continuing

Copy-Item "\\tsclient\Z\target\release\ai-broker-mon.exe" "C:\Users\umesh\work\ai-broker-mon.exe" -Force
Copy-Item "\\tsclient\Z\target\release\zscaler-ai-protect.exe" "C:\Users\umesh\work\zscaler-ai-protect.exe" -Force

# sdk_config::init() needs the REAL bundled base config (init.yaml + auth.yaml +
# the dev CA cert) -- its only portable fallback (since the compiled-in
# CARGO_MANIFEST_DIR path is this laptop's, not the VM's) is `./config/`
# relative to the process's CWD at launch. Put it next to the small cloud:dev
# override file that already lives in ~/.ai-broker (that one's read separately,
# straight from flat CWD, by resolve_init_yaml) -- so CWD = ~/.ai-broker covers
# both at once.
New-Item -ItemType Directory -Path "C:\Users\umesh\.ai-broker\config" -Force | Out-Null
Copy-Item "\\tsclient\Z\ai-gateway\config\*" "C:\Users\umesh\.ai-broker\config\" -Force

Set-Location "C:\Users\umesh\.ai-broker"
$env:ZAX_AGENT_ID = "codex"
& "C:\Users\umesh\work\ai-broker-mon.exe" --llm-proxy --upstream https://api.openai.com
# Leave this running in this window (blocks, tailing its own log).
# Complete the OIDC browser login when it opens.
