# Design: network-egress redirect for VS Code Copilot — Windows first, macOS second

2026-10-13. Scope: **VS Code Copilot only** (the built-in `copilot-chat`
extension and the `@github/copilot` agent host VS Code spawns). Goal: route
their model/CAPI traffic to the local `ai-gateway` listener — and from there
through Optimus for policy enforcement — **enforced, not dependent on the
user leaving an editable setting in place**, so it holds for every account
tier in `vscode-copilot-enterprise-gate-account-test.md`'s matrix. (A
non-enforced app-level lever — VS Code's `http.proxy` — was confirmed working
for rows 1–3/5–7 this session, §8; it is a real interim option, not a
substitute for this hook.)

This is an endpoint DLP / policy-enforcement capability for Zscaler AI Protect,
operating on the organization's own managed devices. It supersedes the VS Code
parts of `option-4-process-aware-redirect-design.md` and the two
`copilot-desktop-*-design.md` docs, and corrects one shared API assumption
(§4). **[verified]** = read from installed binaries, this repo, or
Apple/Microsoft docs on 2026-10-13; **[inferred]** = not yet confirmed.

## 0. Why a redirect hook

- The one app-level mechanism that works (`github-enterprise.uri` CAPI-discovery
  hijack, `vscode_copilot.rs`) is gated on `enterprise: true`, which a real
  Copilot-Business + Enterprise-member account does **not** satisfy.
- Existing `network_egress` is **allow/drop only** on both platforms
  (`docs/network-egress.md`); redirect is a new action, not a new rule.
- A non-enforced lever, VS Code's `http.proxy`, is **confirmed working**
  (§8) — real CAPI/chat traffic routes through it. User-editable, so not an
  enforcement story on its own — it shapes what the hook must *add*:
  enforcement, not reachability.

## 1. The two halves required for success

This feature only succeeds if **both** of the following hold. Either one
alone is not a partial win — a redirect without trust just breaks the agent,
which from outside looks identical to a kernel-side bug.

- **Half 1 — capture the traffic.** Get the connection to land on
  `ai-gateway`'s listener instead of its real destination. This is the
  kernel-level piece: the WFP connect-redirect on Windows (§4), the
  `NETransparentProxyProvider` hook on macOS (§5). **Necessary, not
  sufficient.**
- **Half 2 — terminate at the listener using a root certificate.** Once the
  connection lands there, the client has to actually complete the TLS
  handshake against the listener's certificate, which chains to a CA the
  client trusts. If it doesn't, the handshake is rejected and the agent sees
  a connection failure, not a policed request.

Half 1 is what this document's Windows/macOS sections build. Half 2 is a
**separate, already-surfaced problem for this specific agent**: measured live
2026-10-15, `vscode-copilot`'s Electron `net` stack — which carries its real
CAPI/chat traffic — only honors the system/login keychain, not this product's
existing per-agent `NODE_EXTRA_CA_CERTS` trust channel (which every other
brokered agent uses today). So Half 2 for `vscode-copilot` means installing
the gateway's root CA **device-wide**, not the narrow per-agent trust this
product otherwise relies on — a deliberate, measurement-justified exception,
not a precedent for other agents. See:

- `ai-protect/docs/ca-trust-deployment-model.md` — the decision record: why
  device-wide trust is a per-agent exception rather than a generic fix, and
  what any future agent needs before being added to that list.
- `agent-tls-and-ca-trust-matrix.md` — the measurement itself (keychain vs.
  `NODE_EXTRA_CA_CERTS`, split by TLS stack via GREASE fingerprinting).
- `driver/zsai-netflt/CONNECT-REDIRECT-CRASH-SAFETY.md` — carries this as a
  precondition on the kernel validation checklist, since no amount of
  redirect-path correctness (Half 1) substitutes for it.

## 2. What VS Code Copilot's traffic looks like

### 2.1 Processes [verified on macOS; Windows analog inferred]

Two independent HTTP stacks, two processes:
- **`copilot-chat` extension (built-in, v0.59.0)** runs in the extension-host
  process (`Code Helper (Plugin)` on macOS; `Code.exe --type=utility` on
  Windows).
- **`@github/copilot` agent host (CLI v1.0.73)** runs as a child NodeService
  process executing `@github/copilot-<platform>/index.js --headless --stdio`.

On macOS every helper shares signing identifier `com.microsoft.VSCode.helper`
(Team `UBF8T346G9`); on Windows every helper is the same image `Code.exe`
(per-user `%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe`). So a process
match necessarily covers all helpers — **destination rules do the narrowing**.
**[inferred — confirm the Windows image path + `--type` helpers on the test box
with Process Explorer before writing filters.]**

### 2.2 Destination hosts [verified — read from the two bundles]

CAPI / model + account traffic worth redirecting:
- `api.githubcopilot.com` (default CAPI base), `api-model-lab.githubcopilot.com`
- `copilot-proxy.githubusercontent.com` (default proxy base)
- `api.github.com` (`/copilot_internal/user` discovery, `/v2/token`)
- `api.mcp.github.com` (hosted MCP — a *separate* hardcoded base, same note as
  `vscode_copilot.rs`)

Leave alone (keep rules disjoint from these): `copilot-telemetry…`,
`origin-tracker…`, `raw/uploads/docs/support.github.com`, plus three hosts
confirmed non-CAPI *and* confirmed to reject regardless of trust channel —
`education.github.com`, `default.exp-tas.com`,
`mobile.events.data.microsoft.com` (measured 2026-10-15,
`agent-tls-and-ca-trust-matrix.md`: same Node TLS signature as the
accepted CAPI calls, still rejected — some Node-based call sites pin their own
CA bundle and ignore `NODE_EXTRA_CA_CERTS` regardless of stack). The
destination allowlist above already excludes all of these by construction —
listed here so the exclusion stays a documented decision tied to that
measurement, not an accident of the allowlist being narrow, if the matching
logic ever changes. Redirecting them would buy nothing anyway: they carry no
policy-relevant traffic, and Half 2 (§1) would reject the handshake
regardless of how well Half 1 works. Both the extension and the agent host
trust whatever `endpoints.api` / `endpoints.proxy` the discovery response
returns, so once the discovery leg is routed, later calls follow — same
property `vscode_copilot.rs` already relies on.

## 3. Architecture (shared listener, per-platform hook)

```
VS Code Copilot process ── connect() to api.githubcopilot.com:443
        │
   [platform redirect hook]  — app-id match + destination match
        │ rewrites destination → 127.0.0.1:<listener port>
        ▼
   ai-gateway listener (kinds::https) — already sniffs TLS/SNI, resolves
        the original host, terminates, relays through Optimus, returns
```

The listener half is **reused, not new**: `ai-gateway/listener/src/kinds/https.rs`
already sniffs ClientHello vs CONNECT, captures SNI, and resolves the
destination from SNI/Host when no CONNECT authority is present. The hook's only
job is landing the flow on it; recovering "what host did the client originally
want" is SNI on macOS and a WFP redirect record on Windows (§4).

### 3.1 Recovering the original destination — two different questions, two different sources

The redirect hook only solves "land the connection on the listener." After
that, two separate questions need answering, one kernel-verified and one
client-asserted — neither alone is enough:

- **What was the original destination (IP:port)?** The kernel rewrite at
  `FWPM_LAYER_ALE_CONNECT_REDIRECT_V4` doesn't erase this — WFP keeps a
  redirect record keyed to the new local 4-tuple, and the listener recovers it
  with `SIO_QUERY_WFP_CONNECTION_REDIRECT_RECORDS` on the accepted socket
  (§4.2, step 4). This is kernel-verified ground truth; the client cannot
  influence it.
- **What hostname did the client mean?** A bare IP:port doesn't give you
  `api.githubcopilot.com` as a string — one IP can front many hostnames behind
  a CDN, so IP alone doesn't tell the listener which cert CN to mint for the
  Half-2 TLS termination (§1). That string comes from the TLS ClientHello's
  SNI extension, sent in cleartext before anything is encrypted — exactly what
  `kinds::https.rs` already sniffs, per the diagram above. SNI is
  **client-asserted, not kernel-verified**: a client could in principle
  misstate it, and it is unavailable outright when the client uses ECH
  (Encrypted Client Hello) or connects to a bare IP literal.

Both sources stay in use for different purposes: the redirect record for the
real destination (policy/audit logs and enforces against what the OS actually
tried to reach, not whatever the client claims in SNI), SNI for the cert CN
and for `kinds::https.rs`'s existing host resolution. The degraded case — no
SNI, same IP-ambiguity problem as above — has no WFP-only fix; it falls back
to a pre-associated policy hostname keyed by IP, with the caveat that
shared-IP CDN hosting can make that mapping ambiguous. Not an observed problem
for VS Code Copilot's own hosts (§2.2) as measured this session, but a known
limit worth stating rather than assuming away.

### 3.2 Two key pairs, not one — what the installed root actually verifies

Half 2 (§1) — the agent trusting the listener's cert — rests on two
**independent** key pairs that are easy to conflate because both are called
"the cert" in casual conversation. Neither is ever shared with or derived
from the other; the only link between them is a signature.

| | Root CA pair | Leaf pair |
|---|---|---|
| Private key | the gateway's own CA key (`LocalCa`, `ai-gateway/listener/src/certs.rs`), delivered via `.broker.zip` — never this process's own leaf keys | a fresh key pair generated **in memory, per host**, at mint time (`certs.rs::mint_leaf_inner`) |
| Public key | published to `ca-cert.pem` — what `NODE_EXTRA_CA_CERTS` (or the OS store, for the `vscode-copilot` device-wide exception, `ca-trust-deployment-model.md`) delivers to the agent **once, ahead of time** | embedded in the leaf cert sent live over the wire, fresh per connection to that host |
| What it's used for | **signing** the leaf's data at mint time (an issuance act) | **authenticating the live handshake** — proving the listener holds the key matching this connection's cert (TLS `CertificateVerify` / key-exchange signing) |

So the cert an agent is pre-configured to trust is **never** the cert the
TLS handshake actually authenticates with — it's the cert used to verify
*who signed* the one that does. Concretely, at handshake time:

1. The listener sends the leaf (public key A) plus a signature over it.
2. The agent already has the root's public key B on file (from the one-time
   setup above, not from this connection).
3. The agent checks: does the signature verify under B? If yes, it trusts
   that a CA it already decided to trust vouched for this leaf — this step
   never touches the leaf's own key pair.
4. Separately, the handshake's own signing step proves the listener holds
   the private key matching A — this step never touches the root's key
   pair.

This is also why the root doesn't need to be re-delivered or re-trusted per
host: it's a one-time trust decision (§1, Half 2) that every subsequently
minted leaf, for every host, rides on without any further agent-side
configuration.

## 4. Windows — `FWPM_LAYER_ALE_CONNECT_REDIRECT_V4` (lead platform)

### 4.1 Why this reuses the most [verified]

The parked SNI driver (`driver/zsai-netflt/`, built with WDK 10.0.26100,
validated on Server 2025 — `docs/network-egress-sni-driver-parked.md`) already:
- registers callouts with `FwpsCalloutRegister1` (required at the redirect
  layer — `FwpsCalloutRegister0` does not work there);
- has a device + pend/verdict IOCTL protocol to user mode (`callout.rs`,
  `IOCTL_GET_FLOW` / `IOCTL_SET_VERDICT`, versioned wire format);
- adds filters/sublayer/provider in one rollback transaction (`RegisterCallouts`).

And the user-mode enforcer (`enforcer.rs`) already builds `ALE_APP_ID`
(`FwpmGetAppIdFromFileName0`) + remote-IP + port conditions, and
`reconcile::compute_filters` turns `domains` rules into resolved destination
filters from live DNS. So "match Code.exe → these hosts" is **already
expressible**; only the redirect *action* is new.

### 4.2 The new piece [verified against Microsoft docs]

A callout registered on `FWPM_LAYER_ALE_CONNECT_REDIRECT_V4` (+ `_V6`), in its
classify:
1. `FwpsRedirectHandleCreate0` once, cached (reused across flows).
2. `FwpsQueryConnectionRedirectState0` — if `PREVIOUSLY_REDIRECTED_BY_SELF`,
   return permit/continue (loop guard; the listener's own outbound socket to the
   real host must not be re-redirected).
3. `FwpsAcquireWritableLayerDataPointer0` → cast to `FWPS_CONNECT_REQUEST0`,
   set `remoteAddressAndPort` → `127.0.0.1:<port>`, set `localRedirectTargetPID`
   (the listener's PID) and `localRedirectHandle` (the cached handle).
4. The listener recovers the original destination via
   `SIO_QUERY_WFP_CONNECTION_REDIRECT_RECORDS` and stamps
   `SIO_SET_WFP_CONNECTION_REDIRECT_RECORDS` on its own outbound socket so WFP
   relates the two connections (and the loop guard in step 2 fires on it).

This is a **new callout on a new layer in the existing driver**, not a new
driver. It reuses the device, the sublayer, and the transaction pattern.

### 4.3 Open items (Windows)

- EV + attestation (or WHQL) signing — **no MDM bypass**; the driver's `.sys` is
  still unsigned by CI (`network-egress-sni-driver-parked.md`). Decide signing
  path early; it has independent lead time.
- Crash-safety: a bug here BSODs the machine (vs one process on macOS). The
  classify must be minimal — redirect only; never TLS/HTTP in the kernel.
- Confirm the WDK is present on the AIPTester box (B/`mc/b` or the AWS VM C —
  `project_windows_test_box.md`) before any build.
- `localRedirectTargetPID` requires the ETW sensor to have attributed the
  listener's PID; the same first-connection attribution race `network_egress`
  already documents applies.

## 5. macOS — `NETransparentProxyProvider` (second)

### 5.1 Entitlement is already granted [verified — corrects prior docs]

`packaging/macos/profiles/network.provisionprofile` grants
`com.apple.developer.networking.networkextension = [packet-tunnel-provider,
app-proxy-provider, content-filter-provider, dns-proxy, …]`. The
`app-proxy-provider-systemextension` value is present. The `branding.toml` /
`profiles/README.md` comments saying "content-filter only" are **stale** — the
"is a new Apple entitlement request needed" open item from the prior docs is
**resolved: no**.

### 5.2 Selection is `includedNetworkRules`, not `NEAppRule` [verified — corrects prior docs]

`NETransparentProxyProvider` (macOS 11+) is a subclass of `NEAppProxyProvider`.
Flows reach it via `NETransparentProxyNetworkSettings.includedNetworkRules`
(`[NENetworkRule]`); `excludedNetworkRules` take priority. `NENetworkRule` has
`init(destinationHost:protocol:)` — "a host within a specific DNS domain" — so
we include exactly the §2.2 hosts. **Per-app narrowing happens inside
`handleNewFlow`** via `flow.metaData.sourceAppSigningIdentifier` (match
`com.microsoft.VSCode.helper`); returning **`false` passes the flow through
untouched** (this is the key `NETransparentProxyProvider` difference from
`NEAppProxyProvider`, where `false` drops it). The prior docs' "`NEAppRule`
by bundle id" framing is wrong for this provider type.

### 5.3 Can ride in one sysext with the content filter [verified — DTS-confirmed]

`Info.plist` `NEProviderClasses` may map both
`com.apple.networkextension.filter-data` and `.app-proxy` to classes in the
**same** bundle/process (one XPC endpoint, shared crash domain). So this need
not be "a third extension target" — it can join the planned content-filter
sysext. Trade-off: a crash in one provider takes out the other; keep their
rule sets disjoint (also dodges the historical 11.1 wss-upgrade bug, fixed in
11.2; product min is macOS 11.0).

### 5.4 Open items (macOS)

- No NE provider source exists yet — `net_egress/macos.rs` is daemon-side
  plumbing for a sysext never written; `net-agent` (Swift) has only
  `activate`/`deactivate` and needs `NETransparentProxyManager` enable/disable
  verbs.
- This dev Mac (A/`mc/a`) can't prototype: SIP enabled, Command Line Tools only
  (no `xcodebuild`), zero signing identities. Needs a SIP-disabled Mac/VM
  (`systemextensionsctl developer on`) or the team's Developer ID cert+profile.
- Coexistence: real devices run ZCC's `TRPTunnel` packet-tunnel NE and
  CrowdStrike ES — validate side-by-side.

## 6. Listener changes

Likely minimal: `kinds::https` already resolves destination from SNI. Needed:
(a) a bind/accept path for transparently-redirected flows (no CONNECT), (b) on
Windows, read/stamp the WFP redirect records so the relationship + loop guard
work, (c) scope the gateway's own outbound socket out of the redirect (by PID).

## 7. Build order

1. **Windows**: confirm WDK on the test box; decide signing; add the
   CONNECT_REDIRECT callout (redirect only) reusing the existing device +
   filter/DNS machinery; point redirected flows at the listener; validate the
   attribution race.
2. **macOS**: write the `NETransparentProxyProvider` subclass + `net-agent`
   verbs on a SIP-disabled box; reuse the same listener.
3. Policy/settings surface for a `redirect` action, parallel to `block`/`allow`.

## 8. Parallel test — non-enforced proxy lever — **run, confirmed working, 2026-10-13**

Separate from the hook, and run in parallel rather than waiting on kernel work.
**[verified from the bundles, then confirmed live]**: the `copilot-chat`
extension defaults to Electron's `net` fetcher
(`advanced.debug.useElectronFetcher` default true) — Chromium proxy resolution
(honors VS Code `http.proxy` + system proxy) and the **system keychain** for
TLS trust. The prior research doc's "proxy is ignored" finding only tested
`HTTPS_PROXY`/`NODE_EXTRA_CA_CERTS` — Node mechanisms Electron fetch ignores by
design. `http.proxy` is a different path and was never tested until now.

**Test performed** (compliance-safe: a pass-through CONNECT-logging proxy,
never terminating TLS or reading content; and no real Copilot Chat round-trip
was needed — the discovery/auth calls alone, triggered by sign-in, were
sufficient):
1. Set `"http.proxy": "http://127.0.0.1:8899"` + `"http.proxyStrictSSL": false`
   in the real `settings.json` on the `ukanitkar` account (ordinary `github.com`,
   Business seat, `enterprise: false` — the exact account from
   `vscode-copilot-enterprise-gate-account-test.md`).
2. Restarted VS Code, signed into Copilot, sent one chat message ("why is the
   sky blue?" — in a non-IP/open-source context per the admin's pilot-scope
   note).

**Result: every Copilot-related host routed through the proxy, with zero
direct connections from any VS Code process.** Observed on the wire:
`api.github.com` (×14 — discovery `/copilot_internal/user`, token exchange),
`api.business.githubcopilot.com` (×7 — the actual `/chat/completions`/`/models`
CAPI calls, Business-tier routing), plus `exp.`/`proxy.`/`telemetry.business.githubcopilot.com`.
The chat itself completed successfully with a real model response — this is
confirmed CAPI traffic, not just auth.

**What this changes:** rows 1–3/5–7 of the licensing matrix get a real,
working, **non-enforced** lever today, on an account that gets `enterprise: false`
on every other mechanism tested. **What it doesn't change:** this is routing
only (no TLS termination was attempted — the keychain-trust question in §5
caveat remains untested), and it's user-editable unless pushed via an
MDM-managed VS Code settings profile. It is a real interim option alongside
this doc's hook design, not a substitute for the enforced version.

**Next step on this thread:** install a CA in the system/login keychain and
re-run with a terminating (MITM) relay instead of pass-through, to close the
one remaining unknown between "routes through a proxy" and "fully
intercepted."

## Sources

- Apple: [`NETransparentProxyProvider`](https://developer.apple.com/documentation/NetworkExtension/NETransparentProxyProvider),
  [`NETransparentProxyNetworkSettings`](https://developer.apple.com/documentation/NetworkExtension/NETransparentProxyNetworkSettings),
  [`NENetworkRule`](https://developer.apple.com/documentation/NetworkExtension/NENetworkRule),
  [`NEFlowMetaData`](https://developer.apple.com/documentation/NetworkExtension/NEFlowMetaData)
- Microsoft: [Using Bind or Connect Redirection](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/using-bind-or-connect-redirection),
  [`FwpsRedirectHandleCreate0`](https://ntdoc.m417z.com/fwpsredirecthandlecreate0),
  [`FwpsQueryConnectionRedirectState0`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/fwpsk/nf-fwpsk-fwpsqueryconnectionredirectstate0)
- This repo: `docs/network-egress.md`, `docs/network-egress-sni-driver-parked.md`,
  `driver/zsai-netflt/`, `src/services/net_egress/{enforcer,callout,reconcile}.rs`,
  `ai-gateway/listener/src/kinds/https.rs`, `packaging/macos/profiles/network.provisionprofile`
