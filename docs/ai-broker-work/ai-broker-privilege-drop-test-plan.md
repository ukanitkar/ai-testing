# AI Broker — root daemon → broker as the logged-in user: implementation + test plan

**Status:** plan (privilege drop not yet built — this covers building it *and*
testing it).
**Scope:** the `--control` broker and the `--llm-proxy` child it spawns.
**Where:** research VM only. **Never** run the daemon on your own machine — it
runs as root and touches user configs. Use `--no-install-hooks` during the test.

---

## 0. Goal & current state

**Goal:** ai-protect runs as **root**; the `ai-broker-mon --control` process it
spawns (and that process's `--llm-proxy` child) runs as the **logged-in
(non-root) user**, with the control socket and every file the broker writes owned
by that user.

**Current state (the gap):** `spawn_broker()` spawns with **no** `uid()/gid()`
([`src/subscribers/ai_broker_launch.rs`](../src/subscribers/ai_broker_launch.rs)
— `TODO(ai-broker)` at the spawn site). So today root → **root broker**. The
building blocks to fix it already exist in `src/identity/home.rs`
(`console_user_home`, `home_for`, `nix::unistd::User::from_name/from_uid`).

So this is a two-part effort: **Part A** builds the privilege drop; **Part B–G**
test it.

---

## Part A — Implementation prerequisite (the privilege drop)

### A1. Resolve the target user *explicitly* (do not rely on `current_user_home()`)

`broker_home()` currently derives the socket path from
`utils::discovery::user_home()` → `identity::home::current_user_home()`. Its
resolution order is **SUDO_USER → `$HOME` → console(/dev/console) → getpwuid(euid)**.
That is fine under `sudo` (SUDO_USER wins → the logged-in user), but under
**launchd/systemd** a root `HOME` (`/var/root`, `/root`) wins at step 2 and the
socket would land in **root's** home — which a broker running *as the user*
cannot bind. So the privilege-drop path must resolve the **target user once,
explicitly**, and use that single answer for both the spawn identity and the
socket path.

Add a helper (e.g. `identity::home::broker_target_user()`) returning
`{ name, uid, gid, home }` for the **active/console user**:
- macOS: owner uid of `/dev/console` (reuse `console_user_home`'s uid probe) →
  `User::from_uid` → name/gid/dir.
- Linux: the seat/console user (e.g. `logind` active session, or the owner of the
  active VT / `who`), falling back to `SUDO_USER`.
- Return `None` if the only candidate is root (uid 0) → see A4.

### A2. Drop privileges in `spawn_broker()`

On unix, before `.spawn()`:
```rust
use std::os::unix::process::CommandExt;
let u = broker_target_user()?;            // A1; None => fail-closed (A4)
cmd.uid(u.uid).gid(u.gid);
cmd.env("HOME", &u.home).env("USER", &u.name).env("LOGNAME", &u.name);
// SAFETY: pre_exec runs in the child before exec; set the FULL group set —
// .gid() alone leaves root's supplementary groups attached (privilege leak).
unsafe {
    cmd.pre_exec(move || {
        nix::unistd::initgroups(&CString::new(name)?, Gid::from_raw(gid))?;
        Ok(())
    });
}
```
Key points:
- `.uid()/.gid()` sets the primary ids; **`initgroups`/`setgroups`** is required
  or the child keeps **root's** supplementary groups.
- Set `HOME`/`USER`/`LOGNAME` so the broker's own `current_user_home()` and the
  SDK resolve to the target user (and match A3).

### A3. Consistent socket path on both sides

The daemon (root) connects to `broker_control_socket()`; the broker (user) binds
it. Both must compute the **same** path in the **target user's** home. Point
`broker_home()` at `broker_target_user().home` (A1), not the ambient
`current_user_home()`. The broker, now running as the user with `HOME` set,
resolves the identical path and can create/own `~/.ai-broker/` and the socket.

### A4. Fail-closed policy

If `broker_target_user()` returns `None` (headless host, no console user, only
root logged in), **do not spawn the broker as root** — log and skip. Running the
broker as root is the exact risk we're removing; a silent root fallback defeats
the purpose. (Make this an explicit, logged decision.)

---

## Part B — Test environment (research VM)

1. VM with `zscaler-ai-protect` (daemon) and `ai-broker-mon` **built from the
   branch with Part A**, shipped side by side (the daemon spawns the broker from
   its own dir).
2. A **non-root user logged in at the console** (GUI session on macOS so it owns
   `/dev/console`; an active seat/VT on Linux). Note its uid: `id -u <user>`.
3. Codex present in that user's home (`~/.codex/`) so `register_agent` has a
   target (scratch `CODEX_HOME` if you don't want to touch a real one).
4. **ZCC off** before any LLM-leg step (else TLS intercept → 502 masks results).

---

## Part C — Test procedure

Run the daemon as root, driving the broker via the control interface:

```bash
sudo ./zscaler-ai-protect daemon \
  --allow-unenrolled --no-install-hooks \
  --server-url <dev-backend>          # ai_broker.enabled=true in settings
```

| # | Step | Verify |
|---|------|--------|
| 1 | Daemon is up | `ps -o uid= -p <daemon_pid>` → **0** (root) |
| 2 | Daemon spawns the broker | log line `[ai-broker] launched ai-broker-mon (pid N)`; capture N |
| 3 | **Broker runs as the user** | `ps -o user=,uid=,pid= -p N` → the logged-in user, **not** root |
| 4 | **Supplementary groups dropped** | Linux: `grep Groups /proc/N/status` shows the user's groups, **no** root/gid 0. macOS: compare `ps -o pid,uid` + `id <user>` |
| 5 | **Proxy child inherits the user** | find the `--llm-proxy` child (`pgrep -P N` / `ps --ppid N`); `ps -o user=` → the user |
| 6 | **Socket owned by the user, in their home** | `ls -ln ~<user>/.ai-broker/control.sock` → `user:group`, not `root` |
| 7 | Handshake crosses the boundary | broker log: `start_up … StartedUp ready=true`; the **root daemon connected to the user-owned socket** |
| 8 | **Broker-written files are user-owned** | `ls -ln ~<user>/.ai-broker/config-staging/*` and any sidecar token file → user-owned, not root |
| 9 | Codex register/stage works as the user | `register_agent` accepted; staged ZIP present + user-owned; apply lands `~<user>/.codex/config.toml` user-owned |
| 10 | **LLM leg e2e** (ZCC off) | proxy up; a Codex/OpenAI call through `127.0.0.1:<port>/v1` returns **200** |

---

## Part D — Success criteria

- `uid(broker) == uid(logged-in user)` and `!= 0`; **same** for the `--llm-proxy` child.
- Supplementary group set == the user's (no residual gid 0).
- `control.sock` + **every** file the broker writes are owned by the user.
- start_up handshake + credential push succeed across the root↔user boundary.
- Codex LLM call returns 200 (ZCC off).
- Teardown is clean; fail-closed when no console user (Part E-3).

---

## Part E — Negative / edge tests

1. **Reap on daemon exit:** kill the daemon → broker child is terminated
   (`stop_broker`) and reaped; socket cleaned; no orphan broker left running as
   the user. Verify with `pgrep -f ai-broker-mon`.
2. **Renewal keeps the boundary:** trigger `renew_proxy` (credential mid-life) →
   the *restarted* proxy is **still** the user, not root (regression guard — the
   respawn must re-apply A2).
3. **Fail-closed:** run with **no** console user (headless / only root) → the
   daemon **does not** spawn the broker as root; logs the skip (A4).
4. **Multi-user:** with two users logged in, confirm the target resolves to the
   **active/console** user deterministically (and document the single-instance
   limitation — one broker today, per-user is open-decision #4).

---

## Part F — Gotchas & risks

- **Launch method changes the resolved user.** `sudo` → SUDO_USER (correct);
  launchd/systemd → console/getpwuid, and a root `$HOME` can hijack the ambient
  path. A1 (explicit target user) + A3 (both sides use it) is what removes this
  fragility — test under the **same** launch method production uses, not only sudo.
- **Supplementary groups are silent.** `.gid()` alone looks right in `ps` but
  leaves root's groups — always check step 4, it's the easiest leak to miss.
- **macOS session context.** A launchd (root) process spawning a GUI-user process
  puts the child outside the user's Aqua/bootstrap session — fine for a
  socket+proxy broker (no GUI/login-keychain needed); flag it if any keychain
  access is ever added.
- **Credential handoff is over the socket, not env.** The daemon pushes
  `user_jwt`/refresh in `StartUpParams` over the control socket — so it crosses
  the privilege boundary cleanly (no secrets in the child's argv/env). Good; keep
  it that way.
- **ZCC** must be off for step 10. **Don't run the daemon on your own machine.**

---

## Part G — Teardown / rollback

- Stop the daemon (`sudo pkill -f 'zscaler-ai-protect daemon'`); confirm E-1.
- Remove test artifacts: `~<user>/.ai-broker/` (socket, staging), and the scratch
  `CODEX_HOME` if used.
- No persistent config was written with `--no-install-hooks`; confirm
  `~<user>/.codex/config.toml` only carries the broker's `zax` entries (recover
  removes them).
