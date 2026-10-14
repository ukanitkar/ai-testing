# VS Code Copilot's `enterprise: true` gate — account test against a real Zscaler-licensed account

Follow-up to `vscode-copilot-chat-extension.html`'s open risk (§6): whether a
real customer account can ever satisfy the `enterprise: true` gate that
activates the `github-enterprise.uri` CAPI-discovery hijack. That doc's own
live tests never covered an account with a real Enterprise/Business license
attached. This one does — against `ukanitkar`, a real Zscaler-licensed
GitHub account — and also answers the broader question of what, if
anything, can be done for customers who are on ordinary `github.com` with no
GHE angle at all.

**Bottom line: still `enterprise: false`, and now definitively so.** A real
Copilot Business seat and real Zscaler Enterprise membership were not enough
to activate the mechanism. The one remaining untested path — a genuine
GHE.com sign-in — is now **closed outright**: Zscaler's GitHub admin
confirmed there is no dedicated GHE.com instance at all (§3). There is no
further way to reach `enterprise: true` on this account through that route.

**But a separate, non-account-gated lever was found live and confirmed
working, 2026-10-13: VS Code's `http.proxy` setting routes all Copilot CAPI
traffic, including real `/chat/completions` calls, through a proxy on this
same ordinary (`enterprise: false`) account** (§5 item 5). It's
non-enforced (user-editable) and untested for full TLS termination, but it
changes the answer for the ordinary-`github.com` population from "no known
option" to "a real interim lever exists, with an enforced follow-up being
designed" (`vscode-copilot-network-egress-redirect-design.md`).

## 1. What this account actually has

Checked directly on `github.com` and in VS Code's own local state:

- **`github.com/settings/enterprises`**: `ukanitkar` is a member of two
  Enterprise accounts — `AIGateWayTeam` (Owner, 12-day trial — the same
  self-provisioned trial from `github-copilot-app-interception-feasibility.md`,
  already known to have no path to Copilot Business/Enterprise at all) and
  **`Zscaler` (Member)** — presumably the real employer-owned Enterprise
  account.
- **`github.com/settings/sso`**: only **`AIGuardOrg`** shows an active
  enforced SSO session. No row for `Zscaler` or `AIGateWayTeam` — i.e.
  Zscaler's Enterprise does not appear to enforce SAML SSO on this account.
  This is itself informative: it suggests membership here is ordinary
  org/seat membership, not an SSO-gated enterprise session.
- **VS Code's `state.vscdb`** (`~/Library/Application Support/Code/User/globalStorage/state.vscdb`):
  - `github.copilot-github` → `ukanitkar` (confirms the signed-in identity).
  - `extensionsAssignmentFilterProvider.copilotSku` →
    `copilot_for_business_seat_quota` — **confirms a genuine Copilot
    Business seat**, not the free/individual tier.
  - `defaultAccount.cachedPolicyData` → holds `policyData` (`chat_agent_enabled`,
    `chat_preview_features_enabled`, `mcp: false`, …) but **no `enterprise`
    field, no enterprise-auth-provider object, nothing matching the
    `IDefaultAccountAuthenticationProvider` shape** `defaultAccount.ts`
    returns when `enterprise` is true.
  - The wider model catalog in Copilot Chat's model picker (Claude Sonnet
    5.5, GPT-6 Luna, GPT-6.1 Sol, etc.) is consistent with the Business-seat
    SKU finding — it's evidence for the *license tier*, not for the
    `enterprise` auth-provider flag, which is a separate axis entirely.

**Takeaway:** a real Copilot Business seat + real Enterprise-account
membership on ordinary `github.com` does **not** by itself flip
`enterprise: true`. That flag tracks which `defaultAccountProvider` VS Code
has registered internally, not your license/SKU or org membership.

## 2. The local behavioral test

Since `enterprise` is never persisted anywhere (confirmed by the
`cachedPolicyData` check above — it's computed fresh by
`getDefaultAccountAuthenticationProvider()`, not cached or written to disk),
the only way to observe it is behaviorally: configure `github-enterprise.uri`
to point at a listener you control, sign in fresh, and see whether the
discovery call (`GET /copilot_internal/user`) ever arrives.

**Setup:**
- Built and ran `ai-gateway/gateway-simple` (binary: `ai-gateway-simple`) —
  the existing test harness that implements exactly this relay: binds a
  loopback port, answers `/copilot_internal/user` with a real call to
  `api.github.com` then rewrites `endpoints.api` to point back at itself,
  and passes everything else through.
- Pointed `~/Library/Application Support/Code/User/settings.json`'s
  `github-enterprise.uri` at that listener (`http://localhost:63956`).
- Signed out of Copilot Chat in VS Code, then signed back in via
  **"Continue with GitHub"** (the ordinary OAuth flow,
  `github.com/login/oauth/authorize…`).

**Result:** zero requests ever reached the listener. Same outcome as every
consumer account tested before this one.

**A second, incidental finding from this test:** VS Code's Copilot sign-in
dialog has a **third button**, "Continue with GHE.com", alongside "Continue
with GitHub" and "Continue with Google"/"Continue with Apple". Clicking it
writes two settings automatically:

```json
"github-enterprise.uri": "https://<slug>.ghe.com",
"github.copilot.advanced": { "authProvider": "github-enterprise" }
```

We tried manually pre-setting `authProvider: "github-enterprise"` ourselves
(keeping our own `github-enterprise.uri` value) and then signing in via the
*ordinary* "Continue with GitHub" button instead, to see if the override
alone was enough without a real GHE tenant. It wasn't — `authProvider` got
silently reset back to `{}` by the time sign-in completed. That strongly
suggests `authProvider` is **write-back state that reflects which flow you
actually completed**, not a free-standing switch you can pre-set to change
behavior. The only way to set it that "sticks" is to actually complete a
GHE.com sign-in.

## 3. The GHE.com path — closed, confirmed by Zscaler's GitHub admin

Guessed `zscaler.ghe.com` as the likely tenant slug and clicked "Continue
with GHE.com" twice. Both times: `DNS_PROBE_FINISHED_NXDOMAIN` — that
specific hostname does not exist. That alone only ruled out one guessed
slug, so the admin was asked directly whether a GHE.com tenant exists at
all.

**Admin's answer (2026-10-12):**

> The current GitHub is SaaS multi tenant hosting Enterprise tier. While we
> dont have dedicated instance, the agreement is protected by agreement
> between ZS and MS.

This is a definitive answer, not just a failed guess: Zscaler is on
ordinary **multi-tenant `github.com`** with an Enterprise plan, **no
dedicated GHE.com instance at all**. The ZS/MS agreement referenced is a
contractual/legal safeguard (data-processing / enterprise terms), not a
technical multi-tenancy boundary — it creates no separate sign-in flow and
no distinct `defaultAccountProvider` the way a real GHE.com tenant would.

This also resolves the distinction that caused confusion mid-investigation:

- **"Zscaler" showing up under `github.com/settings/enterprises`** is an
  Enterprise *billing/admin* layer on top of ordinary `github.com` — exactly
  what the admin confirmed. It never implied a GHE.com tenant.
- **GHE.com** is a distinct product (Enterprise Cloud with data residency)
  with its own dedicated subdomain. Zscaler is confirmed not to use it.

**Net effect:** the GHE.com sign-in path is closed for this account, not
just untested. The one remaining candidate mechanism for a genuine
enterprise-flavored sign-in — one that doesn't require a dedicated
instance — is GitHub **Enterprise Managed Users (EMU)**, which runs on
ordinary `github.com` but has its own SSO-only sign-in flow and a
username suffix (e.g. `ukanitkar_zscaler`). The signed-in account here is
plain `ukanitkar`, with no such suffix — evidence against EMU being in use,
but not yet confirmed directly. Follow-up question sent to the admin to
settle this (§6).

### Compliance note surfaced in the same reply

The admin's response also included an unprompted but important policy
note:

> Please note, the Copilot is only approved for pilot with non-IP repos and
> we expect open source code usage during your testing/evaluation.

This matters directly for how this investigation (and any further testing)
should be scoped: Copilot Chat is only approved against **non-IP /
open-source repositories**, not Zscaler's own proprietary codebases. The
testing in this doc was scoped to the sign-in/discovery-URL mechanism only
— no chat prompt was ever issued referencing proprietary repo content — but
this is worth treating as a hard constraint for any further testing, not a
footnote: **do not issue real Copilot Chat prompts inside proprietary
repos** (this one included) as part of this work. If further testing needs
a real chat round-trip (not just the discovery call), it should happen
against a non-IP/open-source repo instead.

## 4. "GitHub Enterprise" vs "Copilot Business/Enterprise" — two different axes

Worth spelling out precisely, since conflating these two is exactly what
caused confusion mid-investigation (§1's "real Business seat + real
Enterprise membership" framing is easy to misread as one thing when it's
actually two independent axes):

**Axis 1 — GitHub's own hosting/account plan** (governs SSO/SAML, audit
logs, advanced security, and *how* the org is hosted):
- GitHub Free / Team — ordinary multi-tenant `github.com`.
- **GitHub Enterprise** (Cloud or Server) — adds SSO/SAML, audit logs,
  policy enforcement, advanced security. Enterprise *Cloud* can be either
  ordinary multi-tenant hosting (what Zscaler has, confirmed §3) or a
  **dedicated `<slug>.ghe.com` instance** (what Zscaler confirmed it does
  *not* have).

**Axis 2 — GitHub Copilot's own subscription tier** (a separate product,
billed per seat, layered on top of whichever hosting plan the org has):
- Copilot Individual — personal.
- **Copilot Business** ($19/user/month) — centralized seat management,
  policy toggles (e.g. block suggestions matching public code), content
  exclusions.
- **Copilot Enterprise** ($39/user/month) — higher AI-request allowance,
  earlier access to new models, deeper customization (custom knowledge
  bases, Copilot Chat on github.com itself).

Per GitHub's own docs, Business and Enterprise are "the two Copilot plans
for customers on GitHub Enterprise Cloud" — an enterprise account picks
one per organization. Worth verifying rather than assuming: whether a
standalone non-Enterprise org (plain GitHub Team) can still buy Copilot
Business on its own — the docs found so far are scoped to the
enterprise-account purchasing flow specifically, so this isn't confirmed
either way from them alone.

**Why this matters for this doc's core finding:** Zscaler's actual setup —
real Enterprise-account membership (Axis 1, ordinary multi-tenant) **plus**
a real Copilot Business seat (Axis 2) — is exactly the combination tested
live in §1–2, and `enterprise: true` stayed false. That's because VS
Code's gate cares about **how the sign-in happened** (tied to Axis 1's
hosting model — specifically whether it's a genuinely GHE-flavored sign-in
like a dedicated GHE.com instance), not which Copilot billing tier is
active (Axis 2). A hypothetical upgrade to Copilot Enterprise alone, with
no dedicated GHE.com instance, would very likely produce the same
`enterprise: false` result — the SKU doesn't touch the sign-in flow at
all. This is also why the matrix in the shared licensing doc treats
"License Needed" as a hosting-model question (dedicated GHE.com instance),
never a Copilot-tier question.

Sources:
- [Choosing your enterprise's plan for GitHub Copilot](https://docs.github.com/en/enterprise-cloud@latest/copilot/get-started/choosing-your-enterprises-plan-for-github-copilot)
- [GitHub Copilot Business vs Enterprise: Choosing the Right Plan for Your Team](https://ruby-doc.org/blog/github-copilot-business-vs-enterprise-choosing-the-right-plan-for-your-team/)

## 5. The broader question: customers on ordinary `github.com`, no GHE at all

Separately from testing this specific account: for a customer who is purely
on `github.com` with no GHE angle whatsoever, the account-tier/sign-in-flow
levers are closed — but **one non-account-gated lever was found live this
session and works today.** Status of every direct lever examined
(`vscode-copilot-chat-extension.html` §2, plus the new finding):

1. **Extension debug settings** (`overrideProxyUrl`/`overrideCapiUrl`) —
   confirmed ignored by `github.copilot-chat` (a filed GitHub issue shows
   this). Closed.
2. **Node-level `HTTPS_PROXY`/`NODE_EXTRA_CA_CERTS`** — the mechanism every
   other adapter in this codebase relies on. Real user reports say the
   extension ignores `NODE_EXTRA_CA_CERTS`; Microsoft's own design doc
   (`agentHost/node/claude/CONTEXT.md`) confirms proxy support for
   chat/completion traffic via this specific path is "Deferred for later
   phases." Closed, but narrower than it first reads — see #5.
3. **BYOK** (`chatLanguageModels.json`) — strictly additive; registers a
   new selectable model alongside Copilot's own, can't redirect or
   intercept Copilot's default traffic. Closed.
4. **The `github-enterprise.uri` discovery hijack** (the mechanism this
   whole investigation is about) — gated behind `enterprise: true`, which
   this doc confirms stays `false` for an ordinary sign-in, Business seat or
   not. Doesn't help this population.
5. **VS Code's `http.proxy` setting (the Electron fetch path) — confirmed
   working, 2026-10-13.** The research that closed #2 only tested the Node
   `HTTPS_PROXY`/`NODE_EXTRA_CA_CERTS` path. The Copilot Chat extension
   defaults to Electron's own fetcher
   (`advanced.debug.useElectronFetcher` = true), which uses Chromium's
   proxy resolution — i.e. VS Code's `http.proxy` setting — not Node's env
   vars. Live-tested end to end on this `ukanitkar` account (ordinary
   `github.com`, Business seat, `enterprise: false`): with
   `"http.proxy": "http://127.0.0.1:<port>"` set and a pass-through
   CONNECT-logging proxy listening, **every CAPI and auth host routed
   through it** — `api.github.com` (discovery/token), and the full
   `*.business.githubcopilot.com` family including a real
   `/chat/completions` call that returned a genuine model response. Zero
   direct (non-proxied) connections from any VS Code process. This is the
   first mechanism in this investigation confirmed to touch the actual
   chat/completions traffic on an ordinary, non-GHE account.
   - **Caveats, stated precisely:** only *routing* was tested (a
     pass-through proxy, no TLS termination) — not full interception. The
     extension trusts the **system/login keychain** for TLS
     (`@vscode/proxy-agent`'s `loadSystemCertificates`), so a CA installed
     there should work for a real MITM relay, but that step was not run.
     The setting is also **user-editable, not enforced** — anyone can
     delete it — unless pushed via an MDM-managed VS Code settings
     profile, which would make it semi-enforceable rather than a true
     kernel-level guarantee. Full write-up, architecture, and the Windows
     `ALE_CONNECT_REDIRECT`/macOS `NETransparentProxyProvider` plan for the
     *enforced* version of this:
     `vscode-copilot-network-egress-redirect-design.md` §7.

**What's left for genuine enforcement** (not just routing) are the
non-interception levers already considered (`vscode-copilot-chat-extension.html`
§8) plus the network-egress redirect hook now being designed:

- **Fork VS Code itself** (core is MIT; the Copilot Chat extension is not)
  to build an interception layer from scratch. Rejected: replaces a vendor
  binary instead of configuring one, needs ongoing rebasing against a
  fast-moving upstream, real distribution/policy cost.
- **Block instead of intercept** — `chat.disableAIFeatures: true`, or the
  more durable Windows `AllowedExtensions` registry policy. Real and
  working today, but stops Copilot Chat from running at all rather than
  letting policy observe/relay its traffic.
- **Replace with a different extension** — Continue (proxy-aware, covers
  autocomplete) or this product's own Claude Code extension (already a
  proven brokered agent, no autocomplete surface). Neither is a clean
  swap; both sidestep Copilot Chat rather than intercepting it.
- **Network-egress redirect** (Windows `FWPM_LAYER_ALE_CONNECT_REDIRECT_V4`,
  macOS `NETransparentProxyProvider`) — the enforced, kernel/NE-level
  version that doesn't depend on a user-editable setting. Design in
  progress: `vscode-copilot-network-egress-redirect-design.md`.

**For any customer conversation:** the `github-enterprise.uri` mechanism
should not be represented as covering the general case — it's a narrow
lever for genuinely GHE-flavored accounts, still unconfirmed against a real
one. But `http.proxy` (MDM-pushed) is now a real, working, much cheaper
*non-enforced* option for the ordinary-`github.com` population, worth
raising as an interim capability alongside the longer-term egress-hook
work — not "block or replace" as the only honest answer anymore.

## 6. Open items

- [x] Get confirmation on whether a GHE.com tenant exists for Zscaler —
      **done, 2026-10-12: confirmed none exists** (§3).
- [ ] Confirm whether Zscaler's GitHub Enterprise uses **EMU (Enterprise
      Managed Users)** — the one remaining non-dedicated-instance path to a
      genuine enterprise-flavored sign-in. Follow-up question sent to the
      admin:

      > Thanks — that's helpful and answers the GHE.com question cleanly.
      > One more specific question: is Zscaler's GitHub Enterprise using
      > **Enterprise Managed Users (EMU)**? I ask because my own username
      > doesn't have the EMU-style suffix, so I suspect not, but wanted to
      > confirm directly rather than assume.

- [ ] If EMU is confirmed in use, repeat the behavioral test by signing in
      through that flow for real — the remaining authoritative version of
      this test.
- [ ] If EMU is also not in use, `enterprise: true` should be considered
      **unreachable for Zscaler's own account** via any sign-in flow, not
      just "unverified" — re-examine `vscode_copilot.rs`'s shipped
      `enabled: true` decision in that light.
- [x] Test whether VS Code's `http.proxy` setting routes Copilot CAPI
      traffic — **done, 2026-10-13: confirmed yes**, including a real
      `/chat/completions` call (§5 item 5). Tested in compliance with the
      admin's pilot-scope note, using a pass-through (non-MITM) proxy and
      no proprietary repo content.
- [ ] Test whether a CA installed in the system/login keychain lets a real
      MITM relay terminate that routed traffic (the remaining step between
      "routes through a proxy" and "fully intercepted").
- [ ] Decide product direction for the ordinary-`github.com` population
      (§5): MDM-pushed `http.proxy` as an interim non-enforced lever,
      network-egress redirect as the enforced follow-up, or
      block/replace — no longer "no option," now a prioritization choice.
- [ ] **Compliance:** any further testing that needs a real Copilot Chat
      round-trip (not just the discovery call) must happen against a
      non-IP/open-source repo, per the admin's pilot-scope note (§3).
