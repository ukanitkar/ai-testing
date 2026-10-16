# Agent TLS posture and CA-trust matrix — SKELETON, mostly unmeasured

Per-agent record of what each brokered agent actually does on the wire, and
whose trust store it validates against. Created 2026-10-15 because the question
"do all popular agents speak TLS 1.2, 1.3, or 1.3 with ECH?" had **no answer
anywhere in either repo** — the only TLS-version material is the generic
mechanism section in `ai-protect`'s `docs/network-egress-sni.md`, with nothing
per agent.

This matters for two live decisions:

- **The connect-redirect design** (`vscode-copilot-network-egress-redirect-design.md`)
  assumes the gateway can read the destination hostname off the ClientHello
  SNI. That is an assumption about *every* agent, currently verified for none.
- **`TlsPolicy::min_version`** in `ai-gateway/listener/src/tls.rs` can be set to
  TLS 1.3-only. With no matrix, nobody can predict which agent that breaks.

## How to use this file

**The `CA trust (confirmed)` column may only be filled from a measurement, and
the `Evidence` column must name it** — a capture file, a log line, a test run,
a source file read with a line number. "Probably, because it's Node" belongs in
`CA trust (guess)`, never in confirmed.

This split is deliberate. `vscode_copilot.rs` shipped `enabled: true` on an
assumption nobody had tested, and the account-gate investigation
(`vscode-copilot-enterprise-gate-account-test.md`) is what it cost to find out.
An unverified matrix that *looks* authoritative is worse than no matrix.

Legend: **✅ measured** · **❓ unknown** · **⬜ not applicable**. Leave cells
`❓` rather than guessing in a confirmed column.

## Matrix

Agents in adapter-registry order (`ai-gateway/agent-manager/src/agents/mod.rs`).
★ = in `ENABLED_AGENTS` today, so these are the rows that matter first.

| Agent (adapter id) | ★ | HTTP stack / runtime | TLS ver. offered | SNI present | ECH attempted | CA trust (confirmed) | CA trust (guess) | Evidence |
|---|---|---|---|---|---|---|---|---|
| `claude` | ★ | Node CLI | ❓ | ❓ | ❓ | ❓ | `NODE_EXTRA_CA_CERTS` — adapter declares `NODE_CA_ENV`, and the brokered base-URL leg works in production, so this is close to confirmed but has never been isolated as a TLS-trust test | adapter: `agents/claude.rs` |
| `codex` | ★ | Node CLI (`@openai/codex`) | ❓ | ❓ | ❓ | ❓ | Node default store; adapter declares **no** `NODE_CA_ENV`, so untested | `agents/codex.rs` |
| `gemini` | ★ | Node CLI | ❓ | ❓ | ❓ | ❓ | `NODE_EXTRA_CA_CERTS` — adapter declares `NODE_CA_ENV` | `agents/gemini.rs` |
| `cursor` | | Electron app | ❓ | ❓ | ❓ | ❓ | Adapter declares `NODE_CA_ENV`, but Electron's `net` path uses the **system** store — the declared channel may be the wrong one, same shape as the `vscode-copilot` finding below | `agents/cursor.rs` |
| `copilot` (CLI) | ★ | Node + a **native Rust** HTTP transport | ❓ | ❓ | ❓ | ❓ (mixed) | Split stack: `NODE_EXTRA_CA_CERTS` for the Node side; the bundle states it "does not affect the OTLP exporter, which uses a native (Rust) HTTP transport" — so at least one path ignores it | read from `@github/copilot-*/app.js`, 2026-10-13 |
| `copilot-desktop` | ★ | Electron shell + native **Rust** backend | ❓ | ❓ | ❓ | ❓ | Backend reads `HTTPS_PROXY`/`HTTP_PROXY` **env vars only** — confirmed by contrast (a system-wide GUI proxy caught the Electron-layer calls but never the backend's `/models`; a process-scoped env var did). That is a *proxy* finding, not a CA-trust one | `copilot-desktop-netransparentproxyprovider-design.md` |
| `devin` | ★ | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | |
| `vscode-copilot` | ★ | **Electron `net`** (default) + `@github/copilot` agent-host child | ❓ | ❓ | ❓ | ❓ | **System/login keychain**, not `NODE_EXTRA_CA_CERTS`: the extension defaults to `advanced.debug.useElectronFetcher = true` and loads trust via `@vscode/proxy-agent`'s `loadSystemCertificates` (gated by `http.systemCertificatesNode`). Strongly evidenced by source read, but the **MITM itself was never tested** — only that `http.proxy` routes the traffic | extension bundle read + live proxy test, 2026-10-13/15 (`vscode-copilot-enterprise-gate-account-test.md` §5) |
| `grok` | | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | |
| `windsurf` | | Electron app | ❓ | ❓ | ❓ | ❓ | Adapter declares `NODE_CA_ENV`; same Electron caveat as `cursor` | `agents/windsurf.rs` |
| `antigravity` | | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | |
| `kiro` | | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | |
| `amazonq` | | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | |
| `continue` | | VS Code extension | ❓ | ❓ | ❓ | ❓ | Noted elsewhere as "proxy-aware"; store unknown | `vscode-copilot-chat-extension.html` §8 |
| `zed` | | Rust app | ❓ | ❓ | ❓ | ❓ | Likely `rustls` + webpki or system roots — a Rust app typically ignores `NODE_EXTRA_CA_CERTS` entirely | |
| `opencode` | | ❓ | ❓ | ❓ | ❓ | ❓ | ❓ | |
| `vscode` | | (MCP surface only, dormant) | ⬜ | ⬜ | ⬜ | ⬜ | No LLM leg — `LlmRouting::None` | `agents/vscode.rs` |
| `aider` | | Python CLI | ❓ | ❓ | ❓ | ❓ | Python/`requests` → `certifi` bundle, which ignores both the system store and `NODE_EXTRA_CA_CERTS`; usually needs `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE` | |
| `amp` | | ❓ (detection only) | ❓ | ❓ | ❓ | ❓ | ❓ | |
| `openclaw` | | ❓ (detection only) | ❓ | ❓ | ❓ | ❓ | Adapter declares `NODE_CA_ENV` | `agents/openclaw.rs` |

## How to measure each column

Per agent, on a box where it is installed and signed in. Do the ★ rows first.

1. **TLS version / SNI / ECH** — point the agent at a logging proxy or capture
   the handshake (`mitmproxy` in ignore-hosts mode logs `CONNECT` without
   terminating; Wireshark/`tshark` on the ClientHello gives the full picture).
   Record from the **ClientHello**: `supported_versions`, whether
   `server_name` is present, whether `encrypted_client_hello` is present.
   - A plaintext `server_name` is the normal case for 1.2 *and* 1.3; ECH is the
     only thing that removes it. See `ai-protect/docs/network-egress-sni.md`'s
     "TLS 1.3 / ECH".
2. **CA trust (confirmed)** — the decisive test, and the one nobody has run:
   stand up a *terminating* proxy with a CA installed in (a) the system/login
   store and (b) nothing else, then (c) only in `NODE_EXTRA_CA_CERTS`. Record
   which combination the agent accepts. This is what tells you whether an MITM
   relay works for that agent at all.
3. **Stack** — usually answerable by reading the shipped bundle
   (`grep` for `undici`/`node-fetch`/`reqwest`/`electron`), which is cheaper
   than measuring and is good enough for the guess column.

⚠️ Compliance: measuring CA trust needs a real request from the agent, so for
GitHub Copilot that must happen against a **non-IP / open-source repo**, per
the pilot scope recorded in `vscode-copilot-enterprise-gate-account-test.md`
§3.

## What this file is not

Not a statement that the unknowns are risky. For the redirect design the
realistic reading is that **plaintext SNI is near-universal** and ECH needs
client, server and DNS all cooperating — so the SNI assumption is probably
safe, and the column that actually varies per agent is **CA trust**. That is
the one worth measuring first; the TLS columns are mostly there so a future
`min_version` change is not a guess.
