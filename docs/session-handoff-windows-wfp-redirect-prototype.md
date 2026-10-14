# Session handoff: Windows WFP connect-redirect prototype

Written 2026-10-14 on the Mac (`mc/a`) to continue this specific task on the
Windows side. Read this top-to-bottom before doing anything — it's the
self-contained context for one task, not a transcript.

**The task:** prototype a `FWPM_LAYER_ALE_CONNECT_REDIRECT_V4` WFP callout that
redirects VS Code Copilot's outbound CAPI connections to a local listener —
the Windows half of the network-egress redirect hook for VS Code Copilot. Full
design: **[vscode-copilot-network-egress-redirect-design.md](vscode-copilot-network-egress-redirect-design.md)
§3** (read that section before writing any code — it has the exact API
sequence, verified against Microsoft's docs, and is not repeated here).

## Why this task exists (one paragraph)

VS Code's built-in Copilot Chat has no account-tier-independent, *enforced*
way to route its model traffic through our gateway. The one app-level
mechanism that works (`github-enterprise.uri`) needs `enterprise: true`, which
a real tested account (Copilot Business seat + Zscaler Enterprise membership,
ordinary github.com) does **not** satisfy — see
[vscode-copilot-enterprise-gate-account-test.md](vscode-copilot-enterprise-gate-account-test.md)
for that whole investigation. A separate non-enforced lever (VS Code's
`http.proxy`) was confirmed working for real CAPI traffic this session (same
doc, §5 item 5) — useful as an interim, MDM-pushable option, but it's
user-editable, not a guarantee. The enforced answer is a kernel/OS-level
redirect: `FWPM_LAYER_ALE_CONNECT_REDIRECT_V4` on Windows,
`NETransparentProxyProvider` on macOS. Windows was chosen to go first because
it reuses the most existing infrastructure (see below).

## What already exists to build on

- **`driver/zsai-netflt/`** — a parked, unsigned WFP callout driver (SNI-based
  *blocking*, not redirect) that already proves the toolchain and most of the
  plumbing:
  - Registers callouts with `FwpsCalloutRegister1` (the redirect layer also
    requires `*Register1`+, not `*Register0`).
  - Has a working device + IOCTL protocol to user mode
    (`zsai-netflt.h` / `callout.rs`), versioned (`ZSAI_NETFLT_PROTO_VERSION`).
  - Adds provider/sublayer/filters in one rollback transaction
    (`RegisterCallouts` in `zsai-netflt.c`).
  - **Was built and validated live** on Windows Server 2025 (build 26100) —
    this proves the dev rig/toolchain works end to end, it's not theoretical.
- **`src/services/net_egress/enforcer.rs`** — user-mode filter construction
  already builds `FWPM_CONDITION_ALE_APP_ID` (via
  `FwpmGetAppIdFromFileName0`) + remote IP + port conditions. Reuse this
  rather than reimplementing app/destination matching.
- **`src/services/net_egress/reconcile.rs`** — `compute_filters` already turns
  `domains` rules into resolved destination filters from live DNS
  observations. Reuse this for the CAPI hostname list (§1.2 of the design
  doc: `api.githubcopilot.com`, `api.business.githubcopilot.com`,
  `api.github.com`, `api.mcp.github.com`, etc.).
- **The new piece is narrow**: a *new callout* on
  `FWPM_LAYER_ALE_CONNECT_REDIRECT_V4` (+`_V6`) in the *existing* driver —
  not a new driver, not new app/destination-matching logic. The exact
  classify-function sequence (`FwpsRedirectHandleCreate0`,
  `FwpsQueryConnectionRedirectState0` loop guard,
  `FwpsAcquireWritableLayerDataPointer0` + `FWPS_CONNECT_REQUEST0`,
  `SIO_QUERY/SET_WFP_CONNECTION_REDIRECT_RECORDS` on the listener side) is in
  the design doc §3.2, verified against Microsoft's own WFP documentation —
  don't re-derive it from memory, follow that doc.

## Step 0 — confirm the environment before writing any code

The open item from the design doc that gates everything else: **is the WDK
actually present on the box you're using?** Don't assume — the parked driver
was built once, in a prior session, on a box that may or may not be the one
you have now.

```powershell
# Does the WDK kernel include tree exist?
dir "$env:ProgramFiles(x86)\Windows Kits\10\Include" -ea SilentlyContinue
dir "$env:ProgramFiles\Windows Kits\10\Include" -ea SilentlyContinue

# Is VS Build Tools + the C++ workload present?
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
  -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  -property installationPath
```

If either comes back empty, install with the exact commands already recorded
in `driver/zsai-netflt/README.md` under "Build prerequisites" — they're the
verified, non-interactive installer invocations for SDK/WDK
**10.0.26100.2454** + MSVC **14.44.35207** (the confirmed-working pairing).
Don't guess a different version; a mismatched SDK/WDK pair "can fail silently
when kernel headers are resolved" (same README).

**Sanity-check the toolchain before touching the redirect code**: build the
driver as-is, unmodified:

```bat
driver\zsai-netflt\build.cmd
```

This should produce `driver\zsai-netflt\build\zsai-netflt.sys` with no
changes. If this doesn't work, nothing past it will either — fix this first.

## Step 1 — which box

Per the project's machine topology (ask the user if this has changed since
2026-10-13 — these notes rot fast):
- **B (`mc/b`)** — the Windows laptop, local.
- **C (`mc/c`)** — `AIPTester` AWS VM, reached via RDP (public IP, SG
  `aiptester-rdp` has 3389 open), built specifically as a disposable rig for
  this kind of test. This is more likely to be the right box for installing a
  **test-signed, loaded kernel driver** — do this on a disposable VM, not a
  primary laptop, since `bcdedit /set testsigning on` and loading a new kernel
  service are exactly the kind of change you want to be able to throw away.
- Do **not** assume ZCC's state here — a prior session note says RDP itself
  works with ZCC on, but gateway/LLM traffic tests need it off. This task is
  about a kernel driver, not gateway traffic, so ZCC's state is probably
  irrelevant to it specifically — but don't carry that assumption into a later
  task without rechecking.

If you don't have current connection details for C, ask — they were recorded
in a prior session's memory, not in this repo, and may have changed or been
torn down since.

## Step 2 — the actual new work

1. Re-read [vscode-copilot-network-egress-redirect-design.md](vscode-copilot-network-egress-redirect-design.md)
   §3.1–3.3 in full.
2. Add the new callout registration (layer `FWPM_LAYER_ALE_CONNECT_REDIRECT_V4`
   / `_V6`) alongside the existing ones in `RegisterCallouts` —
   **redirect-only** classify function, no TLS/HTTP logic in kernel mode (that
   stays in the userspace listener, per the design doc's explicit "simpler
   scope than macOS" point).
3. Reuse `enforcer.rs`'s `ALE_APP_ID` resolution for the VS Code image path
   (confirm the actual path on the Windows box first —
   `%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe` is the per-user
   install default, **[inferred, not yet confirmed on real Windows]** per the
   design doc §1.1).
4. Reuse `reconcile.rs` for the destination hostname list.
5. Point the redirect at a throwaway local listener first (even a bare
   `127.0.0.1:<port>` echo server) to prove the redirect mechanism alone,
   *before* wiring it to the real `ai-gateway` listener — isolate "does the
   kernel-level redirect work at all" from "does the gateway handle a
   redirected flow correctly."
6. Only then integrate with `ai-gateway/listener/src/kinds/https.rs` (§5 of
   the design doc covers what it needs: reading/stamping WFP redirect records,
   excluding its own outbound socket from re-redirection).

## Things this doc deliberately does NOT repeat

- The exact Microsoft API call sequence for the redirect classify function —
  it's in the design doc §3.2, already verified against Microsoft Learn and
  OSR forum posts. Don't re-derive it.
- The full VS Code Copilot architecture (which processes, which hostnames,
  why) — design doc §1.
- The broader licensing/account-tier investigation — the account-test doc.
- The macOS side — separate task, separate (harder, different) environment
  blocker; not this task.

## Open questions to resolve when picking this up

- [ ] Is the WDK actually installed on whichever box you use? (Step 0.)
- [ ] Which box — B or C? Confirm current reachability/credentials; they may
      have changed since 2026-10-13.
- [ ] Confirm the real VS Code + Copilot process image paths on Windows
      (design doc §1.1 marks this `[inferred]`).
- [ ] EV/attestation signing path for anything beyond local test-signing is
      still fully open — out of scope for *this* prototyping task, but don't
      let a working test-signed prototype get mistaken for a shippable one.
