#!/usr/bin/env bash
# One entry point for a comprehensive ai-gateway test pass on macOS/Linux.
#
# Runs everything that's actually wired up today; clearly reports what it
# skipped so "all green" never quietly means "we didn't check that."
#
# Usage:
#   ./run-all.sh              offline pass (build, baseline, integration, teardown)
#   ./run-all.sh --live       also run integration's --live enrolment pass
#   ./run-all.sh --skip-build skip the cargo build/test/clippy step (faster
#                              re-run once you've already built once)
#
# AI_PROTECT_ROOT can override which ai-protect checkout this targets (see
# ai-gateway/scripts/common.sh) — defaults to the sibling ai-protect checkout
# next to this ai-testing repo.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/ai-gateway/scripts"

LIVE=0
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --live)       LIVE=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done

PASS=0
FAIL=0
SKIP=0
declare -a RESULTS

run_phase() {
  local name="$1"; shift
  echo
  printf '\033[1m════ %s ════\033[0m\n' "$name"
  if "$@"; then
    RESULTS+=("PASS  $name")
    PASS=$((PASS + 1))
  else
    RESULTS+=("FAIL  $name")
    FAIL=$((FAIL + 1))
  fi
}

skip_phase() {
  local name="$1" why="$2"
  printf '\033[33mSKIP\033[0m  %s — %s\n' "$name" "$why"
  RESULTS+=("SKIP  $name — $why")
  SKIP=$((SKIP + 1))
}

# ---- wired up and running today -------------------------------------------
if [[ "$SKIP_BUILD" == "1" ]]; then
  skip_phase "build (cargo build/test/clippy)" "--skip-build passed"
else
  run_phase "build (cargo build/test/clippy)" "$SCRIPTS/build.sh"
fi

run_phase "baseline (detection + --recover --dry-run)" "$SCRIPTS/baseline.sh"
run_phase "integration (offline)" "$SCRIPTS/integration.sh"
if [[ "$LIVE" == "1" ]]; then
  run_phase "integration (--live enrolment)" "$SCRIPTS/integration.sh" --live
else
  skip_phase "integration (--live enrolment)" "pass --live to run it (needs one browser sign-in)"
fi
run_phase "teardown (--recover, config restored)" "$SCRIPTS/teardown.sh"

# ---- not wired up yet — real coverage gaps, not oversights -----------------
# See ai-testing/README.md and the "historical" scripts this repo already
# recovered for what these need to be ported FROM. Each of these was real
# coverage in the old Windows E2E suite; none of them has a working
# replacement yet.
skip_phase "MCP leg (--bridge <agent> stdio relay)" \
  "TODO: port commands/phase-c-mcp-stdio.ps1 / ai-gateway/scripts/step2-mcp-pipeline.sh to the new --bridge flag"
skip_phase "TLS + per-install-token gate on the LLM proxy" \
  "TODO: needs a harness against a live --service instance's proxy port (no more standalone --llm-proxy)"
skip_phase "protocol schema-version mismatch (negative case)" \
  "TODO: port commands/phase-c-protocol-mismatch.ps1 to .broker.zip's gzipped schema_ver field"
skip_phase "config-delta allowlist defense (negative case)" \
  "TODO: port commands/phase-b-config-apply.ps1's negative half to the new AgentStatus.config shape"
skip_phase "secure_file ACL-at-rest spot check" \
  "TODO: port commands/phase-a-acl.ps1 to ~/.zsai-gateway's current file names (.credentials.zip, etc.)"
skip_phase "--recover self-heal-gap timing" \
  "TODO: verify ai-gateway/scripts/dev_device_plane.py still matches the daemon's settings-frame mechanism, then port commands/phase-d-recover.ps1's timing assertion"
skip_phase "Windows privilege-drop / SYSTEM-service boundary" \
  "TODO: needs the Windows laptop + VM — see commands/run-e2e-suite.ps1 (historical, needs porting to the new binary/protocol) for what this covered"

# ---- summary ----------------------------------------------------------------
echo
printf '\033[1m════ summary ════\033[0m\n'
for r in "${RESULTS[@]}"; do
  case "$r" in
    PASS*) printf '\033[32m%s\033[0m\n' "$r" ;;
    FAIL*) printf '\033[31m%s\033[0m\n' "$r" ;;
    SKIP*) printf '\033[33m%s\033[0m\n' "$r" ;;
  esac
done
echo
echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"
[[ "$FAIL" == "0" ]]
