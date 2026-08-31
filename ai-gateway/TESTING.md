# ai-broker — agent test checklist

How to install each targeted agent and verify each brokering leg against it.
Companion to `docs/ai-broker-work/ai-broker-llm-brokering.md` (LLM design) and
`scripts/install-test-agents.sh` (installer).

> ⚠️ **Research VM only.** Verifying a leg runs `bootstrap` / the proxies, which
> rewrite agent configs (recover with `ai-broker-mon --recover`). Never against
> the `~/.claude` this terminal depends on.

## The loop

```bash
scripts/install-test-agents.sh        # install the priority set
# launch each agent once + sign in     (creates its config dir)
ai-broker-mon --agents                 # confirm installed=true, see per-leg capability
```

`--agents` columns: `enabled` (product allowlist) · `installed` (config dir
exists) · `mcp` / `llm` (base-URL) / `fwd` (forward-proxy) capability.

## What to verify per agent

Legend: **MCP** = broker registered as an MCP server; **LLM-base** = reverse
proxy via a base-URL knob; **LLM-fwd** = forward-proxy (CONNECT MITM).

| Agent | Install | Legs to test | How to verify |
|---|---|---|---|
| **Claude** (Desktop/Code) | npm / download | MCP ✅, LLM-base ✅ (live) | `bootstrap`, then in a new Code session confirm the `zax` MCP tools enumerate; `~/.claude/settings.json` has `ANTHROPIC_BASE_URL` → the proxy; watch `logs/zax.log` for brokered LLM calls |
| **Codex** (=ChatGPT) | `npm i -g @openai/codex` | MCP ✅; **LLM-base (gated)** | MCP: `--agents mcp=true` + entry in `~/.codex/config.toml`. LLM: the one live check — run `configure_llm`, confirm Codex talks to `127.0.0.1:8789` and gets a valid response; if good, flip `supports_llm_base_url=true` in `agents/codex.rs` |
| **Gemini CLI** | `npm i -g @google/gemini-cli` | MCP ✅; **LLM-fwd** | MCP via `~/.gemini/settings.json`. LLM: OAuth path → forward-proxy (see below) |
| **Copilot CLI** | `npm i -g @github/copilot` | MCP ✅; **LLM-fwd** | MCP via `~/.copilot/mcp-config.json`. LLM: forward-proxy (below) |
| **Cursor** | app + `cursor-agent` | MCP ✅; **LLM-fwd** | MCP via `~/.cursor/mcp.json`. LLM: forward-proxy |
| **Windsurf** | app | MCP ✅; **LLM-fwd** | MCP via `~/.codeium/windsurf/mcp_config.json`. LLM: forward-proxy |
| Devin CLI | vendor | MCP ✅; LLM-base (gated, unverified) | MCP via `~/.config/devin/config.json`; Devin honors `ANTHROPIC_BASE_URL`? |
| Grok / Kiro / Amazon Q / Continue / OpenCode / Antigravity | see installer `--all` | MCP only (not enabled) | detection + `configure_mcp` shape only |

## MCP leg (any enabled agent)

```bash
ai-broker-mon                          # bootstrap: registers zax MCP into every enabled+installed agent
ai-broker-mon --agents                 # mcp=true for the four
# open the agent → confirm the `zax` MCP server / tools appear
ai-broker-mon --recover                # undo
```

## LLM base-URL leg (Claude live; Codex gated)

- Claude: bootstrap sets `ANTHROPIC_BASE_URL` → the reverse proxy (port 8788).
- Codex (gated): needs a live check before enabling —
  1. `ai-broker-mon --llm-proxy --upstream https://api.openai.com --port 8789`
  2. Apply Codex's `configure_llm` (writes `[model_providers.zax]` + `model_provider=zax`).
  3. Run Codex; confirm a real completion comes back **through** the proxy
     (`logs/zax.log` shows the forwarded call), and confirm the `wire_api`
     (`responses` vs `chat`) matches Codex's model.
  4. If good → set `supports_llm_base_url=true` in `agents/codex.rs`.

## LLM forward-proxy leg (Copilot / Cursor / Windsurf / Gemini) — e2e-unverified

```bash
ai-broker-mon --llm-forward-proxy      # CONNECT MITM on port 8790; logs the env each agent needs
```

Then launch the agent with the logged env, e.g.:

```bash
HTTPS_PROXY=http://127.0.0.1:8790 \
HTTP_PROXY=http://127.0.0.1:8790 \
NODE_EXTRA_CA_CERTS="$ZAX_DEMO_HOME/mitm-ca/mitm-ca-cert.pem" \
  copilot            # or cursor-agent / windsurf / gemini
```

Verify: the agent's LLM calls succeed (no TLS-trust errors), and `logs/zax.log`
shows the intercepted request forwarded to the gateway. **Open items to expect**
(see the design doc): HTTP/2 (ALPN pins h1 — a client that insists on h2 fails),
and the env-injection apply path for a *user-launched* CLI is unsolved (here you
set the env by hand). Bootstrap does not start this proxy yet.
