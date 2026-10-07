# Copilot desktop on Windows: a SChannel revocation-check gap in the minted leaf cert — found, fixed, confirmed live

2026-10-05/06. Step (2b) of the validation sequence (the disposable VM) for
the real, continuous-service `ForwardProxy` wiring (`ai-protect` commit
`671c70d5` on `main-08272026-github-copilot-app-mr` — `5cd40c8d` was the same
change's hash on the sibling, pre-BYOK-removal `main-08272026-github-
copilot-app` branch and is not reachable from `-mr`; discussed in
`copilot-desktop-routing-approaches-comparison.md`).
**Status: fixed and confirmed end-to-end — see "Resolved, 2026-10-06" at the
bottom.** The rest of this file is the original diagnostic trail, kept as
written because the reasoning in it is what got to the fix.

## What's confirmed working

- `copilot-desktop` auto-enrolls through the real, continuous
  `zscaler-ai-gateway --service` + `zscaler-ai-protect` daemon pair — no dev
  harness. Adopted a stored, signable triple-JWT record and bound a real
  `Https` listener with zero manual steps:
  ```
  agent 'copilot-desktop' adopting stored record (agent_id=b8e3b183-..., signable=true)
  agent{id=copilot-desktop}: [listener] serving https on 127.0.0.1:8795
  agent 'copilot-desktop' listening on https://127.0.0.1:8795
  agent 'copilot-desktop' WIRED — 1 config delta(s)
  ```
- That one config delta is exactly the mechanism designed for this agent's
  "no config file to write to" case: the MCP delta's `env` block carries
  `HTTPS_PROXY: "http://127.0.0.1:8795"`, readable from `.status.zip`.
- `ai-protect`'s own device CA is correctly provisioned and trusted, as
  `LocalSystem`, in the **machine** `Root` store (`certutil -verifystore
  Root`, no `-user`, shows it; `-user` alone does not — expected, matches the
  LocalSystem-trust model).
- The real GitHub Copilot app (`github.exe`), relaunched with
  `$env:HTTPS_PROXY`/`$env:HTTP_PROXY` pointed at the listener, **does**
  establish a TCP connection to it — confirmed directly:
  ```
  Get-NetTCPConnection -OwningProcess <github.exe PID>
  Established  52491  127.0.0.1  8795
  ```

## The symptom

Beyond that TCP-level connect, **nothing**. No `[listener] METHOD path ->
host status` line ever appears in the gateway log for this connection — not
even an error. The app's own UI shows no new error either; it just never
produces a response. This repeated across multiple clean relaunches (process
confirmed killed and empty before each relaunch, `$env:HTTPS_PROXY` confirmed
printed immediately before `Start-Process` each time — ruled out a stale
process or a missed env var).

## Root cause, narrowed by elimination

1. **Not the listener.** `curl.exe -x http://127.0.0.1:8795 -v
   https://api.github.com/` succeeds the CONNECT tunnel cleanly
   (`CONNECT tunnel established, response 200`), then fails *inside the TLS
   handshake*:
   ```
   * schannel: next InitializeSecurityContext failed: CRYPT_E_NO_REVOCATION_CHECK (0x80092012)
   ```
2. **Confirmed to be exactly a revocation-check problem, not a trust
   problem.** The identical curl command with `--ssl-no-revoke` succeeds
   completely — a real `200` from `api.github.com`, relayed through the
   listener. The leaf certificate `listener::kinds::https` mints on the fly
   is otherwise perfectly valid and trusted; it simply carries no CRL/AIA
   revocation info (expected — it's minted locally per-connection, with no
   real-world revocation infrastructure behind it), and Windows's native TLS
   stack (SChannel) — which `curl.exe` uses by default on Windows — hard-fails
   when a revocation check is requested and cannot be completed, rather than
   treating "nothing to check" as a pass.
3. **`github.exe`'s own established-but-silent connection is consistent with
   hitting the same wall**, just without surfacing a visible error the way
   curl's CLI does — plausible if its own Rust networking stack also goes
   through `native-tls`/SChannel on Windows (unlike the already-working
   `ForwardProxy` agents, `copilot` CLI and `devin`, which are both Node-based
   and use their own bundled TLS stack, never touching SChannel at all). This
   is **the leading explanation, not yet proven for `github.exe`
   specifically** — see "Not yet confirmed" below.
4. **Ruled out as the lever:** the WinINet/Internet Settings
   `CertificateRevocation` registry value (`HKCU:\...\Internet Settings`,
   the documented switch for IE/Edge-Legacy/.NET `WebRequest`-style apps).
   Set to `0`, relaunched, sent a fresh prompt — zero change in behavior.
   This doesn't disprove the SChannel theory; it just confirms `github.exe`'s
   client doesn't consult that particular policy surface (consistent with a
   Rust app calling SChannel APIs directly rather than going through
   WinINet).

## Not yet confirmed

Attempted to get definitive per-process attribution via the CAPI2
operational event log (`Microsoft-Windows-CAPI2/Operational`, which logs
certificate chain-building system-wide). The channel was disabled by
default; enabled it, reproduced, and queried — but every event in the
window was owned by `NT AUTHORITY\SYSTEM`, and `/f:text` output doesn't
print the per-event "Details" section that would carry the actual process
name. So we have strong circumstantial evidence (the curl repro, the
established-then-silent TCP connection) but not a byte-for-byte confirmation
that `github.exe` is failing at the identical `CRYPT_E_NO_REVOCATION_CHECK`
point. Getting that would need either the CAPI2 log read via `/f:xml` (to
get the Details/process fields) filtered to the right PID, or a tool like
Process Monitor attached to `github.exe` directly.

## What this means, and what doesn't need chasing further

This is **not** an architecture problem. Discovery, the `ForwardProxy`
wiring, the real continuous-service enrollment, and the generic
`listener::kinds::https` relay path are all confirmed correct — the exact
same listener code already proved a full real inference response on both
macOS and this same Windows laptop (just not yet on this VM, for this
specific native-Windows-client reason).

If `github.exe` really is hitting this wall, the fix belongs in
`listener::kinds::https`'s on-the-fly leaf-certificate minting — giving the
minted cert something that makes Windows's revocation check resolve cleanly
(e.g., a CDP extension pointing at an endpoint that reliably answers, or
whatever property makes SChannel treat it as "nothing to check" rather than
"couldn't check") — not a VM registry tweak. This has likely never surfaced
before now because every other `ForwardProxy` agent shipped so far
(`copilot` CLI, `devin`) is Node-based and never touches SChannel at all;
`copilot-desktop` is the first native Windows client wired through this
transport.

**Next step, if this needs to be pinned down for certain:** re-run the CAPI2
capture with `/f:xml` and filter on `github.exe`'s PID, or use Process
Monitor's own certificate/TLS event capture, to get an unambiguous
per-process confirmation before investing in the cert-minting fix.

## Resolved, 2026-10-06

Implemented the fix this file recommended: `ai-protect` commit `ac6e4663` on
`main-08272026-github-copilot-app-mr` (`055e7aa0` on the sibling, pre-BYOK-
removal `main-08272026-github-copilot-app` branch) adds
`listener::certs::spawn_crl_server` — a tiny, loopback-only, plain-HTTP
server handing out one always-valid (nothing ever revoked) CRL, signed by
the same local CA, via `rcgen`'s `CertificateRevocationListParams`
(first-class support, no custom-extension hackery needed). Every leaf minted
once `LocalCa::with_crl_port` is set gets a real `crl_distribution_points`
entry pointing at it. Wired into the one place that constructs every
`LocalCa` for every real listener (`https::local_ca_credentials`), so the
standalone `copilot-desktop-forward-proxy` harness picks it up for free too.
`cargo test -p ai-gateway-listener`: 174 passed, including two new tests
asserting the CDP is present/absent correctly and that `crl_der()` parses as
a real CA-issued empty CRL, plus a `#[tokio::test]` exercising the hand-rolled
HTTP response framing over a real socket.

**Confirmed live on the VM, in order:**

1. **The exact `curl.exe` repro that found this bug, re-run after deploying
   the fix (v0.3.6), with no `--ssl-no-revoke`** — succeeded cleanly, full
   revocation checking in effect:
   ```
   curl.exe -x http://127.0.0.1:8795 -v https://api.github.com/
   → HTTP/1.1 200, real api.github.com JSON body, no schannel error at all
   ```
   Same command, same listener, same port shape that previously hard-failed
   with `CRYPT_E_NO_REVOCATION_CHECK` — now clean.
2. **The real GitHub Copilot app, relaunched through the proxy, got a real
   answer in its own UI.** This *looked* like a second bug at first — the
   gateway log showed zero matches for `'copilot-desktop'` immediately after,
   which read as "bypassed the proxy entirely." It wasn't: the per-request
   log line (`[listener] METHOD path -> host status`) never contains the
   literal agent-id string in the first place — that's only on the outer
   span wrapper some *other* lines carry, not these. Grepping for the wrong
   string, not a routing bypass. Once that was spotted, the unfiltered log
   showed exactly what should be there:
   ```
   POST /agents/sessions/<id>/events -> api.individual.githubcopilot.com h2 201 in 675ms
   POST /agents/sessions/<id>/events -> api.individual.githubcopilot.com h2 201 in 285ms
   POST /twirp/clientappsfe.observability.v1.TelemetryAPI/SubmitMetrics -> cafe.github.com http/1.1 200 in 86ms
   ```
   Real `201 Created` responses, real headers (`x-oauth-scopes`,
   `x-github-request-id`, the works), real request/response bodies logged.

**Net result:** the Windows leg of `copilot-desktop`'s `ForwardProxy` wiring
is now fully confirmed end-to-end — real app, real relay, real backend,
real response, through the real continuous service, with proper TLS
revocation checking intact rather than silently weakened. Nothing here
needed a registry tweak, a reboot, or giving up TLS interception; the fix is
real product code, not a VM workaround.

**Lesson worth keeping for next time:** when grepping this log for an
agent's own traffic, filter on the *destination host* or the *path* (e.g.
`githubcopilot.com`, `/agents/sessions`), not the agent id — the per-request
`[listener]` lines never carry it. Losing time to this exact trap once is
enough.
