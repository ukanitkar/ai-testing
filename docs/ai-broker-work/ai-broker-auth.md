# ai-broker — identity & auth (design + current state)

> Scope: how ai-broker authenticates to the ZAX backend, where the user
> credential comes from, and how that relates to ai-protect's device identity.
> Underpins **both** legs (MCP + LLM). Companion to
> `docs/ai-broker-work/ai-broker-llm-brokering.md`. Findings grounded in code as of 2026-08-11.

## TL;DR

- ai-broker and ai-protect talk to **two different central backends**, over
  **HTTP APIs** (never a direct DB): ai-protect ↔ **ai-platform device plane**
  (`/endpoint/v1/*`, `wdc_` device credential); ai-broker ↔ **ZAX control plane**
  (Vector + Bumblebee on `api.<cloud>`) + **gateway** data plane (Optimus).
- The credential the broker needs is a **ZAX user JWT** → exchanged into an
  **instance JWT** → a **triple JWT** carrying capabilities. Today ai-broker
  gets that user JWT from **its own OIDC** (browser), cached in a sidecar.
- A handoff so ai-protect/ZCC *provides* the user JWT (skip per-user OIDC) is
  **designed but not built** — the SDK accepts it, but neither `ai-broker-mon`
  nor the daemon wires it. See [Handoff status](#the-aid_user_jwt-handoff--designed-not-built).
- **ai-protect cannot currently obtain the broker's user JWT** — it holds a
  *device* credential + the *bound-user id*, and has no client for the ZAX
  control-plane APIs. See [ai-protect's identity capabilities](#ai-protects-identity-capabilities--and-the-gap).

## Two backends, two API surfaces

Neither component queries a central database directly — both go through REST.

| | ai-protect | ai-broker |
|---|---|---|
| Backend | **ai-platform** (device plane) | **ZAX control plane** + gateway |
| Base | enrolled `--server-url` | `api.<cloud>` / `gateway.<cloud>` |
| Auth | `wdc_` **device** bearer credential | **user JWT → instance JWT → triple JWT** |
| Holds | device identity, **bound `users.id`**, settings, discovered artifacts | broker **agent identity + capabilities** |

**Device-plane endpoints** (`src/utils/enrollment.rs`, platform client):
```
/endpoint/v1/enroll   /heartbeat   /config   /events(/bulk)   /resolve
/telemetry   /uploads/presign   /files/presign   /files/confirm
/agents/raw-configs   /releases/artifact
```

**ZAX control-plane endpoints** (`ai-broker/sdk/src`):
```
Vector:    /vector/v1/sdk/agents:register   :status   /vector/v1/sdk/brokers
Bumblebee: /bumblebee/v1/activations         /bumblebee/v1/token-exchange
Gateway:   gateway.<cloud>  (brokered MCP + LLM traffic — Optimus)
```

## The token chain (broker side)

```
user authenticates (OIDC)            → ZAX user JWT   (~5 min, offline_access, scope+aud+tenant)
  → Vector agents:register           → agent identity (approved / active)
  → Bumblebee activations            → instance JWT
  → Bumblebee token-exchange         → TRIPLE JWT  (carries intersected_caps)
  → gateway (Optimus)                → brokered MCP / LLM
```

`intersected_caps` = *requested ∩ admin-granted* capabilities. **If empty, the
gateway 403s all brokering** — the current dev blocker (see the LLM doc's Live
verification). The user JWT is the *first* input and the thing a handoff would
supply; everything downstream is minted by the SDK.

## Bound user id vs user JWT

A frequent point of confusion — they are different *kinds* of thing:

| | Bound user id | User JWT |
|---|---|---|
| What | identifier (`users.id`, a name) | credential (a signed proof) |
| Secret? | no | yes (bearer) |
| Expires? | no (stable) | ~5 min (refreshable via `offline_access`) |
| Verifiable alone? | no (needs a lookup) | yes (signature) |
| Grants access? | no | yes |
| Mints the triple JWT? | no | **yes** (it's the input) |

The id usually appears **as a claim inside** the JWT (`sub`), so you can read the
id *from* a JWT — but **not the reverse**: an id can't become a JWT without the
user actually authenticating. This is why "the daemon knows the bound user"
isn't enough to skip OIDC.

## Where the user JWT comes from today

- **SDK is ready to receive one.** `ai-broker/sdk/src/startup.rs`
  `authenticate_stage`: `match zax_user_jwt { Some(j) => j, _ => oidc_login::login(cfg) }`
  — a caller-supplied JWT skips OIDC; `StartupOptions.zax_user_jwt` is the seam.
- **But `ai-broker-mon` sources it from its own OIDC.** `mon/src/common.rs`
  `sdk_init` sets `zax_user_jwt` from the **cached sidecar**
  (`~/.ai-broker/.credentials.json`), written after the SDK's own OIDC. No cache
  ⇒ browser OIDC runs. `AID_USER_JWT` is **not read** anywhere in `mon`.

## The `AID_USER_JWT` handoff — designed, not built

Intent (per `src/subscribers/ai_broker_launch.rs`): the root daemon injects the
ZAX user JWT via `AID_USER_JWT` "so the SDK skips OIDC," sourced from the
enrolled identity / bound user.

| Layer | Provide-JWT-from-ZCC | Evidence |
|---|---|---|
| SDK | ✅ designed | `StartupOptions.zax_user_jwt` skips OIDC when supplied |
| `ai-broker-mon` | ❌ not wired | `sdk_init` reads its own sidecar; no `AID_USER_JWT` read |
| daemon (`ai_broker_launch`) | ❌ TODO | `.env("AID_USER_JWT", …)` is commented-out |

Closing it is **two edits**: (1) `mon` reads `AID_USER_JWT` → passes it as
`InitOptions.zax_user_jwt`; (2) the daemon sets `AID_USER_JWT` when spawning
`ai-broker-mon`. But (2) presumes the daemon *has* a broker user JWT — which it
does not (below).

## ai-protect's identity capabilities — and the gap

What ai-protect **has** (`src/utils/enrollment.rs`, `src/identity/`):
- **Device enrollment** → a server-issued **device identity** + `wdc_` **device**
  bearer credential (device plane only). Persisted as root-only `identity.json` +
  `credential`.
- The **bound user's `users.id`** (an id, recorded at enroll) — plus email for
  display. An identifier, not a token.
- **Discovery** of *other agents'* tokens (Codex `id_token`, Antigravity
  `access_token`, …) — for identity attribution, handled **presence-only** per
  the content policy. Not ZAX, not reusable as a broker credential.

What it **lacks**: any client for the **ZAX control plane** (no
Vector/Bumblebee/`oidc_login` code in `src/` — that lives entirely in the broker
SDK), and therefore **no ability to obtain a ZAX user JWT** with the broker's
audience/scope.

**So the handoff needs a capability that doesn't exist yet**, via one of:
1. **Exchange the device identity for a broker user token** — mint a ZAX
   user/broker JWT from the `wdc_` device credential + bound-user id. Requires
   **backend support** (device-cred → broker-token exchange); not evidenced.
2. **Extend SSO enrollment to also capture a broker-scoped ZID user token**
   (`offline_access`, broker audience) and persist it for the daemon to hand off.
   Today SSO-enroll keeps only the device credential.

Until one exists, `ai-broker-mon` doing its own OIDC is the only working path.

## Intended end-state (from the SDK auth whiteboard)

The onboarding design (imported notes) frames it as:
1. AI Protect **discovers** the agent.
2. AI Broker **onboarding**: agent metadata → API → **triple JWT** back.
3. AI Protect **writes the agent config** with broker endpoints + **[triple JWT |
   Vanity URL]**, choosing a delivery shape:
   - **loopback proxy (LLM) + stdio (MCP)** — option (b), built (this repo), or
   - **broker / Vanity URL** — option (a), unbuilt.
4. **Refresh the triple JWT** — and, for the Vanity-URL shape, AI Protect
   **rewrites the token in the agent's settings file** on refresh (the original
   reason a resident daemon exists).

Current code implements option (b) with ai-broker doing its own OIDC; the
identity-handoff (step "user JWT provided by ZCC") and the Vanity-URL
token-refresh writer are the gaps.
