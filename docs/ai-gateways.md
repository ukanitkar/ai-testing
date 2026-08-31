# AI gateways (`ai_gateways.*`)

Category doc for `src/tasks/ai_gateways/`. Covers what a gateway is (and is
not), the task → event contract, the safety boundary every gateway detector must
honor, where state lives today, and what to do to add a second gateway kind.
Per-gateway detail lives in its own doc — today that is
[`litellm-discovery.md`](litellm-discovery.md).

## What a gateway is

A **model gateway** is a process that sits between a caller and one or more
model providers: it terminates an OpenAI-compatible (or vendor) HTTP API, holds
provider credentials, and routes/fans out to upstreams. LiteLLM is the first
one inventoried; the same shape covers a self-hosted proxy, router, or
credential broker.

A gateway is deliberately **not** any of the other categories:

| Category | Answers |
|---|---|
| `ai_agents.*` | What artifacts (skills / MCP / subagents / instructions) exist for an agent |
| `ai_assistants.*` | Which user-facing assistant frameworks are installed and running |
| **`ai_gateways.*`** | **What model-routing infrastructure is installed, running, and configured on this host** |
| hook events | Which assistant/user made a call, and the gateway URL it was configured with |
| app capture | The HTTP API flavor, requested model, host/path, and status of a request |
| `net_egress` | The actual destination domain, IP, and port a connection reached |

The category records **durable installation and configuration evidence**.
Request activity is not its job and must not be inferred into it — an
OpenAI-compatible request shape alone is never attributed to a gateway
(`docs/litellm-discovery.md`), and the category emits no per-request rows.

## Where it runs

- Registered like any other task: each detector contributes a
  `Task { name: "ai_gateways.<kind>", handler }` to
  [`ai_gateways::TASKS`](../src/tasks/ai_gateways/mod.rs#L54), which
  `src/tasks/mod.rs` folds into `ALL_TASKS` / the global registry. The
  `<category>.<event_type>` name is load-bearing: the backend derives ES index
  names from `category` + `event_type`.
- Scheduled as part of periodic enumeration. `ai_gateways.litellm` is listed in
  `ENUMERATION_TASKS` for **all three** platform arms of
  [`subscribers/enumeration.rs`](../src/subscribers/enumeration.rs#L257) —
  there is no per-OS gateway exclusion today.
- **Not** in `AGENTCFG_RESCAN_TASKS`, and no watcher path routes to it. A
  gateway's authoritative config path is only knowable from a live process's
  argv, so there is nothing stable to watch; freshness is one scan interval
  (stretched by `hook_pressure_max_defer_secs` when the scan governor's
  deferral layer is enabled).
- **Not gated by `collect_artifacts`.** This is operational inventory, not
  artifact collection — see the `ai_gateways.*` note in `AGENTS.md`. Nothing in
  the category has a tenant on/off switch today.
- Runs on the daemon's single `spawn_blocking` scan thread, so it inherits the
  scan governor's demotion/duty-cycle/pause behavior and must be interruptible
  by being *bounded*, not by cooperating with cancellation.

## Task → event contract

One task per gateway kind, one event per tick:

```
category   = "ai_gateways"
event_type = "<kind>"            // e.g. "litellm"
severity   = Info
data       = { "items": [ <gateway row>, … ], "count": <items.len()> }
```

Emitted through `write_observation(event, "ai_gateways.<kind>", "<kind>", count)`
— note the **non-empty `scope_key`**: each gateway gets its own
`state_cache` row, so one gateway's churn never invalidates another's dedup
state. The gate hashes the canonical payload and skips an unchanged tick,
force-emitting when the hash changes or the last emit is older than
`DEFAULT_HEARTBEAT_SECS` (24 h, ±10 % jitter per scope). `Skipped` is a success
result, not an error.

Two properties of the payload shape matter:

- **`items` is a list even though there is exactly one gateway kind per task.**
  It keeps the envelope uniform with every other inventory event and gives a
  future multi-instance gateway somewhere to go.
- **An empty inventory is emitted, not suppressed.** `detect()` returning
  `None` becomes `count: 0` with an empty `items`, which is what clears a
  gateway that has been uninstalled. Pinned by
  `emits_empty_inventory_to_clear_a_removed_gateway`. Do not "optimize" the
  empty case into an early return.

### Gateway row shape

The row is a projection, never a passthrough. LiteLLM's establishes the
category convention, and a second gateway should follow it unless it has a
reason not to:

| Field group | Purpose |
|---|---|
| `kind`, `name` | Stable machine key + display name |
| `installed` | Any durable install evidence **or** a running process |
| `installations[]`, `binary_paths[]` | Where it is installed (package rows, launcher shims) |
| `running`, `processes[]` | Live processes with listener host/port, config path, model |
| `configurations[]` | Per-config-file projection: hash, model rows, sanitized endpoints, presence booleans |
| `*_truncated`, `fields_truncated`, `projection_truncated` | Every cap that was hit, explicitly |
| `*_source` | Provenance of an inferred value (`"cli"` vs `"default_assumed"`) |

Two conventions that are easy to get wrong:

- **Never report an inferred value as observed.** A listener port that came
  from LiteLLM's own default is `listen_port_source: "default_assumed"`, and an
  *invalid* explicit flag is `"invalid_cli_default_assumed"` — not `"cli"`.
- **`installed` must not contradict `running`.** A running gateway is
  `installed: true` even when no package metadata is visible.

## Safety boundary — the category contract

Every gateway detector inherits these. They are the reason the category can
read credential-bearing config at root/LocalSystem at all, so a new detector
does not get to relax them:

1. **No raw bytes leave the endpoint.** Config is parsed in memory into an
   allowlisted projection. Raw YAML/JSON/`.env`, header blobs, keys, tokens,
   and database URLs are never emitted.
2. **No content pipeline.** Because the category is not `ai_agents`, config
   bytes are never hashed for content delivery, registered in the artifact
   cache, persisted as content, or uploaded to S3. The `config_hash` on a
   configuration row is a change-detection identity only — nothing resolves it
   to bytes.
3. **Secrets become booleans.** `api_key_configured`,
   `master_key_configured`, `database_configured`,
   `environment_variable_names` (names only, values dropped). A null or
   whitespace-only value is *not* "configured" (`meaningful()`).
4. **Endpoints are origin-only.** `sanitize_endpoint` keeps scheme/host/port
   and drops userinfo, path, query, and fragment; a `os.environ/…` or `${…}`
   placeholder yields nothing rather than a fake endpoint.
5. **Every file read is owner-bound.** A config (and every recursive include)
   must be owned by the OS identity of the live process that named it. Unknown
   or mismatched owner fails **closed** with a `reason` on the row. On Windows
   a SYSTEM-owned process may additionally read an Administrators-owned managed
   config; on Unix it is uid equality.
6. **Every read is bounded and non-blocking-safe.** 1 MiB per file, 16 files,
   4 include levels. Unix opens with `O_NONBLOCK` so a process-selected FIFO
   cannot wedge the scan thread; Windows performs the open in a killable
   short-lived helper (below) because `CreateFileW` on an attacker-chosen path
   can block indefinitely as LocalSystem.
7. **Every cap is flagged, never silent.** Row caps, string caps (512 chars),
   include-depth and file-count exhaustion each set an explicit boolean.
   Unreadable and invalid-YAML rows still appear, with a reason.
8. **Nothing is probed, launched, or called.** No port scans, no gateway API
   calls, no database connections, no starting a stopped gateway. (Contrast
   `mcp_discovery_enabled`, which *does* launch user code and is therefore
   tenant-gated. A gateway detector that ever wants to probe needs its own gate
   and its own doc section — do not add it silently under this contract.)

### The Windows read helper

`litellm_config_reader.rs` is `#[cfg(windows)]` and is the only privileged
subprocess in the category. Shape worth knowing before touching or
generalizing it:

- The daemon re-spawns **its own binary** (`current_exe`) with the hidden
  `litellm-config-read-internal` subcommand (`src/main.rs:658`), writes one
  bounded JSON request on stdin, and reads one bounded JSON response.
- The helper refuses unless it is running as a service **and** its parent's
  canonicalized exe equals its own (`spawned_by_local_agent`). Parent
  attestation is part of the privilege boundary — the helper inherits
  LocalSystem, so caller-supplied owner SIDs must never be authority for what
  SYSTEM reads.
- It opens with `FILE_FLAG_OPEN_REPARSE_POINT`, rejects reparse points,
  directories, and non-`FILE_TYPE_DISK` handles, re-validates that the *opened
  handle* resolves to a local DOS drive, then checks ownership on the handle.
- Deadline is `min(2 s per file, remaining of the 10 s traversal budget)`. The
  child is in a `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` job object, so daemon
  shutdown cannot orphan a reader blocked in `CreateFile`.

## State: what is stateless today

The whole category is currently **free of module-level state** — no `static`,
`OnceLock`, `Lazy`, or interior mutability in production code under
`src/tasks/ai_gateways/` (the one `Mutex` is a test double, `RecordingWriter`).
Detection is `evidence in → JSON out`, and the task
handlers are plain `fn` pointers, matching the "tasks are pure functions"
contract in `src/tasks/mod.rs`.

The state a gateway scan *depends on* lives in shared layers it does not own:

| State | Owner | Why it is there |
|---|---|---|
| Process snapshot | `ai_assistants::process::snapshot()` — one `Arc<Vec<ProcessInfo>>` per scan epoch, 60 s TTL fallback | `System::new_all()` costs ~50–100 ms; every detector in a tick shares one |
| Python package inventory | `packages::python` cached scan | Same reason |
| Emit/dedup state | `storage::state_cache`, keyed `(task_name, scope_key)` | Server-side dedup contract |

Two places hold *scan-local* mutable state, and they are the real
statelessness seams rather than the statics (there are none):

- `collect_config` threads `&mut visited`, `&mut out`, and `&mut truncated`
  accumulators through recursion. It is correct but not composable: the walk,
  its bounds bookkeeping, and the projection are entangled in one function
  signature.
- The projection helpers thread `&mut fields_truncated` through every field
  read. That is what makes truncation reporting reliable, so a refactor should
  keep the *effect* (a per-row truncation flag) while moving the plumbing into
  a small bounded-string builder rather than sprinkling `&mut bool` through
  call sites.

Neither is shared across ticks, so "make it stateless" here means **make the
per-walk state an explicit value the walk returns**, not "remove a cache".

## Modularity: what is generic vs LiteLLM-specific

Today `litellm.rs` is 1.3 kloc mixing both. A second gateway needs the left
column and none of the right.

**Gateway-agnostic (extract to a shared layer):**

| Piece | Notes |
|---|---|
| `python_entrypoint` / `PythonEntrypoint` | CPython startup-option parsing (clustered short flags, `-m` attached/detached, `--`, `-c`). Nothing LiteLLM about it, and it is the subtlest code in the file |
| `python_environment_root` | `…/bin/python` → env root, `Scripts` on Windows |
| `arg_value`, `resolve_process_path` | `--flag value` / `--flag=value`, cwd-relative resolution |
| `sanitize_endpoint`, `meaningful`, `path_string` | Secret/endpoint policy — should be one implementation for the category |
| `bounded_string{,_with_flag}`, `bounded_path`, the cap constants | Truncation convention |
| `is_executable_launcher` | Per-OS launcher test |
| `read_config_bytes`, `open_config_file`, `owner_matches`, **all of** `litellm_config_reader.rs` | The owner-bound bounded reader is the highest-value extraction: it is the security-critical part and has nothing to do with LiteLLM's schema |
| `collect_config`, `config_status_row`, `include_paths` shape | A generic "walk an include graph under caps, tolerating unreadable nodes" |
| `mod.rs::emit_litellm` | Identical for every gateway once `kind` is a parameter |

**LiteLLM-specific (stays behind a per-gateway seam):**

`detect`, `is_litellm_process`, `find_litellm_binaries`, the flag names
(`--config/-c`, `--host`, `--port`, `--model`, `--api_base`), the
`0.0.0.0:4000` defaults, the YAML schema keys (`model_list`, `litellm_params`,
`include`, `general_settings`, `litellm_settings`, `router_settings`,
`environment_variables`), and `config_projection`'s field set.

### Couplings to untangle first

- `litellm_config_reader.rs` imports `MAX_CONFIG_BYTES` from `super::litellm`
  (`pub(super)`). The byte cap belongs to the reader, not to a gateway's
  schema module — invert that dependency before adding a second gateway, or
  gateway #2 ends up importing LiteLLM's constants.
- The hidden CLI subcommand is named `litellm-config-read-internal`
  (`src/main.rs:658`, echoed in `litellm_config_reader.rs:126`). It is a
  self-spawn of the same binary, so renaming it to something
  gateway-neutral is internally safe (no cross-version skew) — but it is also
  a documented privilege boundary, so rename it in one commit that keeps
  `running_as_service` + `spawned_by_local_agent` intact.
- `mod.rs` hardcodes `"litellm"` in three places (event type, scope key, error
  string). Fine for one gateway; it is the thing a descriptor table replaces.

### The constraint any design has to respect

`TaskFn` is a bare `fn` pointer and `TASKS` is a `pub const`. So a registry
cannot be a `Vec<Box<dyn Gateway>>` built at runtime — each gateway still needs
one monomorphic `fn(TaskInput, &dyn EventWriter) -> TaskResult` visible in a
const array. The two shapes that work:

1. **Descriptor + generic adapter.** A `trait Gateway` with associated consts
   (`KIND`, `NAME`) and a `fn detect() -> Option<Value>`, plus
   `fn adapter<G: Gateway>(input, writer) -> TaskResult`. `TASKS` then holds
   `Task { name: "ai_gateways.litellm", handler: adapter::<LiteLlm> }` — const,
   monomorphic, no macro.
2. **A small declarative macro** generating the adapter fn and the `TASKS`
   entry per gateway, if the trait's associated-const ergonomics get in the way
   of `name` needing to be a `&'static str` literal.

Shape 1 is preferable: it keeps `TASKS` greppable and requires no macro
expansion to read.

## Adding a new gateway

1. Add `src/tasks/ai_gateways/<kind>.rs` exposing
   `pub fn detect() -> Option<Value>` returning the row shape above (or the
   `Gateway` impl, once the seam exists).
2. Register the task in `ai_gateways::TASKS` as `ai_gateways.<kind>`.
3. Add `"ai_gateways.<kind>"` to every applicable arm of `ENUMERATION_TASKS`
   in `subscribers/enumeration.rs` — all three unless the gateway genuinely
   cannot exist on a platform, and say why in a comment if you skip one.
4. Reuse the shared reader for any config file. If the gateway has a *fixed*
   config path (unlike LiteLLM), the owner-binding rule needs restating for
   that case: there may be no live process to bind ownership to, so decide and
   document what identity the file must be owned by before reading it.
5. Honor every numbered item in the safety boundary, and add tests that pin the
   ones that are easy to regress: a secret-bearing fixture whose secret must
   not appear in the serialized output, an owner-mismatch fail-closed case, and
   the cap/truncation flags.
6. Coordinate the new `event_type` with ai-platform (index/schema) and write
   `docs/<kind>-discovery.md` with the gateway's own evidence and limitations.

## Tests

- Unit tests live next to the code: process/argv recognition, the projection's
  secret and cap behavior, include-depth and file-cap truncation, owner
  fail-closed, and (Unix) the FIFO rejection.
- `mod.rs` covers the emit contract, including the empty-inventory case.
- Ignored live test per gateway, using a non-routable fixture — for LiteLLM,
  `tests/fixtures/litellm/` plus
  `cargo test -p ai-warden live_litellm_process_end_to_end --lib -- --ignored`.
  See [`litellm-discovery.md`](litellm-discovery.md#runtime-validation).
