# Decrypting the GitHub Copilot app's own traffic with mitmproxy

Passive `tcpdump` can confirm *which host* the app talks to (source/dest IP,
port, timing) but not the request/response body — that's TLS-encrypted.
Seeing the actual JSON needs a real MITM: a local proxy that terminates TLS
itself, re-encrypts to the real upstream, and is trusted by the OS as a CA.

⚠️ This is a genuine, if temporary, security-trust change (installing a new
trusted root CA + routing all system traffic through a local proxy) — do this
deliberately, on a machine you control, and revert it when done (see
"Cleanup" below). It also decrypts *everything* on the box while active, not
just the one app — expect to see other apps' traffic (browser, other GitHub
API calls, telemetry) in the capture too, including real session cookies and
tokens. Handle the capture file like the credential material it contains.

## Setup

1. **Install mitmproxy into a throwaway venv** (`pip install mitmproxy`
   system-wide is blocked by Homebrew's Python on macOS; a venv sidesteps
   that cleanly and is trivial to delete afterward):
   ```bash
   python3 -m venv /path/to/scratch/mitmproxy-venv
   /path/to/scratch/mitmproxy-venv/bin/pip install mitmproxy
   ```
2. **Write a small addon script** to log just the relevant request/response
   bodies to a plain file (mitmproxy's own TUI works too, but a flat log is
   easier to `grep`/`tail` from another tool). See
   `ai-gateway/scratchpad/copilot-mitm-body-logger.py` in this repo for the
   one used here — filters to hosts containing `"github"`, writes method,
   URL, headers, and body for both request and response.
3. **Start it** (headless — `mitmdump`, not the interactive `mitmproxy` TUI):
   ```bash
   mitmproxy-venv/bin/mitmdump -p 8888 -s copilot-mitm-body-logger.py
   ```
   First run generates a CA at `~/.mitmproxy/mitmproxy-ca-cert.{pem,cer,p12}`.
4. **Trust the CA** (manual, in Keychain Access — this is the actual
   security-trust step, not something to script): open
   `~/.mitmproxy/mitmproxy-ca-cert.cer`, it lands in the login keychain; find
   it in Keychain Access, double-click it, expand **Trust**, set "When using
   this certificate" to **Always Trust** (prompts for your password).
5. **Point the system proxy at it** (manual, System Settings → Wi-Fi (or
   active network) → Details → Proxies): enable both **Web Proxy (HTTP)**
   and **Secure Web Proxy (HTTPS)**, server `127.0.0.1`, port `8888`. GUI
   apps launched via Launch Services don't inherit shell env vars
   (`HTTP_PROXY` set in a terminal has no effect on them), so the system-wide
   setting is what's actually needed to route a native app's traffic.
6. **Quit and relaunch the target app** so it opens fresh connections through
   the new proxy, then drive it normally. Read the log file mitmdump's addon
   wrote to.

## What this found (2026-09-28, live account)

Decrypting the GitHub Copilot desktop app's own first-party ("Auto" model)
traffic showed:

- `GET https://api.github.com/copilot_internal/user` returns, among other
  things, `"endpoints":{"api":"https://api.individual.githubcopilot.com",
  ...}` — a **per-plan-tier** API host, not the generic `api.githubcopilot.com`
  every manual test up to this point had hardcoded. (Tested directly: both
  hosts gave identical results for this account, so the tier-specific host
  turned out not to be the explanation for the errors below — but it's a
  real, previously-unconfirmed fact about how the app resolves its own
  upstream, worth keeping.)
- The same response's `quota_snapshots.premium_interactions` was
  `{"remaining": 0, "entitlement": 0, ...}`, with `"access_type_sku":
  "free_limited_copilot"` and `"copilot_plan": "individual"`. This is the
  real, definitive explanation for every `model_not_supported` error hit
  while testing the custom BYOK provider against every GPT-5.x/Claude/
  Gemini/Kimi/o-series model name: **this specific account's plan has zero
  premium-model quota**, full stop — not an endpoint issue, not a header
  issue, not anything in this project's own pipeline. The `gpt-4o` family
  (the one tier this plan does get, billed under the plain `completions`
  quota) works, but doesn't support `reasoning_effort` at the API level —
  a real GitHub-side constraint, confirmed via direct `curl` with the exact
  same error the app itself surfaced.

## Cleanup (after use)

Stop the proxy process, then reverse both manual steps — leaving either in
place routes/decrypts all future traffic on the box, silently:

1. **System Settings → Wi-Fi → Details → Proxies**: disable Web Proxy (HTTP)
   and Secure Web Proxy (HTTPS) again.
2. **Keychain Access**: find the `mitmproxy` certificate (search "mitmproxy"),
   delete it — or at minimum set its trust back to the system default
   instead of "Always Trust".
3. Delete the venv and the CA files (`~/.mitmproxy/`) — regenerating a fresh
   CA next time is expected and fine; there's no reason to keep an old one
   trusted or untrusted.
4. Securely remove any capture log — it contains real session cookies and
   bearer tokens for whatever else was on the box while the proxy was active.
