# Handoff: VS Code Copilot network-egress redirect — continue on Windows

Written 2026-10-16, for picking this work up on a Windows machine. Everything
below assumes zero other context — if you're a fresh Claude Code session (or
a human) reading this cold, start here.

## 1. What this feature is, in one paragraph

VS Code Copilot's traffic has no enforceable policy-routing lever (the
`github-enterprise.uri` discovery hijack needs `enterprise: true`, which a
real account doesn't satisfy; `http.proxy` works but is user-editable). This
feature routes it through `ai-gateway`'s listener — and from there through
Optimus for policy enforcement — by **transparently redirecting the
connection at the kernel** (Windows first, via WFP's
`FWPM_LAYER_ALE_CONNECT_REDIRECT_V4/_V6`). Full design:
[`vscode-copilot-network-egress-redirect-design.md`](vscode-copilot-network-egress-redirect-design.md).
Visual overview of every component and call, kernel vs. user mode:
[`vscode-copilot-redirect-components-diagram.pdf`](vscode-copilot-redirect-components-diagram.pdf).

**The one framing to hold onto**: this only succeeds if **both halves** work.
**Half 1 — capture**: the kernel redirect lands the connection on the
listener. **Half 2 — terminate**: the client completes a TLS handshake
against the listener's minted certificate, which means it already trusts the
listener's root CA. Half 1 alone is necessary, not sufficient — a successful
redirect into a rejected handshake just breaks the agent. See the design
doc's §1 for the full argument, and
[`ca-trust-deployment-model.md`](https://github.com/SquareX-AI/ai-protect/blob/main-08272026-vscode-copilot/docs/ca-trust-deployment-model.md)
(in `ai-protect`) for why `vscode-copilot` specifically needs device-wide CA
trust, not the narrow per-agent model every other brokered agent uses.

## 2. Repos and exact state to pull

| Repo | Path (on the Mac this was written on) | Branch | Latest commit |
|---|---|---|---|
| `ai-protect` | `~/work/zax/integration/ai-protect` | `main-08272026-vscode-copilot` | `dd50b66f` |
| `ai-testing` | `~/work/zax/integration/ai-testing` | `main` | this doc's own commit (see below) |

`ai-protect` is the code (driver + daemon + ai-gateway). `ai-testing` is
docs/diagrams for this feature specifically (not the general ai-testing
convention doc home for everything — this feature's design doc, CA-trust
matrix, and this handoff live there because that's where this session put
them; cross-check `ai-protect/docs/` too, since some of this feature's docs
— `ca-trust-deployment-model.md`, `settings-keys.md` — live there instead).

```bash
git clone git@github.com:SquareX-AI/ai-protect.git
cd ai-protect && git checkout main-08272026-vscode-copilot

git clone https://github.com/ukanitkar/ai-testing.git
```

## 3. What's actually done vs. not — don't re-derive this, it's current as of `dd50b66f`

### Code, done and tested (on macOS/Linux; see §4 for what's NEVER been run on Windows)

- `net_egress`'s config/policy layer: `redirect` action, `redirect_agent`
  field, `constrains_scope()` validation, `RuleAction::Unknown` fallback
  (closes the endpoint-first-rollout hazard for *future* actions — does not
  retroactively help `redirect` itself, see `docs/settings-keys.md`).
- `Enforcer::reconcile_redirects` — real, `#[cfg(windows)]`, wired into the
  live reconciliation loop (`net_egress/mod.rs`). Installs nothing on a real
  device today only because no console/policy authors a `redirect` rule yet
  — that's a dashboard/backend gap, outside this repo.
- `AgentStatus.listener` / `gateway_listeners()` — the real `ListenerMapping`
  producer (ai-gateway reports its bound listener via `.status.zip`).
- `ai-gateway/listener/src/redirect_context.rs` — parses the kernel's
  `ZSAI_NETFLT_ORIGINAL_DEST` wire format back out. 5 unit tests, all
  platform-independent (pure byte parsing), all green.

### Code, written but **never run on a Windows machine at all**

- `driver/zsai-netflt/zsai-netflt.c` / `.h` — the whole driver, including
  `ConnectRedirectClassify`'s finding-#9 addition (allocates
  `ZSAI_NETFLT_ORIGINAL_DEST`, stamps `localRedirectContext`). Compiled once
  historically (pre-finding-#9) against WDK 10.0.26100; **never since**.
- `redirect_context.rs`'s `WSAIoctl(SIO_QUERY_WFP_CONNECTION_REDIRECT_CONTEXT)`
  call — the ioctl constant is confirmed correct (read straight from the
  `windows-sys` crate's generated Win32 metadata, not guessed), but the
  actual syscall has never executed once.

### Explicitly NOT done — don't assume these are someone else's problem already solved

- **macOS redirect hook (`NETransparentProxyProvider`)** — zero code. Windows
  was always the lead platform; macOS hasn't started.
- **Device-wide CA-trust install for `vscode-copilot`** — the *decision* is
  made and recorded (`ca-trust-deployment-model.md`); no
  install/enable/disable/verify-removal code exists. `certs.rs`'s module doc
  still accurately describes the narrow-only model that's actually shipped.
- **The Windows equivalent of the macOS keychain CA-trust measurement** for
  `vscode-copilot` — explicitly deferred mid-session ("let's do later"),
  still outstanding. If you're on Windows anyway, this might be the moment.
- **The loop-guard's closing half** — `SIO_SET_WFP_CONNECTION_REDIRECT_RECORDS`
  on whichever outbound socket needs it. Unsettled *which* socket that even
  is, since the listener relays through Optimus rather than dialing the real
  destination itself — resolve this against a real filter, don't guess at it
  from source reading.
- **A console/dashboard path to author a `redirect` rule.** Different repo,
  out of scope here, but worth knowing: even a perfect kernel+listener still
  does nothing for a real tenant without this.

## 4. Ordered checklist for the Windows machine

`driver/zsai-netflt/README.md` already has the validated commands for steps
1–4 below — follow it verbatim rather than re-deriving flags; this list is
the order and the *why*, not a replacement for it.

1. **Build.** WDK/SDK 10.0.26100.2454 + MSVC 14.44.35207 (pinned pairing —
   mismatched SDK/WDK fails silently). `driver\zsai-netflt\build.cmd`.
   Confirm it still compiles clean with finding #9's addition — the
   `C_ASSERT(sizeof(ZSAI_NETFLT_ORIGINAL_DEST) == ZSAI_NETFLT_ORIGINAL_DEST_LEN)`
   is new since the last real build and has never been checked by a real
   compiler.
2. **Test-sign + load**, disposable VM only (`bcdedit /set testsigning on`,
   self-signed cert, `sc.exe create ... type= kernel`). Attach WinDbg before
   first `sc start`.
3. **Two "owed, cheap" confirmations** `CONNECT-REDIRECT-CRASH-SAFETY.md`
   finding #9 flagged and nothing has checked yet:
   - Does `ExAllocatePool2` behave like the field docs' `ExAllocatePoolWithTag`
     for WFP's purposes (both should yield `ExFreePool`-releasable blocks, but
     confirm rather than trust the inference).
   - What pool type `localRedirectContext` actually needs — the Microsoft
     reference is silent; this driver uses `POOL_FLAG_NON_PAGED` on the
     stated reasoning (classify can run at `DISPATCH_LEVEL`), unverified.
4. **The build-sensitivity risk**, same finding: an unverified Microsoft
   Q&A report describes this exact redirect mechanism breaking on Windows 11
   build 22621.1265+ (`AlepValidateConnectRedirectLayerData` added
   code-integrity checks). The prior SNI-only validation ran on Server 2025
   (build 26100) — if redirect silently does nothing while the classify
   function looks correct, this is the first thing to check, and which build
   your test machine is running matters for interpreting the result.
5. **Exercise the redirect end to end** — README's "Exercising the
   CONNECT_REDIRECT half" section, verbatim. Three preconditions, two easy to
   get wrong: a `redirect` rule with all four `constrains_scope()` dimensions,
   a **live** listener mapping (`ZSAI_NETFLT_TEST_LISTENERS` env var — the
   pid:port must really be listening, checked against the real TCP table),
   and an IPv4-resolved destination (AAAA never resolves here). Confirm with
   `netsh wfp show filters` or the `reconciled WFP redirect filters` log line
   before assuming the kernel path is under test at all.
6. **This is the actual new ground, not yet covered by any existing
   checklist**: once a filter is installed and a real client connects,
   confirm **both halves of finding #9** together —
   - the connection actually lands on the listener (Half 1 — TCP-level,
     observable via `netstat` / the listener's own accept log),
   - `redirect_context::query()` on that accepted socket returns `Some(...)`
     with the **correct** original IP:port (add a temporary
     `tracing::info!` if the existing log level doesn't already surface it —
     there is no committed test harness for this because it cannot run
     without a real redirected connection).
   Finding out the ioctl returns `WSAEINVAL` even though redirection worked
   (the exact symptom finding #9 documented for the *pre-fix* driver) would
   mean something in the new allocation/stamping code is still wrong — that
   is the single most informative experiment available on this machine that
   isn't possible anywhere else.
7. **Half 2, if you get that far**: point the test client's trust at the
   listener's CA (`NODE_EXTRA_CA_CERTS`, or — since this is `vscode-copilot`
   specifically — install it device-wide per `ca-trust-deployment-model.md`'s
   decision) and confirm the TLS handshake actually completes, not just that
   the TCP connection landed. A successful redirect into a rejected
   handshake is the specific failure this whole design doc's §1 warns about.
8. **Loop guard** — try to provoke it. Is the listener's own outbound leg
   (to Optimus, or wherever it actually dials) ever itself a connection from
   the SAME `ALE_APP_ID`-matched process to the SAME matched destination? If
   it can never match the filter's own scope in the first place (plausible,
   since the listener is a different process image than `Code.exe`), say so
   explicitly in `CONNECT-REDIRECT-CRASH-SAFETY.md` and close that open
   question instead of leaving it unresolved indefinitely.
9. Work down the rest of `CONNECT-REDIRECT-CRASH-SAFETY.md`'s findings list
   as time allows: **#7** (same-layer filter evaluation order — "harmless in
   any order" is asserted, not verified; this needs exactly the rig you now
   have) and **#5** (IPv6 — likely out of scope, it's a separate feature, not
   a fix to this prototype).
10. **Signing path decision**, if this moves past dev testing: EV
    code-signing cert + Microsoft Partner Center attestation/WHQL, per the
    README's "Production signing" section (org infra, separate from this
    repo — do not put production signing credentials in it).

## 5. Key files, so you don't have to rediscover the map

| File | What's in it |
|---|---|
| `driver/zsai-netflt/zsai-netflt.c` / `.h` | The driver. Two independent features share it: STREAM/SNI enforcement (shipped, validated on Server 2025) and `ALE_CONNECT_REDIRECT` (this feature, prototype). |
| `driver/zsai-netflt/CONNECT-REDIRECT-CRASH-SAFETY.md` | The issue tracker for the redirect prototype specifically — read this before touching the driver, it has the full reasoning behind every design choice and every open item. |
| `driver/zsai-netflt/README.md` | Build/sign/load/exercise/validate — the actual commands. |
| `ai-gateway/listener/src/redirect_context.rs` | The listener's half of finding #9 — recovers the kernel-stamped original destination. |
| `ai-gateway/listener/src/certs.rs` | The local CA + per-host leaf minting (Half 2's mechanics). |
| `ai-gateway/listener/src/server.rs` | Where `redirect_context::query()` is called, and `ConnectionInfo::kernel_redirect_dest`. |
| `ai-gateway/util/src/ca.rs` | Where the CA is actually generated (`gateway_util::ca::generate()`) and shipped to the listener via `.broker.zip`. |
| `src/services/net_egress/config.rs` | `RuleAction`, `EgressRule`, `constrains_scope()`, `evaluate_with_match()`. |
| `src/services/net_egress/enforcer.rs` | `FwpmFilterAdd0` — the actual Windows WFP filter install, both block/allow and redirect. |
| `src/services/net_egress/reconcile.rs` | Turns policy + DNS + live listeners into the concrete filter set. |
| `docs/settings-keys.md` (ai-protect) | The per-key settings reference — `network_egress`'s full rollout-ordering story lives here. |
| `docs/ca-trust-deployment-model.md` (ai-protect) | Why `vscode-copilot` gets the device-wide CA-trust exception, and why it's not generic. |
| `vscode-copilot-network-egress-redirect-design.md` (ai-testing) | The full design doc — two halves, architecture, per-platform plan. |
| `agent-tls-and-ca-trust-matrix.md` (ai-testing) | Measured CA-trust behavior per agent, including the GREASE-fingerprinting method used to isolate `vscode-copilot`'s Electron-vs-Node split. |

## 6. Test machines (confirm before use — this may be stale)

Per earlier session memory, there are several candidate machines; **don't
assume which one without asking**:

- A physical Windows laptop ("machine B" / `mc/b` in earlier shorthand).
- `AIPTester` on AWS (`aiptester-vpc`, Windows Server 2025 Full Base,
  `i-01f94d2e2e38fc55b`) — RDP works with ZCC on, reachable from both the Mac
  and the Windows laptop. This is the machine the prior SNI-half validation
  ran on, so it's the natural match for "Server 2025, build 26100" if build
  sensitivity (§4.4 above) turns out to matter.
- A second AWS VM reachable only via Teleport, provisioned by a different
  team, for unrelated (M365 Copilot) testing — probably **not** the right
  target for this work.

⚠️ If any test on this machine talks to Optimus (the ZAX gateway) rather than
just the local driver/listener, **turn off Zscaler Client Connector (ZCC)
first** — it TLS-intercepts the gateway host and presents a synthetic deny
cert, which looks like a gateway-side failure (502) but isn't.

## 7. Working conventions this session used, for continuity

- Commits were written to a temp file and applied with `git commit -F`
  (avoids backtick-in-double-quote shell issues), ending with
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.
- `ai-testing/scripts/render-doc-pdf.sh --all` regenerates
  `docs/crash_safety.pdf` from `CONNECT-REDIRECT-CRASH-SAFETY.md` whenever
  that file changes — `--check` verifies text match without relying on byte
  equality (the PDF embeds a non-reproducible `/CreationDate`).
- Every finding in `CONNECT-REDIRECT-CRASH-SAFETY.md` that's been acted on
  carries a `✅ FIXED <date>` / `⚠️ PARTIALLY FIXED` / `⚙️ ... IMPLEMENTED,
  UNTESTED` marker in its own heading — trust those markers, they're kept
  current as of `dd50b66f`.
