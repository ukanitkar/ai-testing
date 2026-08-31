#!/usr/bin/env bash
# Step 1 — Baseline. Writes nothing.
# Proves recovery works BEFORE you need it, and establishes a clean starting point.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_broker

note "1. Baseline — writes nothing (--recover --dry-run)"
hr

"$BROKER" --recover --dry-run

hr
ok "step 1 complete — expect 'Nothing to repair — config is already clean.'"
