# AI Broker — ai-protect launched as the logged-in user (no privilege drop): test plan

**Status:** plan. Unlike the root-daemon plan, this needs **no broker code
change** — `spawn_broker()` already inherits the parent's user.
**Scope:** the `--control` broker and its `--llm-proxy` child.
**Where:** research VM (or any dev box) — safe, because **nothing runs as root**.
Still use `--no-install-hooks` for a clean, config-preserving test.

> Companion to [`ai-broker-privilege-drop-test-plan.md`](ai-broker-privilege-drop-test-plan.md)
> (root daemon → drop the broker to the user). This is the **inverse**: run
> ai-protect **as** the user, so the broker is the user by inheritance.

---

## 0. Goal & model

**Goal:** ai-protect runs as the **logged-in (non-root) user**. When it spawns
`ai-broker-mon --control`, the broker — and the `--llm-proxy` child — are that
same user **by inheritance**, with the socket and every written file naturally
user-owned. No `uid()/gid()` drop, no supplementary-group juggling, no root.

**Why it's attractive:** it sidesteps the entire risk surface of the root model
(symlink/TOCTOU writes as root, root RCE via the loopback proxy, an unguarded
root control socket). The broker's job — write my dotfiles, hold my token, run my
loopback proxy — needs only *my* privileges, and here it has exactly that.

**The trade-off:** ai-protect is designed as a **root/LocalSystem** daemon.
Running it non-root means it **loses its root-only capabilities** (Part A3). So
this model fits **single-user / dev / reduced-scope** use — or a deliberate
"user-space ai-protect + broker" product decision — not a full privileged fleet
daemon.

### Root daemon (plan 1) vs user daemon (this plan)

| | Plan 1 — root daemon + drop | Plan 2 — user daemon (this) |
|---|---|---|
| Broker code change | **Yes** — build the privilege drop | **None** — inherits the user |
| ai-protect capabilities | Full (root) | Reduced (non-root, Part A3) |
| Broker risk surface | Root until drop works; drop must be correct | **None** — never root |
| Deployment | One system daemon (LaunchDaemon/systemd system) | Per-user agent (LaunchAgent/user systemd) |
| Multi-user | One daemon serves all; broker per bound user | One daemon **per** logged-in user |
| Best for | Production fleet w/ privileged enforcement | Single-user / dev / user-space model |

---

## Part A — What this model requires (not a privilege drop)

### A1. Launch ai-protect as the logged-in user

Start the daemon **without `sudo`**, in the user's own session:
- macOS: a **LaunchAgent** (`~/Library/LaunchAgents`, `Aqua` session) — not a
  LaunchDaemon.
- Linux: a **user** systemd unit (`systemctl --user`) — not a system unit.
- Ad-hoc test: just run the binary as the user in a login shell.

Because it runs as the user, `SUDO_USER` is unset and `HOME` is the user's — so
`current_user_home()` resolves to the **user's** home with no ambiguity (contrast
plan 1, where a root `$HOME` could hijack the path).

### A2. No spawn change — inheritance does it

`spawn_broker()` calls `Command::new(bin).arg("--control")…spawn()` with **no**
`uid()/gid()`. When the parent is the user, the child is the user. The
`TODO(ai-broker)` privilege-drop at
[`src/subscribers/ai_broker_launch.rs`](../src/subscribers/ai_broker_launch.rs)
is **moot** in this model — the current code is already correct here. The
`--llm-proxy` child the broker spawns likewise inherits the user.

### A3. Capability trade-off — what ai-protect gives up running non-root

Verify each degrades gracefully (per `AGENTS.md`, most are best-effort/no-op when
unprivileged) rather than aborting startup:
- **Hooks into *other* users' configs** — only the launching user's.
- **System-managed settings / `Scope::Managed`** paths — can't write system dirs.
- **Scan-governor hard cap** (Linux cgroup v2 / Windows Job Object) — needs
  privilege → best-effort/no-op (macOS is already a no-op).
- **`network_egress` WFP enforce** (Windows admin) — default off anyway.
- **macOS Endpoint Security extension** (`endpoint-ext`) — needs root/approval.
- **WSL provisioning** (Windows admin).
- **`all_user_homes()` scan of *other* users** — permission denied outside own home.
- **Device storage in a system location** — use `--storage sqlite` (user-local).

None of these are needed to exercise the **broker** path, so a reduced-scope
daemon is sufficient for this test — but the plan must confirm they **degrade,
not crash**.

### A4. Socket & files — naturally user-owned

`broker_home()` → `current_user_home()` → the user's `~/.ai-broker`. The broker
(the user) binds `control.sock` there and owns it; the daemon (also the user)
connects. Everything the broker writes (staging ZIPs, sidecar tokens) is
user-owned with no fchown gymnastics. The daemon-side config-apply watcher's
`write_atomic_under(..., owner, ...)` still works — `owner` just resolves to the
same user.

---

## Part B — Test environment

1. Dev box / VM with `zscaler-ai-protect` + `ai-broker-mon` built side by side.
2. Logged in as a **normal (non-root) user**; note `id -u`.
3. Codex present in `~/.codex/` (or a scratch `CODEX_HOME`).
4. **ZCC off** before any LLM-leg step.

---

## Part C — Test procedure

> **If a real ai-protect is already running on the host (e.g. ZCC-managed), do
> NOT start a second full daemon** — it can collide on the IPC socket, hooks, and
> enrollment. Use the **`--sim-daemon` harness** (C-alt) instead: it plays only
> the control-driver slice of ai-protect and touches none of its machinery.

### C-alt (recommended) — the `--sim-daemon` harness

`ai-broker-mon --sim-daemon` spawns the broker as **this user**, drives
`start_up` + `register_agent(codex)`, and idles so the `--llm-proxy` stays up —
without any ai-protect daemon at all. Credentials/attribution come from env (all
optional; absent ⇒ the broker falls back to refresh-token/OIDC, as in the real
flow):

```bash
export ZAX_DEMO_HOME="$HOME/.ai-broker"      # broker home + default socket dir
export CODEX_HOME="$HOME/.codex-zax-test"    # scratch — don't touch a real ~/.codex
# optional: export ZAX_USER_JWT=… ZAX_REFRESH_TOKEN=… ZAX_BOUND_USER=… ZAX_TENANT=…
ai-broker-mon --sim-daemon                   # add --socket <path> to override
# → prints the LLM proxy URL; Ctrl-C stops and reaps the broker
```

Then jump to step 4 in the table below (steps 1–3 concern a full daemon and don't
apply). The harness log lines (`[sim-daemon] → start_up`, `← register_agent …`)
are your interface trace.

### C-full — the real daemon as the user (only if NO other ai-protect is running)

```bash
./zscaler-ai-protect daemon \
  --allow-unenrolled --no-install-hooks --no-install-exts \
  --storage sqlite \
  --server-url <dev-backend>          # ai_broker.enabled=true in settings
```

| # | Step | Verify |
|---|------|--------|
| 1 | Daemon is up | `ps -o uid= -p <daemon_pid>` → **your uid**, not 0 |
| 2 | Daemon didn't abort on a privileged op | log shows privileged subsystems **degraded**, not fatal (A3) |
| 3 | Daemon spawns the broker | log `[ai-broker] launched ai-broker-mon (pid N)`; capture N |
| 4 | **Broker runs as the user** | `ps -o user=,uid= -p N` → your user (trivially — inheritance) |
| 5 | **Proxy child is the user** | `pgrep -P N` → `--llm-proxy`; `ps -o user=` → your user |
| 6 | Socket in your home, your-owned | `ls -ln ~/.ai-broker/control.sock` → your uid:gid |
| 7 | Handshake works (same-user) | broker log `start_up … StartedUp ready=true` |
| 8 | Broker-written files your-owned | `ls -ln ~/.ai-broker/config-staging/*`, sidecar → your uid |
| 9 | Codex register/stage/apply | accepted; staged ZIP present; `~/.codex/config.toml` gets the `zax` entries |
| 10 | **LLM leg e2e** (ZCC off) | proxy up; Codex/OpenAI call via `127.0.0.1:<port>/v1` → **200** |

---

## Part D — Success criteria

- `uid(daemon) == uid(broker) == uid(proxy) == your uid`, none are 0.
- Socket + all broker-written files are your-owned (no root anywhere).
- Daemon starts and runs with privileged subsystems **degraded, not crashed**.
- start_up handshake + credential push succeed (same-user, trivially).
- Codex LLM call returns 200 (ZCC off).
- Teardown clean.

---

## Part E — Negative / edge tests

1. **Reap on exit:** kill the daemon → broker + proxy terminated and reaped; no
   orphans (`pgrep -f ai-broker-mon`).
2. **Renewal stays same-user:** trigger `renew_proxy` → restarted proxy is still
   your user (trivially true, but confirm no regression).
3. **Second user:** log in as a different user and run their own daemon → a
   **separate** broker + socket under *that* user's `~/.ai-broker`; the two don't
   collide (this model is one daemon **per** user by design).
4. **Privileged op requested:** flip on a root-only feature (e.g. hard cap) →
   confirm it logs "unavailable/skipped" rather than failing the daemon.

---

## Part F — Gotchas & risks

- **Reduced ai-protect scope is the whole trade.** This is not a drop-in for the
  privileged fleet daemon — it can't enforce system-wide policy, install hooks for
  other users, or run the ES extension. Decide per use: dev/single-user → fine;
  fleet enforcement → use plan 1.
- **Per-user topology.** Multi-user hosts get **one ai-protect per logged-in
  user**, each with its own broker — the opposite of plan 1's single system
  daemon. Enrollment/identity then needs a per-user (or shared) story.
- **Enrollment & storage.** Non-root can't use the system storage location; use
  `--storage sqlite` (user-local) or a per-user enrolled identity. `--allow-unenrolled`
  for a pure broker smoke test.
- **Autostart.** A LaunchAgent / user systemd unit only runs while that user is
  logged in — matching "broker for the logged-in user" exactly, but it means no
  coverage when nobody is logged in (acceptable for this model).
- **ZCC** off for step 10. Nothing here runs as root, so no root-risk caveats —
  that's the point.

---

## Part G — Teardown / rollback

- Stop the daemon (`pkill -f 'zscaler-ai-protect daemon'`, or unload the
  LaunchAgent / `systemctl --user stop`); confirm E-1.
- Remove `~/.ai-broker/` and the scratch `CODEX_HOME` if used.
- With `--no-install-hooks`, no persistent hook config was written; the broker's
  `zax` entries in `~/.codex/config.toml` are removed by `recover`.

---

## Appendix — Which plan to run

- **Plan 2 (this)** first for a fast, safe broker smoke test — no code, no root,
  minimal risk. It proves the broker/proxy/socket/credential/LLM path end to end
  as the user.
- **Plan 1** when you need ai-protect to keep its **root** capabilities
  (system-wide enforcement, cross-user hooks, ES extension) *and* the broker to
  run as the user — which is the production shape, and which requires building and
  validating the privilege drop.
