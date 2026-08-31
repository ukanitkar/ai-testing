# ai-broker — porting the credential + config-apply watchers to Windows (DONE)

> Scope: the two daemon-side watchers in `src/subscribers/ai_broker_launch.rs`
> that were `#[cfg(unix)]`-only — the credential-request watcher and the
> config-staging apply watcher (the single-writer mechanism). Written
> 2026-08-19, alongside the Windows privilege-drop / named-pipe-transport /
> graceful-shutdown work landed the same session; updated the same day as
> both watchers and the underlying ownership-transfer primitive landed.
>
> **Status: both watchers are now fully ported.** The credential-request
> watcher's three functions and the config-apply watcher's five functions
> (`ensure_config_apply_watcher`, `config_apply_watcher`, `apply_staged_zip`,
> `apply_staged_zip_inner`, `is_allowed_agent_config`, `owner_ids_for`) are
> all `#[cfg(any(unix, windows))]` now, and the `spawn_broker` call site
> starts all three (handshake, credential watcher, config-apply watcher) on
> both platforms. The hard prerequisite — Windows `fchown`-to-an-arbitrary-user
> — is built and generic in `utils::atomic_write::write_atomic_under` (owner +
> DACL via `SetSecurityInfo` on the temp file's handle, before the rename,
> using the `SeRestorePrivilege` pattern already proven in
> `quarantine/windows.rs`), and is now wired into both
> `hook_installer::util::write_user_json` (Copilot, Grok, Devin CLI,
> Antigravity, Cursor, `desktop_config`) and `ai_broker_launch.rs`'s
> `apply_staged_zip_inner`. See [Config-apply watcher](#config-apply-watcher-the-real-work)
> for what changed and the one platform-behavior asymmetry that's staying by
> design (an unresolvable `os_user` fails closed on Windows, open on Unix).

## TL;DR

- Both watchers are **done**. The credential-request watcher was the cheap
  half. The config-apply watcher's hard part — the Unix `fchown` dance
  ai-protect uses to write another user's file as SYSTEM/root — now has a
  working, wired-in Windows equivalent (`SetSecurityInfo` + `SeRestorePrivilege`).
- **Credential watcher — DONE.** It was blocked on one thing — hardcoding
  `std::os::unix::net::UnixStream` instead of reusing the `ControlStream` /
  `open_control_once` abstraction the file already had — which is now fixed,
  and the three functions are widened to run on both platforms.
- **Config-apply watcher — DONE too.** Of the four original gaps (see
  [Config-apply watcher](#config-apply-watcher-the-real-work)), multi-user
  enumeration was already fine, the O_NOFOLLOW-equivalent reparse-point
  containment was already fine (pre-dating this doc), owner resolution +
  the ownership-transfer are now built generically, and
  `ai_broker_launch.rs`'s own watcher functions are now ported to call it.

## Credential-request watcher — mostly a find-and-replace

Current shape (`ensure_credential_watcher` / `credential_request_watcher` /
`serve_credential_request`, `ai_broker_launch.rs:671-720` and `:930-`):
poll the broker's `credential-request` flag file's mtime every 3s; on change,
call `zax_user_credential::fetch` and push the result over a **freshly opened
connection to the control socket**.

**DONE (2026-08-19), both steps:**
- `serve_credential_request` used to hardcode `std::os::unix::net::UnixStream::connect`
  + a manual `try_clone` + `set_read_timeout` dance. It now calls the shared
  `connect_control` — the same helper `push_register_agent` already uses for
  the `register_agent` push — which is `#[cfg(any(unix, windows))]` and
  already retries while the freshly-spawned broker binds (20×100ms, more
  robust than the old single no-retry attempt this replaced).
- `ensure_credential_watcher` / `credential_request_watcher` /
  `serve_credential_request` are now all `#[cfg(any(unix, windows))]` — the
  call site in `spawn_broker`'s success path was split so
  `ensure_credential_watcher()` runs on both platforms while
  `ensure_config_apply_watcher()` (the still-unbuilt half below) stays
  Unix-only.

Neither step introduced any new Windows API surface — the widened functions'
bodies were already fully generic (`broker_home()`, `std::fs::metadata`,
`connect_control`, `zax_user_credential::fetch`, `bound_user::user_id()` are
all already cross-platform), so no isolated Windows-target check was needed
here the way it was for the FFI-heavy pieces elsewhere this session. Verified:
`cargo check -p ai-warden --lib` clean, `cargo test -p ai-warden --lib` 1893
passed. **Not yet live-verified**: that `broker_home()` resolves correctly
under an actual Windows service context (it should — it's the same path
`broker_control_socket()` already uses for the pipe name — but "should"
isn't "confirmed live").

This watcher is now fully ported, pending that one live check.

## Config-apply watcher — the real work

Current shape (`ensure_config_apply_watcher` / `config_apply_watcher` /
`apply_staged_zip` / `apply_staged_zip_inner`, `:725-845`): poll every real
user's `~/.ai-broker/config-staging/*.zip`, and for each staged file inside —
after a containment check (must resolve under that user's home) and an
allowlist check (`is_allowed_agent_config`, today just `.codex/config.toml`)
— write it via `utils::atomic_write::write_atomic_under(home, rel, content,
0o644, owner, false)`, which does an **O_NOFOLLOW-safe write + `fchown` to
the target user**, so ai-protect (running as root) ends up writing a file
*owned by* the user whose config it is, not by root.

Four pieces were Unix-specific. As of this session, three of the four are
now built into the shared primitive itself — this section is updated from
its original "here's what would need building" framing to "here's what's
already there vs. what the watcher itself still needs":

**1. Multi-user enumeration — already done, no gap.**
`identity::home::all_user_homes()` already has a `#[cfg(target_os =
"windows")]` arm (ProfileList registry + a `C:\Users\*` fallback walk). The
watcher's outer loop needs no change here.

**2 & 3. Owner resolution + `fchown`-equivalent — BUILT (2026-08-19).**
`utils::atomic_write::write_atomic_under` now takes `owner: Option<Owner>`,
where `Owner` is a Unix `(uid, gid)` pair *or a Windows username* (not a
raw SID — resolution happens inside, via `LookupAccountNameW`). On Windows,
`atomic_write::windows::write_atomic` resolves that username to a SID, calls
`enable_ownership_privileges()` (`SeRestorePrivilege` + `SeTakeOwnershipPrivilege`
on the process token — duplicating `services::quarantine::windows::enable_privileges`'s
exact pattern, since `utils::` can't depend on `services::`), then
`SetSecurityInfo` on the **temp file's handle** (never by path) with both
`OWNER_SECURITY_INFORMATION` and `DACL_SECURITY_INFORMATION` set together —
owner alone doesn't grant the new owner *data* access unless the DACL also
permits it. This happens *before* the rename, so it shares the Unix path's
all-or-nothing shape: a failure here leaves `target` untouched and cleans up
the temp file, same as a failed `fchown` never reaching the `renameat`.
Verified: isolated `cargo check --target x86_64-pc-windows-msvc --tests`
(this sandbox has no C toolchain to cross-compile the whole daemon — see the
note in `project_ai_broker_followups.md`), full native suite unchanged
(1893 tests). **Not yet live-verified on a real Windows service** — the
`SeRestorePrivilege`-on-a-LocalSystem-token assumption still deserves the
same live check every other Windows claim in this branch got before being
called done (see `docs/ai-broker-work/ai-broker-windows-privilege-drop-verification.html`).
Wired up for `hook_installer::util::write_user_json` (benefits Copilot, Grok,
Devin CLI, Antigravity, Cursor, `desktop_config`) and for
`ai_broker_launch.rs`'s own `apply_staged_zip_inner` (via a new `owner_ids_for`
Windows arm). Also since fixed: `subscribers/package_proxy.rs` and
`subscribers/permission_apply.rs`'s own `owner_ids` stubs (package_proxy.rs
additionally needed `owner.clone()` at its 5 `sync_file` call sites — `Owner`
is `String`, not `Copy`, on Windows), and `hook_installer/{hermes,openclaw}.rs`'s
`owner_ids` **and** their separate `chown_best_effort` fallback path (for
writes landing outside the user's home) — that fallback now calls a new
shared `atomic_write::set_owner_by_path` (by-path `chown` on Unix; open +
`SetSecurityInfo` on Windows). `hook_installer/amp.rs` turned out to have no
`chown_best_effort` at all (its plugin path is always under home), so it only
needed the `owner_ids` fix. `app_capture/install.rs`'s `owner_of` — the one
genuinely different case, deriving an owner from a directory's *existing*
metadata rather than a resolved username — now has its own Windows
implementation too: read the directory's current owner SID
(`GetNamedSecurityInfoW`) and reverse-resolve it to a username
(`LookupAccountSidW`), so it still fits the `Owner = username` contract
everywhere else. Its `install_python` caller needed the same `.clone()`-in-a-
reused-`Fn`-closure fix as `package_proxy.rs`.

**One deliberate platform asymmetry, not a bug:** `owner_ids_for` (the
config-apply watcher's own resolver) returns `None` on Unix for an
unresolvable `os_user` — write proceeds without a chown, graceful
degradation — but always returns `Some` on Windows, so an unresolvable name
now fails the whole write instead (Windows has no cheap way to check
existence without duplicating `atomic_write::windows`'s private
`LookupAccountNameW` call). In practice `os_user` always comes from a real
enumeration (`identity::home::all_user_homes()`), so this only matters if an
account vanishes between enumeration and the watcher's next tick — rare
enough to accept rather than build an existence check for. Documented on
`owner_ids_for` itself and covered by a Windows-specific test variant
(`apply_tests_windows`) that doesn't rely on the Unix-only graceful-degrade
behavior the original `apply_tests` module's success-path test leans on.

**4. The O_NOFOLLOW-safe write — was already done, before this session.**
This doc originally listed this as still-needed work; that was wrong —
`write_atomic_under`'s Windows arm already rejects a reparse point (junction,
mount point, or symlink) at any intermediate path component
(`windows_reject_reparse_ancestors`, `atomic_write/mod.rs`), and it already has
a real test against an actual `mklink /J` junction
(`windows_write_under_refuses_junctioned_intermediate_component`,
`atomic_write/mod.rs`'s test module). No gap here at all, and hasn't been
since before this doc was written.

## What's actually left

Both watchers compile, and every touched piece stayed within the full
`ai-warden` test suite (1893 passed throughout). What hasn't happened —
matching every other Windows claim landed this session, per
`docs/ai-broker-work/ai-broker-windows-privilege-drop-verification.html`'s own standard —
is a **live run on a real Windows service**. Two things specifically worth
that live check before trusting this port in production:

1. Does a LocalSystem service token actually have `SeRestorePrivilege`
   enabled by default the way `enable_ownership_privileges` assumes?
2. Does the config-apply watcher's poll loop, running under that same
   service, actually find and apply a broker-staged zip end-to-end —
   `all_user_homes()` enumeration → containment/allowlist checks →
   `write_atomic_under` → the file landing owned by the right user, verified
   with a real `icacls`/Explorer-properties check, not just "the code
   compiled and a unit test passed"?

The original "needs a security review before any code" framing this doc
opened with is gone — what's built now reuses privilege-acquisition and
DACL-construction patterns already proven in-tree (`quarantine`,
`ai-broker`'s `secure_file.rs`) rather than inventing new Windows API
surface. The remaining risk is ordinary "did it actually work on a real
box" risk, not "is this cross-user privilege boundary sound" risk.
