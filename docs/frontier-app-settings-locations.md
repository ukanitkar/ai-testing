# Per-agent settings locations — user vs. admin-managed

For each agent ai-protect currently wires (via `ConfigDelta`/`ManagedEnvVar` —
see [`broker-status-file-schema.md`](broker-status-file-schema.md)), this
doc lists the **user-settings path ai-protect writes today**, and whether a
real **admin-managed** location exists that could carry the same
registration instead — a meaningfully different trust/deployment model
(MDM/GPO-controlled, not the logged-in user's own account) worth moving to
where it's genuinely available.

**Headline finding, read this before the table:** a managed-settings file
existing is not the same question as whether it can carry *what we write*.
Several tools have a real, root-owned managed tier that can only
**allow/deny an MCP server by name or URL** — it cannot **register** one,
which is what our `ConfigDelta` does. Moving to "managed settings" only
helps where the managed schema actually accepts a server registration (or
an `env`/proxy key for the LLM leg), not wherever a managed file exists at
all. The three tiers below are sorted on exactly that distinction.

Sourced from each vendor's own current docs (cited per row); anything not
independently re-verified against a live install is marked accordingly —
this is the same discipline the rest of this integration follows: verify
against current docs, don't carry forward a stale assumption.

## Tier 1 — the managed channel can carry a real MCP/env registration today

| Agent | User path (today) | Managed path | What it can carry |
|---|---|---|---|
| **Claude Code** | `~/.claude.json`, `~/.claude/settings.json` | `managed-mcp.json` at `/Library/Application Support/ClaudeCode/` (macOS), `/etc/claude-code/` (Linux/WSL), `C:\Program Files\ClaudeCode\` (Windows — **not** the legacy `C:\ProgramData\...` path some older references cite) | **Full MCP registration** — same `{"mcpServers": {...}}` schema as the user file. Deploying it gives the admin *exclusive* control (user/project/plugin MCP loads and `claude mcp add` are disabled). `env` is also a real managed-settings.json key — the natural channel for our LLM-leg's `ANTHROPIC_BASE_URL`/CA-path vars too. [docs](https://code.claude.com/docs/en/managed-mcp) |
| **Gemini CLI** | `~/.gemini/settings.json` | `settings.json` under `/etc/gemini-cli/`, `C:\ProgramData\gemini-cli\`, `/Library/Application Support/GeminiCli/` (overridable via `GEMINI_CLI_SYSTEM_SETTINGS_PATH`) | **`mcpServers` is directly settable** at this tier and sits *above* user and workspace settings — merges by name, system definition wins. Our adapter's `proxy` key (the ForwardProxy leg) is unconfirmed at this tier specifically — same settings.json shape, so plausible, not yet verified. [docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/enterprise.md) |
| **Amp** | (per-editor MCP config) | `managed-settings.json` at `/Library/Application Support/ampcode/`, `/etc/ampcode/`, `%ProgramData%\ampcode\` | Can set **`amp.mcpServers`** directly — a real registration channel, not just allow/deny — plus `amp.mcpPermissions`. [announcement](https://ampcode.com/news/enterprise-managed-settings) |
| **OpenAI Codex CLI** | `~/.codex/config.toml` | `requirements.toml` (hard constraints) + `managed_config.toml` (managed defaults) at `/etc/codex/` (macOS/Linux), `%ProgramData%\OpenAI\Codex\` (Windows) | `[mcp_servers]` identity rules are enforceable via `requirements.toml` — described as constraint/enforcement rather than confirmed full free-form registration; verify the exact semantics against a live install before relying on it to *add* a server rather than *constrain* one. [docs](https://learn.chatgpt.com/docs/enterprise/managed-configuration) |
| **OpenCode** | `~/.config/opencode/opencode.json` | `/Library/Application Support/opencode/`, `/etc/opencode/`, `%ProgramData%\opencode\`, plus a macOS MDM domain (`ai.opencode.managed`) | Highest priority, documented as non-overridable. Exact key-level MCP support not itemized in what was checked — verify before relying on it for registration specifically. [docs](https://opencode.ai/docs/config/) |

## Tier 2 — a managed channel exists, but it can only allow/deny, not register

| Agent | User path (today) | Managed path | The gap |
|---|---|---|---|
| **GitHub Copilot** | `~/.copilot` | `managed-settings.json` at `/Library/Application Support/GitHubCopilot/`, `%ProgramFiles%\GitHubCopilot\`, `/etc/github-copilot/` (also MDM/server-managed) | Only `allowedMcpServers`/`deniedMcpServers` (by `serverName`/`serverUrl`/`serverCommand`) — no key to register a new server. [docs](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/manage-agents/configure-enterprise-managed-settings) |
| **VS Code** (Copilot's editor host) | n/a — routed to the `copilot` adapter, VS Code itself is dormant | ADMX/registry/`.mobileconfig`/`/etc/vscode/policy.json`, **fixed allowlist of policies VS Code's own source registers** | `ChatAllowedMcpServers`/`ChatDeniedMcpServers` allow/deny only; **no policy lets an admin force an arbitrary `settings.json` key** (open feature request, [vscode#312764](https://github.com/microsoft/vscode/issues/312764)); no `http.proxy` policy at all. |
| **Cursor** | `~/.cursor/mcp.json` (MCP), `~/.cursor/cli-config.json`-adjacent (LLM leg) | ADMX/`.mobileconfig`/`~/.cursor/policy.json` — only 6 policies, none MCP/model-related | MCP/model control is `~/.cursor/permissions.json` (`mcpAllowlist`) — MDM-*distributable*, but it is still a **user-home file**, the same trust tier as `mcp.json` itself, not a root-owned location. The real org-level control is the cloud **Admin Console** (server-side, no local artifact to target). [docs](https://cursor.com/docs/reference/permissions) |
| **Windsurf / Devin Desktop** | `~/.codeium/windsurf/mcp_config.json` (MCP), its own `settings.json` (LLM leg, `http.proxy`) | Real ADMX/`.mobileconfig`/`/etc/windsurf/policies/policy.json`, rebranded from Windsurf's own, computer-level beats user-level | Documented policies are `AllowedExtensions`, `EnableTelemetry`, `EnableFeedback`, `UpdateMode` only — **no MCP policy at all**. [docs](https://docs.devin.ai/desktop/enterprise-policies) |
| **Kiro** | `~/.kiro/settings/mcp.json` (MCP), its own `settings.json` (LLM leg, `http.proxy`) | Registry/`.mobileconfig`/`/etc/kiro/policy.json` exists but the **only** documented value is `ExtensionGalleryServiceUrl` — no managed settings.json equivalent. | Enterprise MCP/model control is account-level via the Kiro console + IAM Identity Center, and Kiro's own docs concede it's client-enforced and circumventable by a local admin. [docs](https://kiro.dev/docs/enterprise/governance/mcp/) |
| **Antigravity** | `~/.gemini/config/mcp_config.json` | **None found** — enterprise docs cover only Gemini Enterprise licensing/VPC-SC/logging/BYOID, no GPO/registry/plist/ADMX at all | Treat as genuinely absent, not merely undocumented — nothing in Google's own enterprise page for this product resembles a managed-settings file. |

## Tier 3 — no managed tier exists; user settings are the only option

| Agent | Path | Note |
|---|---|---|
| **Devin CLI** | `~/.config/devin/config.json` | An org/enterprise tier is documented at the top of config precedence, but administered entirely in Devin's cloud console — no local system path exists to target. |
| **Zed** | `~/.config/zed/settings.json` | Zed Business's admin controls are server-side org toggles (collaboration, model provider, data controls) enforced through Zed's own infrastructure — not a local settings file. |
| **Aider** | `~/.aider.conf.yml` | No managed tier — user file, repo root, cwd, or `AIDER_*` env vars only. |
| **OpenClaw** | `~/.openclaw/openclaw.json` | No managed tier found; its env vars (`OPENCLAW_CONFIG_PATH`, `OPENCLAW_STATE_DIR`) are for multi-instance isolation, not policy. |
| **Grok** (official Grok Build) | `~/.grok/user-settings.json` (the path our `grok.rs` adapter targets) | A Codex-shaped managed tier exists (`/etc/grok/managed_config.toml` + `requirements.toml`) but MCP support there is not documented — don't assume parity with Codex's `[mcp_servers]` handling without checking. Also worth re-flagging: this session found the *npm package* commonly associated with "Grok CLI" (`@vibe-kit/grok-cli`) is an unrelated third-party tool, not xAI's own — the managed-tier docs cited here are for the official product, `grok`/Grok Build. |
| **Continue** | *(now discontinued — acqui-hired by Anysphere/Cursor June 2026, repo read-only; see the Fork Ledger)* | Not researched — moot given the product's status. |
| **Amazon Q Developer CLI** | *(EOL)* | Out of scope — superseded by Kiro, already covered above. |

## Recommendation

1. **Claude Code, Gemini CLI, Amp** — move both legs (MCP registration and,
   where the leg exists, the LLM redirect / env vars) to the managed
   channel now. This is a straightforward win: real admin-owned files,
   confirmed to accept the actual registration our `ConfigDelta` carries
   today, not just an allow/deny gate.
2. **Codex, OpenCode** — same direction, but verify the exact managed-key
   semantics against a live install first (both describe their managed
   tier in terms suggesting *constraint/defaults* more than *free
   registration* — worth confirming before assuming parity with Claude
   Code's `managed-mcp.json`).
3. **Copilot, VS Code, Cursor, Windsurf/Devin Desktop, Kiro** — do **not**
   move MCP registration to the managed channel; it structurally can't
   carry it (allow/deny only). The user-settings path stays the only real
   registration surface for these five, regardless of deployment
   preference. If reducing user-writable surface area matters here, the
   lever is different: `ChatAllowedMcpServers`-style allowlisting narrows
   what a *user* could add on their own, but doesn't move where *we* write.
4. **Antigravity, Devin CLI, Zed, Aider, OpenClaw, Grok** — no change
   possible; user settings remain the only option for all of these.

None of the managed tiers surveyed — Tier 1 included — were confirmed
against a **live enrolled install** during this pass; this is a docs-only
survey. Before shipping a managed-settings delivery path, validate write
access (these are root/admin-owned locations — ai-protect already runs
privileged, so this is a path change, not a new privilege requirement) and
confirm precedence behavior matches what's documented (e.g. Claude Code's
`managed-mcp.json` disabling *every other* MCP source once present, which
changes what "adding our server" means in practice — it becomes "the only
server," not "one more server").
