# zscaler-ai-gateway — operating guide

`zscaler-ai-gateway` enrols each AI agent on the host with the ZAX control plane and
carries that agent's **MCP** and **LLM** traffic through the ZAX gateway. One binary,
two continuous modes and three one-shots.

> **This doc is the operating guide** — how to run each mode, verify it, and undo it.
> For *why* it's built this way (architecture, the identity pipeline, on-disk layout,
> the open-issues list), see the **design record** linked from [README.md](README.md).

## The modes

| Mode | Who runs it | Agent config | Blocks? |
|---|---|---|---|
| *(no args)* / `--service` | the ai-protect daemon | **describes** changes in `.status.zip`; writes none | yes, until stopped |
| `--bridge <agent>` | the **agent**, per session | untouched — reads the credential store | yes, until stdin EOF |
| `--agents` | you | untouched | no |
| `--recover` | you | removes its own keys | no |
| `--sim-daemon` | you, on a research VM | via the service it spawns | yes, until Ctrl-C |

```
zscaler-ai-gateway                 service mode: watch .broker.zip, enrol, serve,
                                   write .status.zip
zscaler-ai-gateway --service       the explicit form of no args; identical
zscaler-ai-gateway --bridge AGENT  MCP stdio relay for one agent session
zscaler-ai-gateway --agents        list agents (id · enabled · installed · mcp · llm)
zscaler-ai-gateway --recover       undo this product's config edits
  --dry-run                        report what would change; write nothing
  --purge-home                     also delete the gateway home entirely
  --clean-backups                  also delete leftover .bak.<ts> files
  --keep-credentials               keep the credential store (removed by default)
zscaler-ai-gateway --sim-daemon    dev harness: play ai-protect's file-protocol slice
  --broker-file PATH               .broker.zip's path (default: <home>/.broker.zip)
  --status-file PATH               .status.zip's path (default: <home>/.status.zip)
```

**No args means service mode.** The ai-protect daemon spawns this binary bare, so a
flag it could forget is a flag that silently changes what runs. The modes are mutually
exclusive, and a recovery-only flag outside `--recover` is an error rather than being
ignored — a stray `--dry-run` must not fall through to a mode that enrols for real.

⚠️ **`--mcp-server`, `--llm-proxy`, `--llm-forward-proxy`, `--control` and
`--configure-llm` are gone.** Each is now rejected as an unknown argument, on purpose:
an installed config still naming one has to fail loudly rather than start service mode
and write to the agent's stdout. `--mcp-server` became `--bridge <agent>`, which takes
the agent as an argument instead of reading it from the environment.

## Who writes what

The daemon and the gateway exchange **files only** — no socket, so either side restarts
independently.

| File | Writer | Reader |
|---|---|---|
| `.broker.zip` | ai-protect | service mode |
| `.status.zip` | service mode | ai-protect |
| `.credentials.zip` | service mode (the only writer) | every bridge, read-only |
| an agent's own config | **ai-protect** | the agent |

ai-gateway never writes an agent's config. `.status.zip` carries a `ConfigDelta` per
file that should change and ai-protect merges it, preserving every key the delta does
not mention. That is the point of the protocol: one privileged writer, and a merge that
cannot lose the user's own settings.

### Two things the service will not do

- **No config until the agent can be served.** A `ConfigDelta` is emitted only once
  that agent's enrolment has completed *and* its triple JWT is unexpired. Until then it
  reports `enrolling` with an empty `config`. Pointing an agent at a listener that
  cannot sign is the failure this gate exists to prevent.
- **An empty `config` is "nothing to change", not "unwire".** ai-protect merges deltas
  and has no retract verb, so an agent whose token lapses keeps the config it was given;
  its requests fail `NoCredentials` until the credentials refresh. Undoing is
  `--recover`'s job.

## Environment

| Var | Default | Purpose |
|---|---|---|
| `ZSAI_GATEWAY_HOME` | `~/.zsai-gateway` | gateway state dir (credentials, logs, restore snapshots) |
| `ZAX_CA_BUNDLES` | — | extra PEM paths to trust, separated by the platform's path separator |
| `ZAX_LLM_PORT_BASE` | `8790` | **first** port of the per-agent listener range (`base + slot`), not a single port |
| `CODEX_HOME` etc. | per agent | the agent's own home override, honoured when reading its config |

## Quick start

> ⚠️ **Research VM only.** Service mode enrols agents and hands ai-protect config deltas
> for your real agent configs. See [TESTING.md](TESTING.md).

```bash
export GW=…/ai-protect/target/debug/zscaler-ai-gateway
cargo build -p ai-gateway-service    # build it
$GW --agents                         # what it can see — writes nothing
$GW --recover --dry-run              # prove recovery works BEFORE you need it
$GW --sim-daemon                     # spawn service mode and drive the file protocol
```

Expect each agent listed as `enrolling` with an **empty** config, then `success` with a
config whose setting names `--bridge <agent>` and that agent's own listener URL. A
config appearing before `success` is the gate failing.

## Verifying each mode

In order of how invasive they are — everything up to `--sim-daemon` touches nothing
you'd have to repair.

### 0. Build + unit tests
```bash
cargo build  --workspace
cargo test   --workspace
cargo clippy --workspace --all-targets
```

### 1. Baseline — writes nothing
```bash
$GW --agents
$GW --recover --dry-run      # expect: "Nothing to repair — config is already clean."
```

### 2. The MCP bridge, without touching any config

`--bridge` reads the credential store and relays. Drive it by hand on stdin:

```bash
tail -f ~/.zsai-gateway/logs/zax.log &      # diagnostics go here, never stdout
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | $GW --bridge codex
```

Two invariants worth asserting rather than eyeballing:

```bash
# stdout is JSON-RPC only — one stray log line corrupts the agent's stream
… | $GW --bridge codex >out.jsonl 2>err.txt; wc -c <err.txt        # expect 0 on stdout

# and the bridge really writes nothing
shasum -a 256 ~/.zsai-gateway/.credentials.zip ~/.codex/config.toml > before.sha
… run it … ; shasum -a 256 ~/.zsai-gateway/.credentials.zip ~/.codex/config.toml | diff - before.sha
```

With no record for that agent the relay still starts and advertises no tools; every
request then fails `NoCredentials`. That is deliberate — a clear failure beats an
unsigned request reaching the gateway.

### 3. Service mode end to end
```bash
$GW --sim-daemon
```

Watch `.status.zip` for each agent's status and its config deltas, then Ctrl-C.

### 4. Teardown
```bash
$GW --recover --dry-run      # what it would do
$GW --recover                # do it
```
Exit 0 = clean or repaired; exit 1 = something needs hands, and it names it.

### Isolated testing
`$HOME` is the only input that matters for every path this binary touches, so an
override gives complete isolation without risking your own config:
```bash
H=$(mktemp -d); mkdir -p "$H/.claude"; HOME="$H" $GW --recover
```

## Recovery

`--recover` reverses this product's edits **surgically** — it removes only the keys we
wrote, so live state in an agent's config (project history, sessions) survives. It kills
stray `zscaler-ai-gateway` processes and frees the listener ports **first**, then repairs
the config files, snapshotting each to `.pre-recover.<ts>` before it rewrites one.

⚠️ **The prior-value snapshots are no longer written.** They came from the deleted
bootstrap, which captured `ANTHROPIC_BASE_URL` to `.llm_upstream` and `MCP_TIMEOUT` to
`.mcp_timeout` before overwriting them. With ai-protect as the writer, that snapshot has
no home yet — `apply_config_delta` merges atomically but takes no backup and records no
prior value. `--recover` still strips our own keys, kills strays and removes the
credential store; it just has nothing to restore *to*. Snapshot-before-merge belongs in
`apply_config_delta`, and is a tracked follow-up rather than a silent gap.

## On-disk state

```
~/.zsai-gateway/                  ($ZSAI_GATEWAY_HOME)
├── .broker.zip                ai-protect writes; service mode watches
├── .status.zip                service mode writes; ai-protect watches
├── .credentials.zip           the credential store (0600): the ZAX user JWT plus one
│                              record per enrolled agent — keypair, instance JWT, HMAC
│                              key, triple JWT, broker list
├── certs/
│   ├── ca-cert.pem            the local CA the per-agent listeners terminate TLS with
│   └── ca-bundle.pem          what every outbound leg trusts, rebuilt at startup
└── logs/zax.log               every continuous mode logs here
```

All three control files are gzipped JSON and dot-prefixed. Compression is **not**
protection: what guards `.credentials.zip` is its owner-only mode.

⚠️ **The agent keypair in `.credentials.zip` is the only copy.** Delete it and that agent
cannot re-activate; it enrols from scratch.

The service **defends** the store: it watches the file it writes, and content it did not
write — a foreign write, a delete, a corrupt file — is restored from memory, bounded at 5
restores per 60 s so a looping writer cannot ping-pong. Warn-level log only; nothing
crosses to ai-protect.

## What the outbound legs trust

Service mode builds one CA bundle at startup — the host's trust store, the ZAX
root, then any `ZAX_CA_BUNDLES` path — and hands it to every leg that dials the
gateway: each agent's listener, the MCP bridge, and the SDK's control-plane
client. It is written to `certs/ca-bundle.pem`, so what the process trusts is a
file you can read:

```bash
openssl crl2pkcs7 -nocrl -certfile ~/.zsai-gateway/certs/ca-bundle.pem \
  | openssl pkcs7 -print_certs -noout | grep -i zscaler
```

The startup log line names the counts (`163 host, 0 operator, plus the ZAX root`).
`--agents` and `--recover` do not build it — the first is read-only and the second
promises `--dry-run` writes nothing.

⚠️ **The ZAX root is embedded in the binary and trusted unconditionally**,
release builds included. It is a self-signed CA and a trust anchor for the gateway
leg on every device that runs this binary: whoever holds its key can present a
certificate this process accepts. Narrowing that means gating `trust::ZAX_ROOT_PEM`
on a tenant or environment signal.

## Gotchas that cost real time

- **A stale cached JWT triggers a browser sign-in.** The user JWT lasts ~24h; when it
  lapses the service re-authenticates, and with no refresh token that means interactive
  OIDC. A blank `tenant.oidc.issuer` in `.broker.zip` means it cannot run that flow at
  all, which the service logs once at startup rather than per agent.
- **Both sides must ship from the same build.** A daemon writing `broker.zip` against a
  gateway watching `.broker.zip` fires no event and logs no error — indistinguishable
  from a daemon that has not written yet. Only bites with a stale binary on a test box.
- **Corporate TLS interception breaks the gateway leg, not the control plane.** Symptom:
  `REGISTER` / `ACTIVATE` succeed but the broker list or a `tools/call` fails to connect.
  Diagnose with `openssl s_client -connect gateway.<cloud>:443 | openssl x509 -noout -issuer`
  — a `CN=Bad Server Certificate` issuer is the inspection layer, and no client-side CA
  bundle fixes it. Exempt the host or stop the interceptor.
- **Loopback is the only gate on a listener port.** Any local account can reach it and
  have its traffic signed with this device's ZAX identity. The per-install path token
  that used to narrow that was dropped — see `listener/DESIGN.md`.
- **Piping this binary's stdout to `head` exits 101** — that's Rust panicking on `EPIPE`,
  not a bug. Redirect to a file instead.
- **`--recover` deletes the credential store by default**, so the next run re-enrols every
  agent unless you pass `--keep-credentials`.

---

*Operating guide. Architecture, the identity pipeline, diagrams and the full open-issues
list live in the **design record** (link in [README.md](README.md)). Re-check both
against the code before relying on any detail.*
