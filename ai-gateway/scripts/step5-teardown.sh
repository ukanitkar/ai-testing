#!/usr/bin/env bash
# Step 5 — Teardown. Reverses the config edits step 4 makes.
# Surgical by default: removes only the keys the bootstrap writes; live state in
# ~/.claude.json (project history, sessions) survives. Exit 1 if anything was left
# unrepaired (so it works as a test-teardown gate). Does NOT undo the tenant-side
# agent registration — that is server-side.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_broker

note "5. Teardown (--recover)"
hr

# Stop any running broker/proxy first so recover sees a clean process/port state.
pkill -f ai-broker-mon 2>/dev/null && sleep 1 || true

note "dry-run (what it would do):"
"$BROKER" --recover --dry-run || true
hr

note "applying recovery:"
if "$BROKER" --recover; then
  ok "step 5 complete — config restored (exit 0)"
else
  die "recover reported unrepaired items (exit 1) — see output above"
fi
