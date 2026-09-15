# "Copilot doesn't work" outside VS Code — findings

Written 2026-09-15, in response to a field report that "the Copilot work we
have done works for VS Code, but not for GitHub app and Copilot app." Short
answer: the report conflates three (really four) distinct surfaces that
share the word "Copilot," only one of which our `ai-gateway` adapter
(`ai-gateway/agent-manager/src/agents/copilot.rs`) ever targeted. This isn't
a regression in existing code — it's a scope question, and one of the two
named apps turns out to need a different *kind* of solution than a config
key we got wrong.

**Update 2026-09-15:** the VS Code Copilot Chat question (row 2 below) is
now resolved — see its own section — leaving the GitHub Copilot app as the
only surface still genuinely open.

## The four surfaces, disambiguated

| Surface | What it actually is | In our adapter's scope today? |
|---|---|---|
| **GitHub Copilot CLI** (`copilot` command, npm `@github/copilot`) | The thing `copilot.rs` was built for | Yes — this is "the Copilot work" that exists |
| **VS Code's built-in Copilot Chat extension** | A separate code path inside VS Code itself | **No, and confirmed correctly so** — `vscode.rs` has `llm: LlmRouting::None`, and the extension itself has no working redirect mechanism to target. See "VS Code's built-in Copilot Chat extension" below |
| **GitHub Copilot app** (`github.com/features/ai/github-app`) | A brand-new, separate desktop application — "the only desktop experience for agent-driven development built natively on GitHub." Not the classic GitHub Desktop git client | No — never targeted. See findings below; bringing it in scope needs new, riskier tooling |
| **Microsoft 365 Copilot app** (`microsoft.com/.../download-copilot-app`) | A completely different Microsoft product (confirmed on Microsoft's own page: *"a completely separate product from GitHub Copilot"*). Talks to Outlook/Word/Excel/PowerPoint, not GitHub's Copilot backend | **Out of scope permanently** — there is no shared backend to intercept. This is a category error, not a gap |

## VS Code's built-in Copilot Chat extension — resolved 2026-09-15

Investigated as the third surface in the table above, since it's the one
most likely to be what the original "works for VS Code" report actually
meant.

**Our own code already treats this as out of scope, and correctly so.**
`ai-gateway/agent-manager/src/agents/vscode.rs` sets `llm: LlmRouting::None`
and the adapter is dormant — `"vscode"` isn't in `ENABLED_AGENTS`. Discovery
maps a `vscode` session to the `copilot` broker identity purely because
"Copilot Chat is the agent behind the editor" (its own doc comment), but
that's identity attribution only: `copilot.rs`'s actual redirect mechanism
writes to `~/.copilot/mcp-config.json` / `~/.copilot/settings.json` — the
standalone CLI's home directory, which the VS Code extension never reads.
`docs/SYSTEM-OVERVIEW.md` already flagged this: "the VS Code Copilot Chat
extension's sessions stay opaque."

**No working interception mechanism exists in the extension itself, either.**
Verified against the extension's own contributed-settings schema and a
maintainer-tracked issue, not guessed:

- `github.copilot.advanced.debug.overrideProxyUrl` / `overrideCapiUrl` are
  real settings, but their documented purpose is overriding the GitHub
  *authentication* proxy, not chat/inference traffic — and a confirmed
  [GitHub issue](https://github.com/microsoft/vscode-copilot-release/issues/7802)
  shows `github.copilot-chat` **ignores them entirely**; only the older,
  separate inline-completion extension (`github.copilot`) honors them.
- VS Code's supported customization path, BYOK (`chatLanguageModels.json`),
  is strictly additive — it registers a new selectable model next to
  Copilot's own in the model picker, requiring manual/pinned selection. It
  cannot redirect or intercept Copilot's own default traffic.
- On this Mac, the extension isn't even installed (`chatLanguageModels.json`
  is `[]`; no `github.copilot-chat` under `~/.vscode/extensions`), consistent
  with nobody having wired a live config surface for it.

A subsequent AI-generated answer (Google AI Mode) claimed a
`github.copilot.advanced.requestHeaders` field and a working
`debug.overrideProxyUrl` redirect for Copilot Chat specifically — checked
against the extension's real schema and found fabricated (`requestHeaders`
isn't a real contributed setting at all) and contradicted by the issue
above. Worth remembering as a caution on trusting AI-search answers for
config specifics, not a new finding about the product itself.

**Conclusion: the field report's "works for VS Code" almost certainly meant
the `copilot` CLI run inside a VS Code integrated terminal** — the one path
our adapter genuinely brokers — not the Copilot Chat extension, which has no
supported or working redirect mechanism today. This closes the open
question below about which surface was originally tested.

**Incidental finding, not a gap:** the separate `continue.dev` VS Code
extension (unrelated to GitHub Copilot, present on this machine) *does*
support a custom proxy endpoint and headers via its `config.json`'s
`apiBase` / `requestOptions.headers` fields — confirmed against Continue's
own docs. Noted only to show the gap is Copilot Chat specifically refusing
this pattern, not that no VS Code extension can support it.

The rest of this doc is about the GitHub Copilot app, since it's the one
remaining case where "we should support this" is a coherent, open ask.

## What was actually found (live install, this Mac, 2026-09-15)

`/Applications/GitHub Copilot.app`, home dir `~/.copilot/` (shared with the
CLI's own home dir name, which is itself a little misleading — see below).

**The files our adapter writes to don't exist on this real, actively-used
install at all:**

```
~/.copilot/
├── config.json              # app-level metadata only (firstLaunchAt, appTipShown, …) — NOT settings.json
├── data.db (+ -shm, -wal)   # SQLite, actively open — this is where real config lives
├── session-store.db
├── repo-metadata-cache.db
├── servers/                 # empty
├── ide/                     # empty
├── installed-plugins/       # empty
└── logs/, run/, session-state/, hooks/, media-cache/
```

No `mcp-config.json`. No `settings.json`. `config.json` only carries UI/app
metadata (`appTipShown`, `reasoningSummariesCleanupDone`, …), nothing
resembling an MCP registry or an LLM redirect.

### The actual config lives in `data.db` (SQLite)

Two tables matter for the LLM leg:

```sql
CREATE TABLE model_providers (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'openai',
    settings_json TEXT NOT NULL DEFAULT '{}',
    account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
    -- + created_at, updated_at
);

CREATE TABLE provider_models (
    id TEXT PRIMARY KEY NOT NULL,
    provider_id TEXT NOT NULL REFERENCES model_providers(id) ON DELETE CASCADE,
    model_id TEXT NOT NULL,
    wire_model TEXT,
    -- + display_name, max_prompt_tokens, max_output_tokens, wire_api_override, …
);
```

The live row, on this install:

```
model_providers:
  id             = github_copilot:eb941f95-68df-4c6a-873d-5a3f4c959166
  name           = GitHub Copilot
  type           = github_copilot
  settings_json  = {"authKind":"none","baseUrl":"","headersJson":"{}","wireApi":"responses"}
  account_id     = eb941f95-68df-4c6a-873d-5a3f4c959166
```

`baseUrl` is the field. It's a JSON key, inside a TEXT column, inside a
SQLite row — not a file our `apply_config_delta`/JSON-merge machinery can
touch. `provider_models` is empty (0 rows) on this install.

**No MCP-server-definition table exists anywhere in the schema.** The only
MCP-adjacent tables are session-scoped event logs
(`session_managed_mcp_event_display_names`, `session_mcp_event_sources`) —
tracking, not configuration. This lines up with a public search finding
(unverified against this app specifically, flagged as such) that MCP config
for GitHub's newer surfaces has moved to a **per-project** file
(`<project>/.copilot/mcp-config.json`), not the per-user-home file our
adapter targets. Not confirmed against this exact app; the app's own
worktree checkouts inspected during this investigation (under
`~/work/zax/copilot-worktrees/`) had no such file, but those may not be
representative of where a real MCP config would land.

### Why this isn't a "wrong path" fix

- **The DB is open and actively written to right now** — two running
  instances of the app on this machine, with the WAL file growing during
  the investigation. Writing into it from outside the app risks corruption,
  or being silently overwritten by the app's own next commit, unless done
  with real SQLite transaction discipline (and ideally the app's own
  cooperation — e.g. writing only while it's confirmed not to be mid-write,
  which nothing in our current tooling attempts).
- **No existing code path fits.** Every adapter in this repo assumes a
  mergeable JSON/TOML *file* (`ConfigDelta` → `config_render` →
  `apply_config_delta`'s file merge). None of that machinery knows how to
  address a database row.
- **No stable, documented schema to build against.** This app is new enough
  that nothing indexed publicly describes `data.db`'s schema. Everything
  above came from inspecting a real, live install directly — the same
  discipline this codebase's own adapters insist on elsewhere (e.g. Devin's,
  Grok's, and Kiro's doc comments all cite "confirmed against a live
  install" or "UNVERIFIED" explicitly) — but it means the schema found here
  could change without notice on the app's next update, with no changelog
  to watch.

## Recommended paths forward

1. **Don't attempt a live-DB write without explicit product sign-off.** The
   corruption/silent-overwrite risk is real and the blast radius is a
   user-facing app's entire local state (sessions, workspaces, worktrees —
   this DB is not a small, single-purpose config file).
2. **If this surface is a real priority, treat it as new product design
   work, not a bugfix.** Two realistic directions:
   - Build careful, transaction-safe SQLite write tooling specifically for
     this app, with the same "narrow trust, confirm against live install,
     never guess a schema" discipline already established elsewhere in this
     codebase — and accept it needs re-validation on every app update until
     GitHub documents the schema (if ever).
   - Wait for/push for the app to expose a supported external configuration
     surface (an env var, a CLI flag, a documented settings file, an IPC
     endpoint) rather than reverse-engineering its private database.
3. **VS Code claim — resolved, no action needed.** Re-verified
   independently (see "VS Code's built-in Copilot Chat extension" above):
   the extension has no working redirect mechanism today, in code or in the
   product itself. "Works for VS Code" almost certainly meant the CLI run
   in an integrated terminal, which is expected, unremarkable, and already
   covered by `copilot.rs`. Writing the relevant settings into
   `settings.json` programmatically is mechanically trivial (same
   JSON-merge pattern every other adapter here already uses) but
   accomplishes nothing, since `github.copilot-chat` ignores the only
   settings that look like a proxy override.
4. **Microsoft 365 Copilot app**: no further action recommended. Flag to
   whoever raised the original report that it's a different product with a
   different backend, not a coverage gap in this adapter.

## Open questions for the team

- Is the GitHub Copilot app actually a stated priority for LLM-traffic
  brokering, given the live-DB risk profile above? If not, this doc is the
  record of why it's out of scope, not a to-do.
- Does GitHub expose (or plan to expose) any supported external
  configuration surface for this app? Worth checking their own repo/issue
  tracker for the app (separate from `github/copilot-cli`) if one exists
  publicly.
- ~~Which exact surface was tested when "Copilot" was reported working for
  VS Code?~~ **Resolved 2026-09-15** — almost certainly the CLI in an
  integrated terminal; the Copilot Chat extension has no interception path
  that could have been "working" in the first place.
