# ai-testing — recovered testing & documentation

Everything here was **deleted** from `ai-protect` in commit `7bdeb17a`
("ai-gateway: protocol crate, full-state status, per-agent spans, doc
cleanup", by Ajit Singh, PR #639) and restored from its parent commit,
`70de3917`, so the prior AI Gateway design docs and the Windows E2E test
harness aren't lost even though `ai-protect`'s own tree moved on to a
different testing/doc structure (`docs/ai-gateways.md`,
`ai-gateway/scripts/integration.ps1`).

Its own git repo (`github.com/ukanitkar/ai-testing`), separate from
`ai-protect` — files mirror their original relative paths there for context.

## What's here

- `commands/` — the full Windows E2E test suite (PowerShell): the main
  orchestrator (`run-e2e-suite.ps1` + its elevated helper) and every
  `phase-*`/`path-*` step script, plus a few scratch/debug leftovers
  (`fix1.txt`, `fix2.txt`, `check-both.ps1`, …).
- `docs/ai-broker-work/` — the AI Broker/Gateway design & control-plane docs
  (architecture diagrams, integration design, auth, LLM brokering, the
  Windows privilege-drop test plans and verification doc, the watcher/port
  design doc, and the "current state" control-plane reference).
- `ai-gateway/docs/` — the e2e-script guide, test ledger, and test-order docs
  that lived alongside the (now-superseded) crate split.
- `ai-gateway/TESTING.md` — the crate split's own testing doc.
- `ai-gateway/scripts/` — the testing-specific shell scripts (`step0`–`step5`,
  `install-test-agents.sh`, `verify-llm-gateway.sh`) and `dev_device_plane.py`,
  the mock ai-platform device-plane server the E2E suite drove against.

## Not included

Source code and runtime config that were also deleted in the same commit
(the old `ai-gateway/sdk`, `listener`, `mon`, `credential-manager` `.rs`
files; `ai-gateway/config/*.yaml`; `ai-gateway/mon/templates/*`;
`ai-gateway/scripts/admin.yaml` / `approve_agent.py`) — those were
superseded by the new architecture, not testing/documentation, so they
weren't pulled into this archive.
