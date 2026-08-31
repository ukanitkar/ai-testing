#!/usr/bin/env bash
# Step 4 — Full bootstrap. THIS ONE EDITS YOUR REAL CLAUDE CONFIG.
# Flips ANTHROPIC_BASE_URL to the local proxy and registers the `zax` MCP server
# in ~/.claude.json, ~/.claude/settings.json and claude_desktop_config.json.
# It then runs sdk_init, launches the LLM proxy, and STREAMS the log until Ctrl-C
# (Ctrl-C stops the stream *and* the proxy). Reverse it with step5-teardown.sh (--recover).
#
# Guarded because it is invasive. Pass --yes to skip the prompt.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_broker

note "4. Full bootstrap — edits your real Claude config"
hr
warn "This writes ANTHROPIC_BASE_URL + the zax MCP registration into your live config."
warn "Backups are written (*.bak.<ts>); reverse with scripts/step5-teardown.sh."

if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "Proceed with the full bootstrap? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted — no changes made"
fi

cat <<'EOF'

After it reports "ready", verify manually (cannot be done headlessly):
  1. In Claude Desktop's Code tab, start a NEW session (each spawns its own bridge).
  2. Check tools appear namespaced  <broker-slug>_<tool>.
  3. Watch the streamed log for       [llm] POST /v1/messages -> 200
Then Ctrl-C to stop, and run scripts/step5-teardown.sh to restore your config.

EOF

exec "$BROKER"
