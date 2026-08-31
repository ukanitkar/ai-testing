#!/usr/bin/env bash
# Integration test for the file protocol, run as a deployment.
#
# Both processes come up ONCE and stay up for the whole test:
#
#   zax-sim              continuous, playing ai-protect (rescans, rewrites
#                        .broker.zip, watches .status.zip, applies config)
#   zscaler-ai-gateway   service mode, spawned bare by the sim exactly as the
#                        daemon spawns it — unmodified, used as-is
#
# Events are then driven over time and each transition asserted. Nothing is
# restarted between phases, and nothing is injected: every assertion is about
# what the real gateway produced.
#
# Everything is written under target/zax-it/<ts>/, so the real ~/.ai-broker and
# the real agent configs are never touched.
#
# Detection is sandboxed too: both processes run with HOME pointed at a fixture
# tree, so `is_installed()` sees a fixed set of agents rather than whatever
# happens to be on the box. Without that the result varied per machine — and the
# removed-agent check could not work at all on a box with nothing installed.
#
# Usage:
#   ./integration.sh                 offline: steady-state behaviour only
#   ./integration.sh --live          enrol for real (ONE browser sign-in)
#   ./integration.sh --keep-logs     keep the run dir even on a pass
#   ./integration.sh --rescan 5      the simulator's rescan interval (default 3)
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
set +e   # every check reports; the summary decides the exit status

LIVE=0
KEEP_LOGS=0
RESCAN=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live)       LIVE=1 ;;
    --keep-logs)  KEEP_LOGS=1 ;;
    --rescan)     shift; RESCAN="${1:?--rescan needs seconds}" ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_gateway
require_sim

RUN_DIR="$REPO_ROOT/target/zax-it/$(date +%Y%m%d-%H%M%S)"
HOME_DIR="$RUN_DIR/home"
CONFIG="$RUN_DIR/test-config.yaml"
mkdir -p "$HOME_DIR"
LATEST="$REPO_ROOT/target/zax-it/latest"
rm -f "$LATEST" && ln -s "$RUN_DIR" "$LATEST" 2>/dev/null

PASS=0; FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
step() { printf '\n\033[36m── %s\033[0m\n' "$1"; }
naptime() { perl -e "select(undef,undef,undef,$1)"; }

SIM_PID=""
cleanup() {
  [[ -n "$SIM_PID" ]] && kill "$SIM_PID" 2>/dev/null
  pkill -f "zax-sim" 2>/dev/null
  pkill -f "$(basename "$GW")" 2>/dev/null
  if [[ "$FAIL" != "0" || "$KEEP_LOGS" == "1" ]]; then
    printf '\n\033[1mlogs kept:\033[0m %s\n' "$RUN_DIR"
    printf '  simulator : %s\n' "$HOME_DIR/sim.log"
    printf '  gateway   : %s\n' "$HOME_DIR/logs/zax.log"
    printf '  protocol  : %s/.broker.zip .status.zip\n' "$HOME_DIR"
    printf '  latest    : %s\n' "$LATEST"
  else
    rm -rf "$RUN_DIR"; rm -f "$LATEST"
    printf '\nlogs removed (a pass). Re-run with --keep-logs to keep them.\n'
  fi
  ls -1dt "$REPO_ROOT/target/zax-it"/2* 2>/dev/null | tail -n +6 | xargs rm -rf 2>/dev/null
}
trap cleanup EXIT

# Wait for a pattern in the sim log, or time out. $1 pattern, $2 seconds.
await_sim() {
  local ticks=$(( ${2:-20} * 4 ))
  for _ in $(seq 1 "$ticks"); do
    grep -q "$1" "$HOME_DIR/sim.log" 2>/dev/null && return 0
    naptime 0.25
  done
  return 1
}

# How many times a pattern appears in the gateway log. `grep -c` prints 0 and
# exits 1 on no match, so the status is deliberately ignored.
gw_count() {
  local n
  n="$(grep -c "$1" "$HOME_DIR/logs/zax.log" 2>/dev/null)"
  echo "${n:-0}"
}

# Run a command, counting its exit status as one check. An inline `assert` that
# blew up used to print a traceback and leave the summary saying "failed: 0".
check() {
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$what"; else bad "$what"; fi
}

# The status of the command just run, counted. Without it an inline `assert` that
# blew up printed a traceback and left the summary saying "failed: 0".
gate() {
    local rc=$? what="$1"
    if (( rc == 0 )); then pass "$what"; else bad "$what (exit $rc)"; fi
}

# Poll a control file until an agent is gone from it. Polling, not sleeping: the
# rescan probes every agent's version before rewriting, so a fixed nap races it.
await_gone() {  # await_gone <file> <key> <needle> <seconds>
    local f="$1" key="$2" needle="$3" secs="$4" i=0
    while (( i < secs )); do
        if python3 -c "import gzip,json,sys;doc=json.loads(gzip.decompress(open(sys.argv[1],chr(114)+chr(98)).read()));names=[a.get(chr(110)+chr(97)+chr(109)+chr(101),chr(34)+chr(34)) for a in doc.get(sys.argv[2],[])];sys.exit(0 if not any(sys.argv[3].lower() in n.lower() for n in names) else 1)" "$f" "$key" "$needle" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}
await_snapshot_without() { await_gone "$HOME_DIR/.broker.zip" agents "$1" "$2"; }
await_status_without()   { await_gone "$HOME_DIR/.status.zip" agents "$1" "$2"; }

# ── a fixed set of agents, so the run is the same everywhere ───────────────
# Two things make an agent reportable, and the fixture has to supply both:
# `is_installed()` is "does its config dir exist under $HOME", and REGISTER needs
# a version, which the gateway probes from a real file. Config dir alone leaves
# the agent detected-but-withheld.
AGENT_HOME="$RUN_DIR/agents"
mkdir -p "$AGENT_HOME/.codex" "$AGENT_HOME/.gemini" "$AGENT_HOME/.config/devin"
touch "$AGENT_HOME/.claude.json"

# Version sources, all home-relative so no host install is involved.
npm_pkg() {  # npm_pkg <package> <version>
    local d="$AGENT_HOME/.npm-global/lib/node_modules/$1"
    mkdir -p "$d"
    printf '{"name":"%s","version":"%s"}\n' "$1" "$2" > "$d/package.json"
}
npm_pkg "@openai/codex" "0.9.9-fixture"
npm_pkg "@google/gemini-cli" "0.29.0-fixture"

# Devin ships as a VS Code extension; the version is in the directory name.
DEVIN_EXT="$AGENT_HOME/.vscode/extensions/shayanline.devin-vscode-0.11.0"
mkdir -p "$DEVIN_EXT"
printf '{"name":"devin-vscode","version":"0.11.0"}\n' > "$DEVIN_EXT/package.json"

# Claude resolves through an app bundle; ~/Applications is one of the roots.
CLAUDE_APP="$AGENT_HOME/Applications/Claude.app/Contents"
mkdir -p "$CLAUDE_APP/MacOS"
printf 'stub' > "$CLAUDE_APP/MacOS/Claude"
chmod +x "$CLAUDE_APP/MacOS/Claude"
cat > "$CLAUDE_APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Claude</string>
  <key>CFBundleShortVersionString</key><string>1.0.0-fixture</string>
</dict></plist>
PLIST

# Deliberately absent, to prove exclusion works: .cursor .copilot .codeium
PRESENT=(codex claude gemini devin)
ABSENT=(cursor copilot windsurf)

step "fixtures: $((${#PRESENT[@]})) agents present, $((${#ABSENT[@]})) absent"
note "HOME → $AGENT_HOME (present: ${PRESENT[*]} · absent: ${ABSENT[*]})"

# ── the deployment comes up once ───────────────────────────────────────────
step "deploy: one gateway service, one continuous simulator"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../simulator" && pwd)/test-config.yaml"
python3 - "$CONFIG" "$TEMPLATE" <<'PY'
import sys, pathlib
# codex enabled so the apply path has a subject.
s = pathlib.Path(sys.argv[2]).read_text()
s = s.replace("  - name: codex\n    enabled: false", "  - name: codex\n    enabled: true")
pathlib.Path(sys.argv[1]).write_text(s)
PY

SIM_ARGS=(--config "$CONFIG" --home "$HOME_DIR" --spawn --rescan "$RESCAN")
if [[ "$LIVE" == "1" ]]; then
  SIM_ARGS+=(--allow-login)
  warn "--live: one browser sign-in will open. Complete it to let enrolment finish."
fi
# HOME is inherited by the gateway the sim spawns, so both see the fixtures.
HOME="$AGENT_HOME" "$SIM" "${SIM_ARGS[@]}" > "$HOME_DIR/sim.log" 2>&1 &
SIM_PID=$!
note "sim pid $SIM_PID (rescan ${RESCAN}s); the gateway is spawned by it, bare"

FIRST_WAIT=25
[[ "$LIVE" == "1" ]] && FIRST_WAIT=360   # approval polling runs to 300s
if await_sim "← status" "$FIRST_WAIT"; then
  pass "the deployment exchanged a first snapshot and status"
else
  bad "no status within ${FIRST_WAIT}s — see $HOME_DIR/sim.log"
fi

GW_PID="$(pgrep -f "$(basename "$GW")" | head -1)"
[[ -n "$GW_PID" ]] && pass "gateway running as a service (pid $GW_PID)" || bad "no gateway process"

step "1. the protocol: both files present, gzipped, decodable"
python3 - "$HOME_DIR" <<'PY'
import gzip, json, sys, pathlib
h = pathlib.Path(sys.argv[1])
for name in (".broker.zip", ".status.zip"):
    raw = (h / name).read_bytes()
    assert raw[:2] == b"\x1f\x8b", f"{name} is not gzip"
    json.loads(gzip.decompress(raw))
print("  PASS both control files are gzipped JSON")
PY
gate "1. the protocol: both files present, gzipped, decodable"

step "2. detection: exactly the fixture agents reach the snapshot"
PRESENT_CSV="$(IFS=,; echo "${PRESENT[*]}")" ABSENT_CSV="$(IFS=,; echo "${ABSENT[*]}")" \
python3 - "$HOME_DIR" <<'PY'
import gzip, json, os, re, sys, pathlib
h = pathlib.Path(sys.argv[1])
doc = json.loads(gzip.decompress((h / ".broker.zip").read_bytes()))
snapshot = [a["name"] for a in doc["agents"]]
log = re.sub(r"\x1b\[[0-9;]*m", "", (h / "sim.log").read_text(errors="ignore"))
# id → display name, from the sim's own scan report.
seen = dict((i, d) for d, i in re.findall(r"\[zax-sim\] (.+?) \((\w+)\) — ", log))
for want in os.environ["PRESENT_CSV"].split(","):
    disp = seen.get(want)
    assert disp, f"{want} was never scanned"
    assert disp in snapshot, f"{want} has a config dir but is missing from the snapshot"
for nope in os.environ["ABSENT_CSV"].split(","):
    disp = seen.get(nope)
    assert disp, f"{nope} was never scanned"
    assert disp not in snapshot, f"{nope} has no config dir but reached the snapshot"
print(f"  PASS snapshot is exactly the {len(snapshot)} fixture agent(s), absent ones excluded")
PY
gate "2. detection: exactly the fixture agents reach the snapshot"

step "3. steady state: identical rewrites must not churn the gateway"
BEFORE="$(gw_count "enrolment started")"
note "waiting out three rescan ticks"
naptime "$(( RESCAN * 3 + 2 ))"
AFTER="$(gw_count "enrolment started")"
REWRITES="$(grep -c "wrote .*\.broker\.zip" "$HOME_DIR/sim.log" 2>/dev/null)"
REWRITES="${REWRITES:-0}"
note "sim rewrote .broker.zip ${REWRITES}x; gateway enrolment starts: $BEFORE → $AFTER"
if [[ "$REWRITES" -ge 3 ]]; then
  pass "the simulator is continuous (rewrote the snapshot ${REWRITES}x)"
else
  bad "the simulator wrote only ${REWRITES}x — it is not rescanning"
fi
if [[ "$AFTER" == "$BEFORE" ]]; then
  pass "an unchanged snapshot did not re-trigger enrolment (content-hash gate)"
else
  bad "an unchanged snapshot re-triggered enrolment ($BEFORE → $AFTER)"
fi

step "4. a real change: drop a detected agent from the live config"
python3 - "$CONFIG" <<'PY'
import sys, pathlib
# The snapshot is a full list, so absence IS the removal signal.
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("  - name: devin\n    enabled: false\n", ""))
PY
note "removed 'devin' from the config (detected, so it was in the snapshot)"
if await_sim "changed — rescanning" 15; then
  pass "the simulator noticed the config edit"
else
  bad "the config edit was not picked up"
fi
if await_snapshot_without "Devin" 30; then
  pass "devin left the snapshot"
else
  bad "devin is still in the snapshot after 30s"
fi
# devin is off ENABLED_AGENTS, so it was never registered and there is nothing to
# unregister. What must hold is the full-state contract: once it leaves the
# snapshot it stops being listed at all.
if await_status_without "devin" 30; then
  pass "devin left the status document"
else
  bad "devin is still reported in .status.zip after 30s"
fi

step "5. tamper: the service restores the credential store it owns"
if [[ -f "$HOME_DIR/.credentials.zip" ]]; then
  printf 'tampered' > "$HOME_DIR/.credentials.zip"
  naptime 3
  if [[ "$(gw_count "restoring from memory")" != "0" ]]; then
    pass "the gateway restored the store after a foreign write"
  else
    bad "the tamper was not noticed"
  fi
else
  note "no credential store yet — offline, nothing enrols, so there is none to defend"
  pass "skipped: the store only exists once something enrols"
fi

step "6. liveness: nothing died during the run"
kill -0 "$SIM_PID" 2>/dev/null && pass "the simulator is still running" || bad "the simulator died"
kill -0 "$GW_PID"  2>/dev/null && pass "the gateway is still running"   || bad "the gateway died"
LISTENERS="$(lsof -p "$GW_PID" -a -i TCP -sTCP:LISTEN 2>/dev/null | grep -c LISTEN)"
note "gateway listening sockets: ${LISTENERS:-0}"

step "7. the gate: what the gateway actually reported"
LIVE="$LIVE" python3 - "$HOME_DIR" <<'PY'
import gzip, json, os, sys, pathlib
h = pathlib.Path(sys.argv[1])
doc = json.loads(gzip.decompress((h / ".status.zip").read_bytes()))
print(f"  message: {doc['message']}")
for a in doc["agents"]:
    ident = a.get("aid_key", "") or "-"
    print(f"    {a['name']:9} {a['status']:22} deltas={len(a['config'])} aid={ident}")
if os.environ.get("LIVE") == "1":
    served = [a for a in doc["agents"] if a["status"] == "success"]
    assert served, "--live: nothing enrolled — see logs/zax.log"
    for a in served:
        assert a["config"], f"{a['name']} is success but described no config"
        # Registration minted these; ai-protect correlates on them.
        assert a.get("aid_key"), f"{a['name']} is success but reported no aid_key"
        assert a.get("agent_id"), f"{a['name']} is success but reported no agent_id"
    for a in doc["agents"]:
        if a["status"] != "success":
            assert not a.get("aid_key"), f"{a['name']} is {a['status']} but claims an aid_key"
    print(f"  PASS {len(served)} agent(s) enrolled, described their config and their identity")
else:
    for a in doc["agents"]:
        assert not a["config"], f"{a['name']} was wired without enrolling"
        assert a["status"] != "success", f"{a['name']} cannot be success offline"
    print("  PASS no agent was wired without a completed enrolment")
PY
gate "7. the gate: what the gateway actually reported"

step "8. what the simulator applied"
APPLIED="$(sed 's/\x1b\[[0-9;]*m//g' "$HOME_DIR/sim.log" \
  | grep -E "→ (wrote|refused|would write)|is report-only — would write|already current" | head -8)"
if [[ -n "$APPLIED" ]]; then
  printf '%s\n' "$APPLIED" | sed 's/^/    /'
else
  note "nothing applied — no agent reached success, so no delta existed"
fi
WROTE_ANY="$(find "$HOME_DIR" -name 'config.toml' -o -name '.claude.json' 2>/dev/null)"
if [[ "$LIVE" == "1" ]]; then
  [[ -n "$WROTE_ANY" ]] && pass "the gateway's own delta was applied to a real config" \
                        || bad "--live: no config was written"
else
  [[ -z "$WROTE_ANY" ]] && pass "no config written (nothing was serviceable)" \
                        || bad "a config was written with no enrolment"
fi

step "9. clean shutdown: SIGTERM to the sim reaps the gateway it spawned"
kill -TERM "$SIM_PID" 2>/dev/null
for _ in $(seq 1 40); do kill -0 "$SIM_PID" 2>/dev/null || break; naptime 0.25; done
if kill -0 "$SIM_PID" 2>/dev/null; then
  bad "the simulator ignored SIGTERM"; kill -9 "$SIM_PID" 2>/dev/null
else
  pass "the simulator exited on SIGTERM"
fi
for _ in $(seq 1 40); do kill -0 "$GW_PID" 2>/dev/null || break; naptime 0.25; done
if kill -0 "$GW_PID" 2>/dev/null; then
  bad "the gateway outlived the simulator that spawned it (orphaned)"; kill -9 "$GW_PID" 2>/dev/null
else
  pass "the gateway it spawned was reaped"
fi
SIM_PID=""

step "10. the real home and the real agent configs were never touched"
# Both names: the current home, and the pre-rename one in case anything still
# derives it — a write to either is an escape from the run dir.
TOUCHED="$(find "$HOME/.zsai-gateway" "$HOME/.ai-broker" -newer "$CONFIG" -type f 2>/dev/null)"
for real in "$HOME/.claude.json" "$HOME/.codex/config.toml" "$HOME/.gemini/settings.json"; do
  [[ -f "$real" && "$real" -nt "$CONFIG" ]] && TOUCHED="$TOUCHED$real"$'\n'
done
if [[ -z "$TOUCHED" ]]; then
  pass "nothing written under the real home or any real agent config"
else
  printf '%s\n' "$TOUCHED" | sed 's/^/    touched: /'
  bad "something was written outside the run dir"
fi

printf '\n\033[1m%s\033[0m\n' "───────────────────────────────────"
printf 'passed: %s   failed: %s%s\n' "$PASS" "$FAIL" "$([[ "$LIVE" == "1" ]] && echo "   (live)")"
[[ "$FAIL" == "0" ]] || exit 1
