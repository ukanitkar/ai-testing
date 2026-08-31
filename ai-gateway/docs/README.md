# ai-gateway — docs

## Design record

The architecture decisions behind `ai-gateway` — why the crates sit outside the
daemon build graph, why it's a mono-exe, why the signed SDK client replaces
Python's `httpx` monkey-patch, and why the relay registers *as* the agent it
serves — are written up here, with diagrams:

**https://claude.ai/code/artifact/9d348c21-2fdf-4f5b-9945-ca604826ef89**

> Private link. If you get a 404, ask @ukanitkar for access rather than
> assuming the page has moved.

Covers:

- **Placement and build isolation** — why the root-privileged daemon never links
  the gateway crates (there are 11 now, not the two the page describes)
- **Process model** — service mode / `--bridge <agent>` / `--recover`
- **Enrolment order** — the constraint that matters: persist the record, push the
  credentials, bind the listener, *then* emit the config
- **The MCP leg** — vector-discovered brokers (`list_brokers()`),
  `<server>_<tool>` namespacing, `isError: true` instead of JSON-RPC errors
- **The LLM leg** — upstream resolution, loop guard, cleartext guard
- **Identity and credentials** — registering as the agent; the credential store
  that lets per-session bridges skip interactive OIDC
- **Config delivery** — `.status.zip`'s `ConfigDelta`s, which ai-protect merges;
  ai-gateway writes no agent config itself
- **Daemon integration** — the `settings.received` reconcile flow and the three
  `TODO(ai-broker)` blockers
- **Open issues** — recorded deliberately, since they're the part most easily
  lost between reviews
- **Decision ledger** — 13 decisions with rationale and status

Six diagrams: build-graph isolation, runtime topology, enrolment sequence, MCP
`tools/call` path, daemon reconcile flow, recovery decision tree.

⚠️ **The page predates the module integration.** It still describes the bootstrap
and the three retired listener modes (`--mcp-server`, `--llm-proxy`,
`--llm-forward-proxy`). [OperationalModes.md](OperationalModes.md) is the current
mode table; treat that as authoritative where the two disagree.

The page is generated, not hand-maintained. It reflects the tree at commit
`052e697` — re-check it against the code before relying on any detail.

## Registration approval

REGISTER (`POST /vector/v1/sdk/agents:register`) can leave the agent **pending**,
and the SDK then polls `/v1/sdk/agents:status` for 300s waiting for an admin.
Nothing downstream runs until that resolves — ACTIVATE and EXCHANGE both depend
on it, so an unapproved agent never becomes serviceable: it reports `enrolling`
and the config-emit gate withholds its `ConfigDelta`.

Auto-approval is on for the dev tenant, but it does **not** cover every agent. An
admin authors an auto-approval policy (`bumblebee-admin`,
`auto_approval_policies`: tenant × subject scope × object type), it publishes to
Redis, and `zax-proxy-authz` stamps `x-agent-auto-approval` on the register
request, which vector approves inline — minting the AID without a separate
activate.

⚠️ Observed 2026-08-30, three agents in one run: `codex` and `gemini` came back
`status="approved" identity_status="active"` on poll #1, while `claude` stayed
`status="pending_approval"` through poll #3 and never enrolled. So the policy's
subject scope does not cover Claude on this tenant — worth checking before
reading a stuck `enrolling` as a device-side fault.

The policy has no version or hash dimension, so one policy covers every
subsequent release of an agent — which matters, because the gateway registers
*as* the agent it serves. Note that `software_hash` is currently sent **empty**
by both sides, so it cannot be the discriminator either way.

> The `agent_id` in the `[onboard]` log lines is a local addition to the vendored
> SDK (`sdk/src/registration/agent_onboard_client.rs`, marked `DIVERGENCE`)
> restoring what zax-sdk-python logs. It is the only handle an admin has for
> approving a registration by hand; without it the id first appears in the 300s
> poll timeout, by which point `sdk_init()` has already failed. Re-apply it if
> that file is re-vendored.

## Recovering a test run

`--recover` is the teardown mode. It reverses the config edits this product
makes — including an `ANTHROPIC_BASE_URL` left pointing at a proxy that is no
longer running, which stops Claude Code working entirely:

```bash
zscaler-ai-gateway --recover --dry-run                 # report only, writes nothing
zscaler-ai-gateway --recover                           # repair
zscaler-ai-gateway --recover --purge-home --clean-backups
zscaler-ai-gateway --recover --keep-credentials        # keep the credential store
```

Surgical by default: it removes only the keys this product writes, so live
state in `~/.claude.json` (project history, sessions) survives. Restoring a
`.bak.<ts>` is the fallback for a file that no longer parses, and everything it
rewrites is snapshotted to `*.pre-recover.<ts>` first. The credential store is
deleted unless `--keep-credentials` — it's a live credential, and the service
discards it on every run anyway. Exit status is 1 when something was left
unrepaired, so it works as a test-teardown step.

The recovery-only flags are rejected without `--recover`, so a stray `--dry-run`
can't fall through to a mode that enrols for real.

It does **not** undo the tenant-side agent registration that `sdk_init()`
performs; that's server-side.

This replaced a standalone `scripts/claude-recover.py` (removed — see git
history for `ZSAI-6236` if you need it). The divergences from that original,
each one a bug it had, are listed at the top of `service/src/recover.rs`.