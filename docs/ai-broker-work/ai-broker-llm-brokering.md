# ai-broker — multi-provider LLM brokering (design + status)

> Scope: how ai-broker points each agent's **LLM** traffic through the ZAX
> gateway (Optimus), beyond Claude. Companion to the MCP adapters in
> `ai-broker/mon/src/agents/` and to `docs/ai-broker-work/ai-broker-auth.md` (identity/auth —
> the token chain, the two backends, and the user-JWT handoff). Written 2026-08-10.

## TL;DR

- **The gateway is not the blocker.** Optimus (`~/work/zax/optimus`) already
  brokers ~21 providers (`config/providers/*.yaml`, `traffic_type: llm`),
  including all four priority agents' endpoints: Anthropic, OpenAI, Google
  (incl. the Gemini CLI's `cloudcode-pa.googleapis.com`), and GitHub Copilot.
  It runs as **both** a forward proxy (CONNECT + TLS interception) and a
  host-driven reverse proxy.
- **The ai-broker localhost proxy is already provider-agnostic** at the
  transport level: `sdk/forwarding/llm_proxy::forward` prepends any `upstream`
  origin to the request path and `ZaxMiddleware` signs (RFC 9421 + triple JWT)
  and routes to the gateway. Only the *defaults/naming* were Anthropic-specific.
- **Done in this pass:** `--llm-proxy` gained `--upstream <origin>` / `--port
  <n>` and provider-neutral naming, so one binary can run a proxy per provider.
- **Remaining work is per-agent, client-side, and splits by mechanism** (below).
  Nothing here is blocked on Optimus's *provider config*; each item needs one
  live verification.
- **⚠️ Live finding (2026-08-11):** Optimus's provider *config* supports the
  providers, but brokering is also gated by **per-agent capability entitlement**,
  and that's the current blocker — see [Live verification](#live-verification-2026-08-11).

## Live verification (2026-08-11)

Ran the Codex reverse-proxy leg end-to-end on a dev machine:
`--llm-proxy --upstream https://api.openai.com --port 8789` (ZAX OIDC completed;
REGISTER → ACTIVATE → token-exchange all 200 OK), Codex LLM leg applied to an
isolated `CODEX_HOME` via `--configure-llm codex --base-url http://127.0.0.1:8789/v1`.

**Result — the ai-broker client side is verified; the gateway blocks on
entitlement:**

- A no-auth probe through the proxy logged
  `[forward] POST https://api.openai.com/v1/chat/completions → gateway=gateway.zsagenticdev.ai:443`
  — ai-broker correctly signs (RFC 9421 + triple JWT) and routes to the gateway.
- The gateway returned **HTTP 403 with a Zscaler block page** — *not* a provider
  401. Cross-checked the **Anthropic** leg (`/v1/messages` on a 2nd proxy):
  **identical 403**. So it is **not** provider-specific.
- Root cause is authoritative in the SDK log: the token-exchange returned
  **`intersected_caps=[]`** — the enrolled agent (approved, identity active) was
  granted **zero brokering capabilities** (`intersected_caps` = requested ∩
  admin-granted). Empty ⇒ the gateway denies all brokering.

**Therefore:** LLM brokering (Codex/Gemini/Copilot **and** Claude) is blocked
equally for this agent, and the next action is **gateway/dashboard-side** — grant
the agent brokering capabilities so token-exchange returns non-empty
`intersected_caps`. No ai-broker code change is implied. Then re-probe: a
provider **401** (auth) instead of a Zscaler **403** means brokering is live →
do the real Codex call, confirm `wire_api`, flip `supports_llm_base_url=true`.

**Gotcha for when caps land:** the SDK warns
`TARGET_URL is https:// … an intercepting proxy may not see the inner request …
if you get 401 bad_http_signature, switch to http://`. If the post-caps probe
returns `bad_http_signature`, express the `--upstream` as `http://<host>` (let
the gateway do the upstream TLS) rather than `https://`.

## How the endpoint reaches Optimus (traced from `optimus/config`)

- **Optimus is a cloud gateway**, not endpoint-local. The SDK derives its URL
  from the cloud: `gateway_url_for(cloud) = https://gateway.<cloud>`
  (`ai-broker/sdk/src/config/sdk_config.rs:52`). The endpoint never runs Optimus.
- **Reverse-proxy leg (today)** reaches it by having `ZaxMiddleware` re-route the
  request to the gateway and sign it (RFC 9421 + triple JWT) — that signature
  *is* the per-user ZAX identity.
- **Forward-proxy listener** (`optimus/config/*.yaml` `forward_proxy:`):
  `enabled: true`, `connect_enabled: true`, CONNECT on `listen.tcp_ports`
  (dev `9080`; prod the gateway's port), `connect_allowed_ports: [443]`, inner
  protocols default `[tls_intercept, plainhttp, h2c]`. `tls_intercept` means
  Optimus terminates TLS with its **CA** (`tls.ca_cert`, mounted at
  `/zscaler/<ns>/certs/ca.crt` in prod) and re-enters the pipeline — **clients
  must trust that CA**.
- **⚠️ Identity gap in forward mode.** The forward proxy's only auth knob is a
  *static* `proxy_auth_token` (`Proxy-Authorization: Basic`), **not** the
  per-user triple-JWT the reverse leg injects. So pointing a knob-less agent's
  `HTTPS_PROXY` straight at cloud Optimus routes traffic but drops per-user ZAX
  identity. This is why the forward-proxy path for knob-less agents wants a
  **local** ai-broker component (below), not a direct HTTPS_PROXY to the cloud.

## Two brokering mechanisms

| Mechanism | How the agent reaches the gateway | Needs a base-URL knob? | ai-broker path |
|---|---|---|---|
| **Reverse proxy / base-URL** | Agent's `*_BASE_URL` → localhost proxy → gateway | **Yes** | `--llm-proxy --upstream … --port …` + per-agent `configure_llm` |
| **Forward proxy / TLS-intercept** | Agent's egress → Optimus as HTTPS proxy (MITM) | **No** | route egress + trust the intercept CA (new; see §Copilot) |

Reverse-proxy is what Claude uses today. Forward-proxy is how Optimus already
handles knob-less clients and browser apps.

## Per-agent status & plan

### Claude — DONE (reverse proxy)
`ANTHROPIC_BASE_URL` in `~/.claude/settings.json` → localhost proxy (default
upstream `api.anthropic.com`). `agents/claude.rs::configure_llm`.

### Codex / ChatGPT — reverse proxy, IMPLEMENTED + GATED
- **Gateway:** ✅ `optimus/config/providers/openai.yaml` brokers `api.openai.com`
  `/v1/chat/completions` **and** `/responses`.
- **Client knob written by `agents/codex.rs::configure_llm`:** `~/.codex/config.toml`
  ```toml
  model_provider = "zax"
  [model_providers.zax]
  name = "zax"
  base_url = "https://127.0.0.1:8789/<token>/v1"   # ai-broker OpenAI proxy
  wire_api = "responses"
  ```
  `<token>` is the per-install secret `llm_leg::configured_base_url` reads/creates
  from `$ZAX_DEMO_HOME/llm-proxy.token` — added because a bare loopback TCP port has
  no per-user access control (any local account can connect), so the proxy now also
  terminates TLS with a locally-minted leaf and requires this token as the leading
  path segment. `--configure-llm codex --base-url <url>` (the manual/test path this
  doc's examples use) needs the full `https://…/<token>/v1` form now too — via new
  `toml_cfg` helpers (`upsert_str_table` + `set_scalar_str`); `recover`
  removes the table and unsets `model_provider` **only if still `zax`**
  (`remove_scalar_if_eq`) so a user's later choice is never clobbered.
- **Proxy:** run `--llm-proxy --upstream https://api.openai.com --port 8789`
  (the generalized flags) for the OpenAI leg.
- **GATED:** `supports_llm_base_url` stays `false`, so bootstrap does not wire it
  yet — the code is complete and unit-tested, flip the flag once verified.
- **⚠️ Verify then flip:** the exact `config.toml` keys + which `wire_api`
  ("responses" vs "chat") Codex's active model expects, and that Codex honors a
  custom `model_provider` for auth it didn't mint. On confirm: set
  `supports_llm_base_url=true` and have bootstrap start the OpenAI proxy +
  pass its base URL to `configure_llm`.

### Gemini — reverse proxy path is a GAP
- **Gateway:** ✅ brokers `generativelanguage.googleapis.com` and
  `cloudcode-pa.googleapis.com` (the CLI's Code-Assist endpoint).
- **Client knob:** Gemini CLI's default is **OAuth → Code Assist**, which has no
  clean, documented base-URL override. The API-key path
  (`GEMINI_API_KEY` + `generativelanguage`) may accept a base-URL env, but that
  forces the user onto API-key auth. **No verified knob today** → do NOT write a
  speculative redirect (would break Gemini's LLM).
- **Options:** (a) confirm a base-URL env for the API-key path and use reverse
  proxy for API-key users only; (b) use the **forward-proxy** mechanism (below),
  which needs no knob and covers the OAuth path. (b) is likely the real answer.

### Copilot — forward proxy only (no base-URL knob) — SCOPING
GitHub Copilot CLI has no user base-URL override; its traffic goes to
`api.{business,enterprise,individual}.githubcopilot.com`, which Optimus already
brokers (`optimus/config/providers/github-copilot.yaml`, incl. `/v1/messages`,
`/responses`). So the only path is forward-proxy / TLS-intercept.

**Naïve version (rejected): point `HTTPS_PROXY` straight at cloud Optimus.**
Optimus's forward proxy would route + intercept, but its only auth is the static
`proxy_auth_token` — the request would carry **no per-user ZAX identity** (the
triple-JWT the reverse leg signs). Wrong for a per-user endpoint product.

**IMPLEMENTED (gated, HTTP/1.1, e2e-unverified): a local ai-broker forward/
CONNECT proxy** — `ai-broker-mon --llm-forward-proxy` (`src/forward_proxy.rs` +
`src/mitm.rs`), a sibling to the reverse `--llm-proxy`, closing the identity gap
the same way the reverse leg does:

1. **Route egress:** set `HTTPS_PROXY=http://127.0.0.1:<local-fwd-port>` in the
   Copilot launch environment (Copilot CLI is Node → respects proxy env). No
   config-file edit.
2. **Local MITM + sign + chain:** the local proxy accepts CONNECT, terminates
   TLS with a **local** ai-broker CA (so it can read the inner request), signs
   via the SDK client (`ZaxMiddleware`, same identity as the reverse leg), and
   chains to the cloud gateway. Two distinct CAs: the *local* ai-broker CA the
   agent trusts, vs. the *cloud* Optimus CA (not exposed to the agent in this
   design).
3. **Trust the local CA — narrowly:** prefer a Copilot-scoped
   `NODE_EXTRA_CA_CERTS=<local-ca.pem>` over the OS/user trust store — far
   smaller blast radius, and reversible in `recover`.
4. **Where it lives:** not a per-agent config-file adapter like MCP — an
   environment + trust concern. Add an `AgentAdapter` capability
   (`supports_llm_forward_proxy`) so an adapter declares "broker my LLM via
   forward proxy," and a bootstrap step that (a) starts the local forward proxy,
   (b) sets `HTTPS_PROXY` + `NODE_EXTRA_CA_CERTS` in the agent's launch env.
   **Bonus:** the same mechanism covers Cursor, Windsurf, and Gemini's OAuth
   path — every knob-less agent — turning "impossible" into "supported."

**What's built (`--llm-forward-proxy`):** local CA lifecycle
(`mitm::LocalCa` — mint/persist a CA `0600`, mint per-SNI leaves; unit-tested),
a rustls dynamic SNI resolver (`mitm::SniResolver`), and the CONNECT server
(`forward_proxy.rs`): read CONNECT → 200 → TLS-terminate with a minted leaf
(ALPN pinned `http/1.1`) → the decrypted inner request re-enters the SAME
`llm_leg::build_app` reverse handler with `upstream=https://<host>` so the SDK
re-signs + routes to the gateway. Capability seam `supports_llm_forward_proxy` +
`llm_forward_proxy_env` on the adapter (Copilot/Cursor/Windsurf/Gemini return
`HTTPS_PROXY`+`HTTP_PROXY`+`NODE_EXTRA_CA_CERTS`). Port 8790 (`--port` /
`ZAX_LLM_FORWARD_PROXY_PORT`). `--agents` shows a `fwd=` column.

**Not done (gated / open):** (1) **HTTP/2** interception (ALPN forces h1 today —
some Node clients prefer h2; a compat/perf follow-up). (2) **e2e verification** —
compile-verified + CA/resolver unit-tested, but no live agent/gateway run in the
sandbox. (3) **Env-injection apply path** — nothing sets `HTTPS_PROXY` for a
*user-launched* CLI; the proxy currently just **logs** what each installed agent
needs. Solving this (a shell-profile shim, a wrapper launcher, or launching the
CLI from ai-broker) is the real remaining product decision. Bootstrap does NOT
start this proxy yet.

- **⚠️ Verify:** Copilot/Cursor/Windsurf/Gemini honor `HTTPS_PROXY` +
  `NODE_EXTRA_CA_CERTS`; HTTP/2 need; and pick the env-injection apply mechanism.

## Enablement wiring (already built)

`agents::ENABLED_AGENTS` (Claude/Gemini/Codex/Copilot) gates what bootstrap
wires; `supports_mcp` / `supports_llm_base_url` are *capability*. When a client
mechanism above is verified, flip that adapter's capability flag (and, for
forward-proxy agents, add the new capability) — the agent is already enabled, so
it wires automatically. LLM legs fan out in `bootstrap::configure_llm_legs`.

## Caveat: inspection depth ≠ brokering

Optimus's deepest role-tagged prompt extraction (`ai_metadata` pipeline) fires
only for **OpenAI + Anthropic** and string-valued content today (Phase-2 gap,
`optimus/REQUEST-FLOW.md` ~L243). Other providers are brokered and inspected via
the array-aware inline content-guard fallback — less granular. So "brokered"
and "inspected to Phase-1 depth" are not the same for Gemini/Copilot yet.

## Verification checklist (turns "maybe" → "ship")

- [ ] **GATING BLOCKER — grant the agent brokering capabilities on the ZAX
      gateway/dashboard** so token-exchange returns non-empty `intersected_caps`.
      Verified 2026-08-11 that empty caps ⇒ Zscaler 403 for *all* providers.
      Everything below is blocked on this. Re-probe: provider 401 (not 403) = live.
- [x] ~~ai-broker signs + routes to the gateway for OpenAI *and* Anthropic~~ —
      **verified** end-to-end (client side works; see Live verification).
- [ ] Codex `config.toml` redirect against a live Codex (config-write already
      verified against the real config); confirm `wire_api` (`responses` vs
      `chat`) once caps are granted, then flip `supports_llm_base_url=true`.
- [ ] If a post-caps probe returns `401 bad_http_signature`, switch `--upstream`
      to `http://<host>` (gateway does upstream TLS).
- [ ] Gemini: is there a base-URL env for the API-key path? If not, it rides the
      forward-proxy path with the other knob-less agents.
- [x] ~~Optimus forward-proxy listener port~~ — **traced**: CONNECT on
      `listen.tcp_ports` (dev `9080`), `connect_allowed_ports:[443]`, inner
      `tls_intercept`, CA `tls.ca_cert`. Gateway is cloud (`https://gateway.<cloud>`).
- [ ] **Forward-proxy identity**: direct `HTTPS_PROXY`→cloud Optimus only has
      static `proxy_auth_token` (no per-user JWT) → build the **local**
      forward/CONNECT proxy that signs via the SDK and chains to the gateway.
- [ ] Can the SDK sign an arbitrary inner request captured by a local MITM
      (CONNECT server is new code)? Local CA mint/rotate story.
- [ ] Copilot/Cursor/Windsurf honor `HTTPS_PROXY` + `NODE_EXTRA_CA_CERTS`.
