#!/usr/bin/env bash
# Baseline. Writes nothing: proves recovery works before you need it, and shows
# what the gateway detects on this machine.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_gateway

note "agents this machine has"
hr
"$GW" --agents

note "recovery dry run"
hr
"$GW" --recover --dry-run

hr
ok "baseline clean — expect 'Nothing to repair'"
