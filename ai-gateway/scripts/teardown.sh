#!/usr/bin/env bash
# Teardown. Reverses this product's config edits.
# Surgical: removes only the keys we write, so live state in an agent's config
# (project history, sessions) survives. Exit 1 if anything is left unrepaired, so
# it works as a test gate. Does NOT undo the tenant-side agent registration.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_gateway

note "teardown (--recover)"
hr

# Stop the gateway and any simulator first, so recover sees clean process/port state.
pkill -f zax-sim 2>/dev/null || true
pkill -f zscaler-ai-gateway 2>/dev/null && sleep 1 || true

note "dry-run (what it would do):"
"$GW" --recover --dry-run || true
hr

note "applying recovery:"
if "$GW" --recover; then
  ok "step 5 complete — config restored (exit 0)"
else
  die "recover reported unrepaired items (exit 1) — see output above"
fi
