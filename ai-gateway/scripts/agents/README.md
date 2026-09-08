# Per-agent end-to-end tests

One script per agent, covering the 7 confirmed-wired cases from the
minimum-agents review (`main-08272026-all-agents`, commit `e345e71e`):
`claude` (Desktop+Code), `cursor`, `gemini`, `openclaw`, `devin`, `windsurf`,
`codex`. Not covered — real gaps, see the review: VS Code+Copilot's editor
LLM leg, ChatGPT Desktop.

## Run

```powershell
cd ai-gateway\scripts\agents

# fast, no login — confirms `--agents` reports enabled+installed
.\test-cursor.ps1

# full check — one browser sign-in, asserts the real config file/registry content
.\test-cursor.ps1 -Live

# all 7, sequentially (one login per agent under -Live)
.\run-all-agents.ps1 -Live
```

Requires a build first (`..\build.ps1`) — same `$Gw`/`$Sim` binaries
`..\integration.ps1` uses, via `..\common.ps1`.

## Two tiers, on purpose

- **Detection** (always runs): `zscaler-ai-gateway --agents` reports this
  agent `enabled=true`. No login, no file writes.
- **Wiring** (`-Live` only): a real `zax-sim.exe` + `zscaler-ai-gateway.exe`
  deployment, one browser sign-in, then the exact config file/registry
  content is asserted once the agent's status reaches `success`. Config
  deltas **only land after real enrollment succeeds** — this is a hard
  product constraint (see `..\integration.ps1` step 7), not something an
  offline run can fake, so there's no offline file-assertion tier.

## Known, documented limitations — read before assuming a FAIL is real

- **Cursor's LLM leg cannot be exercised at all here.** It's pure
  process-env (`src/ai_broker_env/`), and the simulator's `apply.rs` has no
  code path for it — only the real installed daemon does. `test-cursor.ps1`
  SKIPs those specific checks with that reason; MCP is still fully checked.
- **OpenClaw has no fixturable identity source** (no npm package / app
  bundle / VS Code extension hint, only a bare command name on PATH) — its
  wiring tier only runs to completion if a real `openclaw`/`clawdbot` binary
  is actually on PATH on this VM.
- **Windsurf's Devin-first tie-break isn't exercised** by the default
  fixture (it only creates the legacy `Windsurf\User` root) — see
  `test-windsurf.ps1`'s header for how to force the Devin-branded path
  instead.
- Every per-script header cites the exact `agent_configs.rs` /
  `agents/<id>.rs` source the assertions were derived from — if a real
  install disagrees with a check, that's the file to re-read first, since
  the registry is the ground truth this was written against, not this
  script.

## Shared helpers

`common-agents.ps1` — dot-sourced by every script. JSON path traversal
(including dotted-literal keys like `http.proxy`), a minimal TOML table
reader (Codex only — not a general parser), `HKCU:\Environment` /
`profile.ps1` readers for the process-env leg, and the generic
fixture → deploy → wait-for-success → assert → recover driver
(`Invoke-AgentE2E`).
