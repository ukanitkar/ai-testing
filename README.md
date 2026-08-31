# ai-testing — testing & documentation for ai-protect / ai-gateway

Home for all documentation and testing scripts related to `ai-protect`'s
AI Gateway (ai-broker) integration — going forward, new docs/scripts are
authored directly here rather than inside `ai-protect` itself. Its own git
repo (`github.com/ukanitkar/ai-testing`), separate from `ai-protect`; files
mirror their `ai-protect`-relative paths for context.

Two kinds of content live here, side by side in the same directories in a
few places (`ai-gateway/docs/`, `ai-gateway/scripts/`) — see the breakdown
below for which is which:

## Current (mirrored from `ai-protect`'s live tree, as of 2026-08-31)

- `docs/ai-gateways.md` — the current, consolidated AI Gateway design doc.
- `ai-gateway/docs/README.md`, `OperationalModes.md`, `TESTING.md` — the
  crate split's current docs.
- `ai-gateway/scripts/README.md`, `baseline.sh`, `build.sh`, `common.sh`,
  `integration.sh`, `integration.ps1`, `teardown.sh` — the current
  build/integration-test/teardown script set.

Not mirrored (deliberately): `ai-gateway/docs/x` (a ~5.7MB accidental shell-
history dump, gitignored in `ai-protect` itself) and `ai-gateway/docs/jeswin.html`
(an untracked personal file) — neither is real project content.

## Historical (recovered from deletion, commit `7bdeb17a`)

Everything else was **deleted** from `ai-protect` in commit `7bdeb17a`
("ai-gateway: protocol crate, full-state status, per-agent spans, doc
cleanup", by Ajit Singh, PR #639) and restored from its parent commit,
`70de3917`, so the prior AI Gateway design docs and the Windows E2E test
harness aren't lost even though `ai-protect`'s own tree moved on to the
"Current" structure above:

- `commands/` — the full Windows E2E test suite (PowerShell): the main
  orchestrator (`run-e2e-suite.ps1` + its elevated helper) and every
  `phase-*`/`path-*` step script, plus a few scratch/debug leftovers
  (`fix1.txt`, `fix2.txt`, `check-both.ps1`, …).
- `docs/ai-broker-work/` — the AI Broker/Gateway design & control-plane docs
  (architecture diagrams, integration design, auth, LLM brokering, the
  Windows privilege-drop test plans and verification doc, the watcher/port
  design doc, and the "current state" control-plane reference — "current"
  as of before the rework, now itself historical).
- `ai-gateway/docs/ai-broker-e2e-script-guide.html`, `ai-broker-test-ledger.html`,
  `e2e-test-order.html` — docs that lived alongside the pre-rework crate split.
- `ai-gateway/TESTING.md` — the pre-rework crate split's own testing doc (at
  the crate root, not under `ai-gateway/docs/` — that's what distinguishes it
  from the current `ai-gateway/docs/TESTING.md` above; they are different files).
- `ai-gateway/scripts/step0-build-test.sh` … `step5-teardown.sh`,
  `install-test-agents.sh`, `verify-llm-gateway.sh`, `dev_device_plane.py` —
  the pre-rework testing scripts, including the mock ai-platform device-plane
  server the old E2E suite drove against.

Not included even historically: the source code and runtime config also
deleted in the same commit (the old `ai-gateway/sdk`, `listener`, `mon`,
`credential-manager` `.rs` files; `ai-gateway/config/*.yaml`;
`ai-gateway/mon/templates/*`; `ai-gateway/scripts/admin.yaml` /
`approve_agent.py`) — those were superseded by the new architecture, not
testing/documentation, so they weren't pulled into this archive.
