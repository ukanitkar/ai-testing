# Testing ai-protect/ai-gateway on a disposable VM, without the real ai-platform backend

2026-10-22. For running `ai-protect`'s full daemon (and the `ai-gateway`/AI
Broker it launches) on a disposable Windows VM (DVM) — or any throwaway
box — with no real tenant, no real backend, no enrollment. Point the daemon
at a local mock of ai-platform's device plane instead.

## The contract, sourced from `ai-protect`'s own code

- **`--server-url`** is pure backend config — "it picks the backend, in any
  mode" — and wins over an enrolled identity's stored URL. Resolution order
  (`src/main.rs:1205`): managed store (MDM) > `--server-url` flag >
  `ZS_AI_PROTECT_SERVER_URL` env > `config.toml` > enrolled identity's URL >
  compiled dev default (`http://localhost:8080`). On a clean DVM, nothing
  above the flag is set.
- **`--allow-unenrolled`** (`src/main.rs:1214`) is required alongside it — an
  unenrolled `--storage http` daemon otherwise just idles waiting for
  enrollment and never heartbeats at all. This stamps events with a
  placeholder identity (tenant `"default"`, random device UUID).
- **Two calls matter**, both flat JSON (no envelope), confirmed against the
  actual structs in `src/services/heartbeat.rs`:
  - `POST {server-url}/endpoint/v1/heartbeat` → `HeartbeatResponse`. Only
    `ingested: bool` is required; every other field (including
    `config_version: u64`) has `#[serde(default)]`.
  - `GET {server-url}/endpoint/v1/config` → `ConfigResponse`. Only
    `version: u64` is required; `settings`/`policy`/`managed_configs` all
    default to absent/`None`.
  - The daemon only calls `/config` when the heartbeat's `config_version`
    differs from what it already holds (starts at 0) — bump it to force a
    (re-)fetch.
- **No auth to fake.** `with_device_auth()` only attaches a bearer token if a
  device credential already exists; unenrolled, there is none, so every
  request arrives with no `Authorization` header.

## The tenant/AI-Broker gate — two independent layers, and which one each mock drives

`ai_broker_launch` (`ai-protect/src/subscribers/ai_broker_launch.rs`) decides
whether to spawn `ai-gateway` from **two merged layers**, not just the pushed
config:

1. **`<gateway home>/init.yaml`** — a local bootstrap file, read straight off
   disk (`load_init_config_at`, home = `<broker owner home>/.zsai-gateway/`,
   filename `init.yaml` — both `gateway_util::paths::HOME_DIRNAME` and
   `control_files::INIT_FILE_NAME`). Carries `cloud` + `oidc.issuer` as a
   baseline that needs no backend at all.
2. **`settings.ai_gateway.{cloud, issuer, ...}`**, pushed via
   `GET /endpoint/v1/config` → `settings.received`. **Settings win; blank
   there falls back to `init.yaml`, never to a compiled-in value**
   (`tenant_from_with`/`or_local`, `ai_broker_launch.rs:756-792`).
3. The broker only actually spawns when **both**: `settings.ai_broker.enabled`
   is not explicitly `false` (**absent defaults to `true`**), AND
   `tenant_is_usable()` — `tenant.cloud` and `tenant.oidc.issuer` are both
   non-empty, from whichever of the two layers above supplied them
   (`gateway_enabled_with`, `ai_broker_launch.rs:826-838`).

So there are two valid ways to satisfy the gate, and the two mocks in this
repo each drive a different one:

| Mock | Drives | Needs a local `init.yaml`? |
|---|---|---|
| **`ai-gateway/scripts/dev_device_plane.py`** (pre-existing) | Only `settings.ai_broker.enabled` | **Yes** — relies on `init.yaml` already carrying `cloud`/`issuer` on the test box |
| **`ai-gateway/scripts/mock_config_server.py`** (this session) | `settings.ai_gateway.{cloud, issuer}` directly | **No** — fully self-contained, nothing to hand-author on a fresh DVM |

Use `dev_device_plane.py` if the DVM already has (or you're also testing)
`init.yaml`-based bootstrap, or if you want its extra features: a built-in
delayed config-version switch (for race-free "wait N seconds, then flip"
tests like a log-off scenario), broader endpoint stubbing
(`/events`, `/telemetry`, `/files/*`, `/uploads/presign`, `/health`), and
env-var driven toggling (`AI_BROKER_ENABLED`, `CONFIG_VERSION`,
`HEARTBEAT_INTERVAL_SECONDS`) without editing the file.

Use `mock_config_server.py` for the simplest possible from-scratch run — a
disposable VM with nothing pre-placed — since it supplies the tenant
directly and needs no `init.yaml` at all.

## Running it

```bash
# On the DVM, pick ONE mock and start it:
python ai-gateway/scripts/dev_device_plane.py          # needs local init.yaml for cloud/issuer
# — or —
python ai-gateway/scripts/mock_config_server.py         # self-contained, no init.yaml needed

# Then, elevated/admin:
zscaler-ai-protect daemon --server-url http://localhost:8080 --allow-unenrolled --no-install-hooks
```

`--no-install-hooks` (and `dev_device_plane.py`'s own usage note mentions
`--no-install-exts`) avoid the daemon touching real AI-tool configs/hooks on
the test box while you're just exercising the gateway spawn path — see
`AGENTS.md`'s own warning that `--no-install-hooks` alone is **not**
sufficient against `hook_enforce`'s separate settings-driven install path if
your mock ever starts a sending a settings frame with no `enforce_hooks` key.

Tenant used for the self-contained mock's default settings (matches the real
macOS e2e run documented in `vscode-copilot-real-optimus-e2e.md`):
`cloud: prod`, `issuer: https://aibroker-engineer.zslogin.net/` — so a
successful spawn here should reach the exact same real backend/Optimus path
already verified end-to-end on macOS, just with the config-fetch leg now
coming from a local mock instead of real ai-platform.

To push a changed config mid-test: edit `mock_config_server.py`'s
`SETTINGS`/`CONFIG_VERSION` and restart it (the daemon's next heartbeat tick
notices the version moved and re-pulls); `dev_device_plane.py` supports the
same via env vars without a restart-and-edit cycle — see its own docstring.
