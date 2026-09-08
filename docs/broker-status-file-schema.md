# `.broker.zip` / `.status.zip` — wire schema reference

Source of truth: `ai-gateway/protocol/src/lib.rs` (crate `protocol`, linked by
both ai-protect and ai-gateway so a renamed field is a compile error on both
ends, not a silent wire mismatch). This doc is a reading aid, not a
replacement — re-check the source before relying on a field name or default.

Current wire version: `BROKER_SCHEMA_VERSION = "1"`. Bumped only on a
breaking change; an additive field an old reader ignores does not bump it.

## Transport model

No persistent socket. Each real user's gateway home
(`~/.zsai-gateway` by default, `$ZSAI_GATEWAY_HOME`) holds two gzipped-JSON
files, each side watching the one it reads:

| File | Writer | Reader | Contract |
|---|---|---|---|
| `.broker.zip` | ai-protect | ai-gateway (service mode) | `BrokerFile` — full snapshot every write |
| `.status.zip` | ai-gateway (service mode) | ai-protect | `StatusFile` — full snapshot every write |

**Full snapshot, not a change feed, on both sides.** Neither file is ever a
diff or an append. `.broker.zip`'s `agents[]` is ai-protect's complete current
discovery list every time; `.status.zip`'s `agents[]` carries every agent's
complete current wiring every time, including one already reported healthy
on the previous write. This is why the merge on the ai-protect side
(`ConfigDelta`, below) has to be idempotent — the same delta arrives on every
write for as long as that agent is serviceable, not once.

**Absent means empty, never missing.** Every string field is present on the
wire and carries `""` when unknown — a reader never has to distinguish
"omitted" from "no value" — and every field carries `#[serde(default)]`
regardless, so a writer built before a field existed still decodes.

## `BrokerFile` — ai-protect → ai-gateway

```
BrokerFile {
  schema_ver: String,              // "1"; "" from a pre-field writer is treated as a mismatch
  tenant: Tenant,
  credentials: UserCredentials,
  platform: Platform,
  device: Device,
  provenance: Provenance,
  agents: Vec<AgentEntry>,         // full current discovery list, never an append
}
```

- **`tenant.cloud`** — cloud/endpoint selector; `""` ⇒ ai-gateway's compiled-in
  default. **A changed value rebuilds the whole `AgentManager`** (see the flow
  doc) — it isn't just consulted, it forces the endpoints, OIDC, and
  credential store to be re-derived.
- **`tenant.oidc`** — `Oidc { issuer, client_id, audience, scope,
  authorize_path, token_path, discovery_path, tenant_id_claim }`. `""` in any
  field means "use the SDK default"; a blank `issuer` specifically means
  ai-gateway cannot run interactive OIDC at all if it needs to.
- **`credentials`** — `UserCredentials { user_jwt, refresh_token }`. Both
  blank ⇒ "ai-protect has nothing to give"; ai-gateway falls back to its own
  cached refresh token, then interactive login. `UserCredentials::available()`
  is `!user_jwt.is_empty() || !refresh_token.is_empty()`.
  ⚠️ **Currently always blank in practice** — `identity::zax_user_credential::fetch`
  on the ai-protect side is a stub (no real ZAX-user-JWT source wired yet).
- **`platform` / `device` / `provenance`** — host facts gathered by
  ai-protect so ai-gateway does not re-probe; field-for-field the shape the
  SDK's own enrolment payload expects. `provenance.root_proof` /
  `root_proof_type` (`"none"` today) and `provenance.attestation.tpm_present`
  are wired but not yet populated with anything meaningful.
- **`agents[]`** — one `AgentEntry` per agent ai-protect's discovery
  inventory maps to a known broker adapter id (`client_label_to_broker_id`
  in `src/subscribers/ai_broker_launch.rs`). Written **without diffing**:
  ai-gateway is the one that dedups/filters against its own
  `agents::ENABLED_AGENTS` list. `AgentEntry` flattens a `Process` (`name`,
  `format`, `entry_point`, `language`, `filename`, `runtime`, `cmdline`,
  `software`, `pid`) plus `description` and an optional `parent: Process` (the
  launching process, `None` when installed-but-not-running). **Today
  ai-protect only ever populates `process.name`** (the adapter id string,
  e.g. `"codex"`) — every other `Process`/`Software`/`CodeSigning` field is
  the type's default. The full shape exists on the wire (code-signing state,
  binary hash, publisher, cert chain) for when that richer discovery data is
  wired through; it is not a schema gap, it is an unfinished populate.

## `StatusFile` — ai-gateway → ai-protect

```
StatusFile {
  message: String,                 // human-readable, for logs
  credential: CredentialStatus,
  agents: Vec<AgentStatus>,        // full current wiring, in .broker.zip's agent order
}
```

- **`credential.message`** — a `CredentialState`: `Good` | `Expiring` |
  `Expired` | `Other(String)` (`Other("")` is the default, "nothing reported
  yet"). `CredentialStatus::needs_refresh()` is true for `Expiring` /
  `Expired` only. ai-protect edge-triggers on the **false→true transition**
  of `needs_refresh()` to refetch a credential and rewrite `.broker.zip` —
  it does not refetch on every snapshot while the state stays `Expiring`,
  and an unrecognised `Other` value is deliberately never treated as a
  refresh request (acting on a value neither side can interpret would turn
  every unknown string into a credential fetch).

### `AgentStatus` — one row per agent

```
AgentStatus {
  name: String,                    // echoed VERBATIM from the .broker.zip entry
  status: AgentRegistrationStatus, // NotSupported | NotApproved | NotAbleToRegister | Success | Other(String)
  aid_key: String,                 // "" until registered
  agent_id: String,                // "" until registered
  config: Vec<ConfigDelta>,
  process_env: Vec<ManagedEnvVar>,
  process_env_commands: Vec<String>,
}
```

- **`name` is echoed, not normalised.** `.broker.zip` may name an agent by
  adapter id (`"codex"`) or display name (`"Codex CLI"`); `AgentStatus.name`
  returns whichever form it was sent, because ai-protect correlates rows by
  that string.
- **`status`** — only `Success` counts (`is_success()`). The two
  in-progress values ai-protect's own code treats specially are carried as
  `Other("enrolling")` / `Other("refreshing")` (the constants
  `agent_manager::ENROLLING` / `REFRESHING`) — distinguishing a first
  enrolment from a lapsed one that's re-enrolling.
- **`config`** — **empty until that agent is both enrolled AND currently
  signable.** This is the gate that matters most: a `ConfigDelta` is never
  emitted for an agent that can't yet be served, specifically so ai-protect
  never points an agent at a listener with nothing behind it. See
  `AgentManager::state_of` — `enrolling` or `!is_serviceable()` ⇒ empty
  status with no config; a lapsed triple JWT (`!store.agent_can_sign`) also
  reports empty, as `Other("refreshing")`.
- **`process_env` / `process_env_commands`** — the process-env delivery leg
  (Amp, Cursor's `cursor-agent`, Antigravity's `agy`, Aider's Anthropic-family
  leg, …): named OS env vars for an agent with no config-file knob at all.
  `process_env_commands` names the exact `$PATH` command(s) the vars are
  scoped to (e.g. `["cursor-agent"]`) — required because two agents can want
  different values for the same var name (`HTTPS_PROXY`), which a
  shell-wide `export` can't represent; ai-protect's `src/ai_broker_env/`
  wraps each named command in its own shell function (Unix) or PowerShell
  profile function rather than exporting globally. Empty iff `process_env`
  is empty. **ai-gateway never touches the OS environment itself** — this
  field only describes intent, same division of labor as `config`.

### `ConfigDelta` — one file, one merge-able change

```
ConfigDelta {
  file: String,      // home-relative, e.g. ".codex/config.toml"
  setting: Value,    // a JSON object merges key-by-key; anything else overwrites
}
```

ai-gateway computes this; **ai-protect is the only writer of the real file**,
by design — ai-gateway never touches an agent's own config. Two gates on the
ai-protect side that are easy to miss when reasoning about this from the
schema alone:

1. **The allowlist** (`gateway_util::config_merge::ALLOWED_CONFIG_PATHS`,
   32 entries as of this doc) — `file` must be an exact match or the delta
   is refused on arrival with "not an allowlisted agent-config path", *even
   if* the adapter that produced it is otherwise correct. Every new adapter
   or new settings file needs an entry here — three agents this session
   (Kiro, Antigravity, Aider) had a *correct* delta silently refused because
   this list was never updated when their adapter shipped.
2. **The format dispatch** (`gateway_util::config_merge::format_for`, by
   file extension) — `.toml` merges via `toml_edit` (preserves comments on
   untouched keys), `.yaml`/`.yml` merges via `serde_yaml` (comments on
   untouched keys are **lost** — no AST-preserving edit exists for YAML),
   anything else merges as JSON via a JSONC-tolerant parser (comments
   stripped on re-serialize). All three refuse rather than replace on a
   parse failure — a malformed existing file is left alone, not overwritten
   with an empty object.

### `ManagedEnvVar` / `EnvVarKind`

```
ManagedEnvVar { name: String, value: String, kind: EnvVarKind }
EnvVarKind = LoopbackUrl | CaPath | Fixed
```

`kind` is how ai-protect's "never clobber a real pre-existing value" guard
decides ownership **without re-deriving policy ai-gateway already computed**:

- `LoopbackUrl` — `value` is expected to be `http(s)://127.0.0.1:*` or
  `localhost:*`. Ours iff whatever is currently set, if anything, is *also*
  loopback-shaped.
- `CaPath` — `value` is a filesystem path to the local CA bundle. Ours iff
  the current value also names it (path suffix match on
  `certs/ca-cert.pem`).
- `Fixed` — `value` is a literal with no per-install variation (e.g.
  Cursor's `NODE_USE_ENV_PROXY=1`). Ours iff the current value, if any,
  already equals it exactly.

## What's on the wire but not yet populated

Worth flagging explicitly for anyone reviewing the schema expecting more than
ai-protect currently sends:

- `AgentEntry.process.software` (name/version/hash/bundle id/publisher) and
  `.code_signing` (the full X.509 chain-and-trust shape) — fully defined,
  always default today. `discovered_broker_agents()` only ever sets
  `process.name`.
- `AgentEntry.parent` — always `None`; nothing populates "what launched
  this agent" onto the wire yet, though ai-protect's own hook-side process
  lineage walk (used elsewhere for policy) could feed it.
- `Provenance.root_proof` / `attestation.tpm_present` — always blank/false.
- `BrokerFile.credentials` — always blank in practice (see above).

None of these are schema gaps — the fields exist specifically so populating
them later is additive, not a wire break.
