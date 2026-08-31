# ai-gateway — agent test checklist

How to install each targeted agent and verify each brokering leg against it, by
hand. The automated protocol test is [`../scripts/integration.sh`](../scripts/integration.sh)
(or `integration.ps1` on Windows) and needs no agent installed.

> ⚠️ **Research VM only.** Verifying a leg runs service mode, which enrols
> against the real control plane and hands ai-protect config deltas for your real
> agent configs (undo with `zscaler-ai-gateway --recover`). Never against the
> `~/.claude` this terminal depends on.

## The loop

```bash
../scripts/integration.sh            # the protocol end to end, no agent needed
# launch each agent once + sign in     (creates its config dir)
zscaler-ai-gateway --agents          # confirm installed=true, see per-leg capability
```

`--agents` columns: `enabled` (the supported list) · `installed` (config dir
exists) · `mcp` / `llm` (base-URL) / `fwd` (forward-proxy) capability.

⚠️ `installed` keys on a config **directory**, which our own hook installer
sometimes creates. An agent can report installed on a machine where it was never
present. A version is what proves it: an agent whose binary cannot be located is
withheld from the snapshot entirely, because REGISTER requires `package.version`.

## What is actually wired

`agents::ENABLED_AGENTS` is the single supported list — **claude, gemini, codex,
copilot**. Anything else in the snapshot is reported `not_supported` and gets no
config, however capable its adapter is. That is the first thing to check when an
agent below "has an adapter" but nothing happens.

| Agent | Install | Supported? | Legs |
|---|---|---|---|
| **Claude** (Desktop/Code) | download | yes | MCP ✅ · LLM-base ✅ live |
| **Codex** (=ChatGPT) | `npm i -g @openai/codex` | yes | MCP ✅ · LLM-base **dark** (`enabled: false`) |
| **Gemini CLI** | `npm i -g @google/gemini-cli` | yes | MCP ✅ · LLM-fwd ✅ (env delivered) |
| **Copilot CLI** | `npm i -g @github/copilot` | yes | MCP ✅ · LLM-fwd ✅ (`proxyUrl`, unverified) |
| Devin CLI | vendor / VS Code ext | **no** | adapter has MCP + LLM-base, unreachable until enabled |
| Cursor | app + `cursor-agent` | **no** | adapter has MCP + LLM-fwd, no env block declared |
| Windsurf | app / VS Code ext | **no** | as Cursor |
| Grok / Kiro / Amazon Q / Continue / OpenCode / Antigravity / Zed / VS Code | — | **no** | detection + delta shape only |

## MCP leg

```bash
zscaler-ai-gateway                   # service mode: enrol, then describe each config in .status.zip
zscaler-ai-gateway --agents          # mcp=true for the supported four
# open the agent → confirm the `zax` MCP server and its tools appear
zscaler-ai-gateway --recover         # undo
```

The gateway never writes an agent's config itself — `.status.zip` carries a
`ConfigDelta` per file and **ai-protect merges it**. So a leg that "does not
apply" may be a delta that was described and never written; read `.status.zip`
before blaming the gateway.

## LLM base-URL leg (Claude live; Codex dark)

The listener is per-agent: `ZAX_LLM_PORT_BASE + slot` (default base 8790), so
there is no single port to check — read the emitted delta or the
`agent{id=…}: [listener] serving https on …` log line for the real one.

- **Claude**: the delta points `env.ANTHROPIC_BASE_URL` at that agent's own
  listener, in `~/.claude/settings.json`.
- **Codex**: the form is written and ready but ships dark — `LlmRouting::BaseUrl
  { enabled: false }` in `agents/codex.rs`. To verify before enabling:
  1. Service mode binds the listener itself; there is no separate proxy mode.
  2. Flip `enabled: true`, run service mode, confirm the delta writes
     `[model_providers.zax]` + `model_provider = "zax"` into `~/.codex/config.toml`.
  3. Run Codex; confirm a real completion comes back **through** the listener
     (the log shows the forwarded call) and that `wire_api` (`responses` vs
     `chat`) matches the active model. Getting this wrong breaks Codex's LLM
     rather than merely failing to broker it — which is why it is dark.

## LLM forward-proxy leg (Gemini only)

There is **no `--llm-forward-proxy` mode** — it was removed with the other
standalone listener modes, and the flag is now rejected. Service mode binds a
per-agent listener that serves the CONNECT and base-URL shapes on one port.

The proxy env is **delivered as config**, not set by hand: for an agent that
declares an `env_file`, `.status.zip` carries it in that agent's own config file
alongside the MCP entry —

```json
"env": {
  "HTTPS_PROXY": "http://127.0.0.1:8792",
  "HTTP_PROXY": "http://127.0.0.1:8792",
  "NODE_EXTRA_CA_CERTS": "…/certs/ca-cert.pem"
}
```

Note the scheme: the listener is `https`, but a CONNECT proxy is addressed over
plain `http`. It is emitted only once a listener is bound and a CA exists.

To verify: run service mode, confirm those keys land in `~/.gemini/settings.json`,
then use the agent and check its calls succeed with no TLS-trust error and the log
shows the intercepted request forwarded.

⚠️ **Unverified against a live agent**: that Gemini CLI honours a top-level `env`
block in `settings.json`. Unlike Copilot's the file is at least the right kind —
the CLI's own settings, not a server registry — but a key it ignores is inert, so
`.status.zip` would report `success` while the traffic went direct. Confirm on a
real install before trusting the status.

**Copilot CLI** is pointed by `proxyUrl` in `~/.copilot/settings.json`, not by an
`env` block — `~/.copilot/mcp-config.json` is a **server registry** (it configures
what Copilot spawns, not how Copilot itself makes egress), so a proxy key there is
never read. `settings.json` carries only `proxyUrl` and the Kerberos SPN, which is
why the CA path cannot ride along with it.

⚠️ Also unverified live. `proxyUrl` is the key the working Python reference writes
(`demo/zscaler-ai-gateway-demo`), so this is not a guess — but Copilot also honours
`HTTPS_PROXY`/`HTTP_PROXY`, and if the key were ever ignored the status would read
`success` while traffic went direct. Confirm the log shows an intercepted request
before trusting it.

`cursor` and `windsurf` still declare no file, so they get no proxy config at all.

**Open items to expect**: HTTP/2 (ALPN pins h1, so a client that insists on h2
fails), and reaching a CLI the user launches themselves for an agent with no env
block at all.

## When an agent sits at `enrolling`

Usually not a device fault. The control plane can hold a registration at
`status="pending_approval"` and the SDK polls for 300 s. Filter the log by agent —
every line carries `agent{id=…}` — and look for the `[onboard] poll #N … status=`
lines. Observed 2026-08-30: `codex` and `gemini` were auto-approved on poll #1
while `claude` stayed pending, so approval coverage is per-subject on the tenant.
