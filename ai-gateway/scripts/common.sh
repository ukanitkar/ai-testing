#!/usr/bin/env bash
# Shared environment for the ai-gateway test scripts. Source it; do not run it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the ai-protect checkout these scripts actually build/test against.
# Three cases, checked in order:
#   1. AI_PROTECT_ROOT set explicitly -- always wins, e.g. a laptop where
#      ai-protect and ai-testing aren't laid out as siblings.
#   2. Running from a REAL ai-protect checkout (this script's own canonical
#      home, ai-protect/ai-gateway/scripts/) -- two levels up is the repo
#      root; confirmed by finding the ai-warden package there, not just any
#      Cargo.toml.
#   3. Running from the ai-testing mirror (ai-testing/ai-gateway/scripts/) --
#      ai-testing and ai-protect are siblings under .../integration/, so go
#      up to that shared parent and across.
if [[ -n "${AI_PROTECT_ROOT:-}" ]]; then
  REPO_ROOT="$AI_PROTECT_ROOT"
elif [[ -f "$SCRIPT_DIR/../../Cargo.toml" ]] && grep -q '^name = "ai-warden"' "$SCRIPT_DIR/../../Cargo.toml" 2>/dev/null; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../../ai-protect" && pwd)"
fi
[[ -f "$REPO_ROOT/Cargo.toml" ]] || {
  echo "[fail] no ai-protect checkout found at $REPO_ROOT -- set AI_PROTECT_ROOT to override" >&2
  exit 1
}
export REPO_ROOT

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
