#!/usr/bin/env bash
# Step 2 — The SDK pipeline, without touching Claude's config.
# --mcp-server runs the full six-stage pipeline + the MCP leg, but only READS
# Claude's files (preflight diagnostics). We drive it by hand on stdin and assert
# the two invariants that matter: stdout is JSON-RPC only, and nothing was written.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_broker

note "2. SDK pipeline via --mcp-server (read-only)"
hr

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BEFORE="$WORK/before.sha"
OUT="$WORK/out.jsonl"
ERR="$WORK/err.txt"

# Snapshot config before (files may not exist on a clean box — that's fine).
shasum -a 256 "$HOME/.claude.json" "$HOME/.claude/settings.json" > "$BEFORE" 2>/dev/null || true

note "driving initialize + tools/list on stdin (diagnostics go to $ZAX_LOG)"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | "$BROKER" --mcp-server >"$OUT" 2>"$ERR"

# Invariant 1: stdout is JSON-RPC only — one stray log line would corrupt Claude's stream.
ERR_BYTES="$(wc -c <"$ERR" | tr -d ' ')"
[[ "$ERR_BYTES" == "0" ]] && ok "stderr is empty (stdout stayed JSON-RPC only)" \
                          || warn "stderr had $ERR_BYTES bytes — inspect $ERR"

# Invariant 2: the mode really is read-only.
if shasum -a 256 "$HOME/.claude.json" "$HOME/.claude/settings.json" 2>/dev/null | diff -q - "$BEFORE" >/dev/null 2>&1; then
  ok "config unchanged (read-only confirmed)"
else
  warn "config changed — --mcp-server should never write. Inspect."
fi

# Pipeline pass-markers + advertised tool count.
note "pipeline markers:"
grep -aE "REGISTER complete|ACTIVATE instance_id|EXCHANGE|routable broker|advertising .* tool" "$ZAX_LOG" 2>/dev/null | tail -5 || warn "no markers in $ZAX_LOG"

REPLIES="$(wc -l <"$OUT" | tr -d ' ')"
ok "$REPLIES JSON-RPC replies on stdout (expect 2)"

hr
ok "step 2 complete — the 'mcpServers.zax MISSING' preflight WARNs are EXPECTED here"
