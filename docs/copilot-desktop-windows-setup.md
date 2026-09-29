# GitHub Copilot desktop app on Windows — install + real bearer token

Everything in `copilot-desktop-real-optimus-e2e.md` was run on macOS. This is
the piece that doc's "Still open" section flags as needed before the
disposable/research Windows VM run: how to get the app itself onto a Windows
box, and how to get a real Copilot bearer token there (the one
`listener::copilot_upstream_token` injects — see that module's doc comment in
`ai-protect/ai-gateway/listener/src/copilot_upstream_token.rs`). Not yet run on
Windows end-to-end; the install steps are the vendor's own documented path,
and the token steps are a direct translation of the bash script already
verified working on macOS (`get_copilot_token.sh`) — call out anywhere that
translation hasn't itself been exercised on Windows yet.

## 1. Install the GitHub Copilot desktop app on Windows

Official app, not the CLI or the VS Code extension — same one used on macOS
this session (`/Applications/GitHub Copilot.app`).

- **winget** (real, actively-published package —
  confirmed via [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs/pull/438313),
  version history tracks the same `1.1.x` line as the macOS build we tested
  against, e.g. `1.1.23`):
  ```powershell
  winget install --id GitHub.CopilotApp -e
  ```
- **Direct download**: [github.com/features/ai/github-app](https://github.com/features/ai/github-app)
  (landing page) or [github.com/github/app](https://github.com/github/app)
  (per-arch builds — Windows x64 and Windows ARM releases listed directly).

First launch (per GitHub's own
[quickstart](https://docs.github.com/en/copilot/get-started/quickstart-copilot-app)):
sign in to GitHub (device-code browser flow, same shape as § 2 below), then
either subscribe to a Copilot plan or configure a custom/BYOK provider —
that custom-provider row is exactly what `copilot_app_provision.rs` writes by
hand into the app's `data.db`; see `ai-protect/docs/copilot-app-provisioning.md`
for that side. Requires a GitHub account and Git installed; no admin rights
called out by the vendor docs beyond a normal per-user install.

## 2. Getting a real Copilot bearer token

This is the credential `listener::kinds::copilot_desktop` injects — the app's
own BYOK row carries none of its own, by construction. It's a hand-run,
non-renewing step (no refresh flow exists in this phase).

### The script (verified working, macOS)

`get_copilot_token.sh` — real GitHub OAuth **device flow** → exchanged for a
real Copilot bearer. It does **not** live on this branch; it's on the sibling
`main-08272026-vscode-copilot` branch at `ai-gateway/scripts/get_copilot_token.sh`.
To use it on the VM, either `git show main-08272026-vscode-copilot:ai-gateway/scripts/get_copilot_token.sh`
out to a file, or check out that branch/cherry-pick the file. It needs `curl`
and `jq`, so on Windows that means Git Bash or WSL — there's no native
Windows shell for it as written.

The three real calls it makes, in order (client id is VS Code Copilot's own
registered extension id):

```bash
# 1. Request a device code
curl -s -X POST https://github.com/login/device/code \
  -H "Accept: application/json" \
  -d "client_id=Iv1.b507a08c87ecfe98&scope=read:user"
# -> { device_code, user_code, verification_uri, interval }

# 2. Poll until the user approves user_code at verification_uri
curl -s -X POST https://github.com/login/oauth/access_token \
  -H "Accept: application/json" \
  -d "client_id=Iv1.b507a08c87ecfe98&device_code=<device_code>&grant_type=urn:ietf:params:oauth:grant-type:device_code"
# -> { access_token }   (poll every `interval` seconds until this appears)

# 3. Exchange the GitHub OAuth token for a Copilot bearer
curl -s https://api.github.com/copilot_internal/v2/token \
  -H "Authorization: token <access_token>" \
  -H "Editor-Version: vscode/1.90.0"
# -> { token, expires_at }   <- this "token" is the real Copilot bearer
```

### PowerShell translation (untested — same endpoints, not yet run on Windows)

Mechanical `Invoke-RestMethod` translation of the same three calls, for a VM
where Git Bash/WSL isn't set up. Verify it actually works there before relying
on it — it hasn't been run:

```powershell
$clientId = "Iv1.b507a08c87ecfe98"

$device = Invoke-RestMethod -Method Post -Uri "https://github.com/login/device/code" `
  -Headers @{ Accept = "application/json" } `
  -Body @{ client_id = $clientId; scope = "read:user" }

Write-Host "Open $($device.verification_uri) and enter code: $($device.user_code)"

do {
    Start-Sleep -Seconds $device.interval
    try {
        $poll = Invoke-RestMethod -Method Post -Uri "https://github.com/login/oauth/access_token" `
          -Headers @{ Accept = "application/json" } `
          -Body @{ client_id = $clientId; device_code = $device.device_code; grant_type = "urn:ietf:params:oauth:grant-type:device_code" }
    } catch { $poll = $null }
} until ($poll -and $poll.access_token)

$copilot = Invoke-RestMethod -Uri "https://api.github.com/copilot_internal/v2/token" `
  -Headers @{ Authorization = "token $($poll.access_token)"; "Editor-Version" = "vscode/1.90.0" }

$copilot.token   # the real Copilot bearer
```

### Where the listener actually reads it from

Write the raw bearer (no quotes, no trailing newline needed either way) to
`<gateway home>\copilot-upstream-token.txt`. On Windows that resolves (per
`ai-gateway/util/src/paths.rs`) to:

```
%USERPROFILE%\.zsai-gateway\copilot-upstream-token.txt
```

— unless the `ZSAI_GATEWAY_HOME` env var is set for that process, in which
case it's `<that path>\copilot-upstream-token.txt` instead. On macOS this was
`~/.zsai-gateway/copilot-upstream-token.txt`; same file, same rule, just
`%USERPROFILE%` in place of `$HOME`.

The listener re-reads this file at most once every 30s and fails open (passes
the client's original, empty `Authorization` through unchanged) if it's
missing, empty, or the token's embedded `exp=` has passed — so a stale token
doesn't hard-fail requests, it just goes back to looking like the pre-fix
behavior. If real requests start 401-ing again, refresh this file by hand.
