#!/usr/bin/env bash
# Shared environment for the ai-gateway test scripts. Source it; do not run it.
set -euo pipefail

# Repo root is two levels up: ai-gateway/scripts -> ai-gateway -> ai-protect
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export GW="${GW:-$REPO_ROOT/target/debug/zscaler-ai-gateway}"
export SIM="${SIM:-$REPO_ROOT/target/debug/zax-sim}"
export DOCS="$REPO_ROOT/ai-gateway/docs"
export ZAX_LOG="${ZSAI_GATEWAY_HOME:-$HOME/.zsai-gateway}/logs/zax.log"

hr()   { printf '%s\n' "────────────────────────────────────────────────────────────"; }
note() { printf '\033[36m[step]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m %s\n'   "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

require_gateway() {
  [[ -x "$GW" ]] || die "no gateway binary at $GW — run ./build.sh first"
}

require_sim() {
  [[ -x "$SIM" ]] || die "no simulator at $SIM — run ./build.sh first"
}
