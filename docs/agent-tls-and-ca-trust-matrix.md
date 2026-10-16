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
| `vscode-copilot` | ★ | **Electron `net`** (default) + `@github/copilot` agent-host child | ❓ | ✅ (explicit-proxy mode only — see note) | ❓ | ✅ **Mixed, confirmed 2026-10-15** — see below | **System/login keychain is the dominant path**; `NODE_EXTRA_CA_CERTS` is honored by *some* internal component but not all | terminating `mitmdump` proxy, CA installed via `security add-trusted-cert` into `login.keychain-db`; full chat/auth round-trip observed both ways |

  **CA trust (confirmed) detail for `vscode-copilot`, measured 2026-10-15:**
  - **System/login keychain: fully trusted.** CA added to `login.keychain-db`
    only (`security add-trusted-cert -r trustRoot`, no System-wide change).
    Result: **0 TLS rejections across 40 relayed requests** — every
    `api.github.com`, `api.business.githubcopilot.com`,
    `exp.business.githubcopilot.com` call succeeded, including
    `/copilot_internal/user`, `/copilot_internal/v2/token`,
    `/copilot_internal/managed_setting…`, `/models`. Clean, unambiguous.
  - **`NODE_EXTRA_CA_CERTS`: partial, inconsistent — not a clean yes/no.**
    Same CA, same hosts, `NODE_EXTRA_CA_CERTS` set at process launch (no
    keychain trust in effect for this run). Per-host result was **mixed, in
    the same burst**: `api.github.com` 16 relayed / 15 rejected,
    `api.business.githubcopilot.com` 8 relayed / 3 rejected,
    `mobile.events.data.microsoft.com` 6 relayed / 10 rejected. Successful
    calls included real CAPI traffic (`/copilot_internal/user`, `/v2/token`,
    `/models`, `/agents`, `/embeddings/models`), so the channel is real, not
    a fluke — but different internal components of VS Code/Copilot evidently
    make independent TLS-trust decisions for the identical hostname. This
    matches the `copilot` CLI row's "mixed" finding, just split differently
    (there it's Node-vs-native-Rust; here it looks like Electron's `net`
    vs. a Node-based path inside the extension, not yet isolated further).
  - **Note on the SNI column**: marked ✅ only for *explicit proxy mode*
    (`http.proxy`, this test's setup) — `mitmdump` in that mode learns the
    destination from the client's `CONNECT` line, not from sniffing SNI, so
    this test does not confirm SNI presence for a *transparently* redirected
    flow (the connect-redirect design's actual scenario). That remains ❓.
  - **No-trust baseline, run before either of the above**: same proxy, same
    CA, installed nowhere. Every host — including `api.github.com` and
    `api.business.githubcopilot.com` — aborted the TLS handshake immediately,
    zero exceptions. Confirms cert validation is not silently bypassed; the
    two successes above are attributable to the trust step, not to a broken
    check.
  - **Compliance incident during the first (`NODE_EXTRA_CA_CERTS`) run**: VS
    Code relaunched into whatever workspace was last open (`ai-protect`), and
    Copilot's background discovery made an automatic repo-scoped API call
    (`/repos/squarex-ai/ai-protect/...`) through the intercepting proxy —
    repo identity only, no code/chat content, but exactly what the pilot's
    non-IP-repo rule exists to prevent. Not anticipated before relaunching.
    Fixed for the second run by launching into a genuine empty throwaway
    folder (no git identity at all) — confirmed 0 repo-identity references in
    that run's log. The flow-capture file from each run (which holds the
    real session's live bearer tokens once TLS is terminated) was securely
    deleted immediately after each run, not retained.
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
