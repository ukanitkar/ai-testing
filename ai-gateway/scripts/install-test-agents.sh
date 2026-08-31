#!/usr/bin/env bash
# install-test-agents.sh — install the AI coding agents ai-broker targets, so
# they can be tested end-to-end, then report what ai-broker detects.
#
# ⚠️ RESEARCH VM ONLY. This installs agent CLIs globally, and the point of
# installing them is to run ai-broker's bootstrap / LLM legs against them —
# which REWRITES their configs (MCP entries; gated LLM base-URL / proxy env).
# `--recover` undoes it, but do NOT do this on a daily-driver machine, and never
# against the ~/.claude this terminal session relies on.
#
# Idempotent: re-running is safe. Nothing here mutates agent configs — it only
# installs the agents and runs `ai-broker-mon --agents` (read-only detection).
#
# Usage:
#   ./install-test-agents.sh            # priority set (Claude/Codex/Gemini/Copilot) after a confirm
#   ./install-test-agents.sh -y         # skip the confirm
#   ./install-test-agents.sh --all      # also the lower-priority / gated agents
set -euo pipefail

YES=0
ALL=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    --all) ALL=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1m[install-test-agents]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[install-test-agents] %s\033[0m\n' "$*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "written for macOS; the npm installs work anywhere but the app links are mac."
fi

if [[ "$YES" -ne 1 ]]; then
  cat <<'EOF'
This installs AI coding-agent CLIs GLOBALLY on THIS machine so ai-broker can be
tested against them. Testing then rewrites those agents' configs (recoverable
via `ai-broker-mon --recover`). Use a research VM, not your daily machine.
EOF
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted."; exit 1; }
fi

# ── npm-based CLIs (the priority four's CLI legs) ────────────────────────────
if command -v npm >/dev/null 2>&1; then
  # name → npm package. Copilot's package `@github/copilot` confirmed against
  # docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli. If npm has
  # `ignore-scripts=true`, prefix with `npm_config_ignore_scripts=false`.
  # NOTE: Claude Code (@anthropic-ai/claude-code) is intentionally NOT installed
  # here — this terminal / machine already depends on Claude, and reinstalling or
  # letting ai-broker touch it is exactly what we don't want. Install Claude
  # yourself on a throwaway box if you need to test its legs.
  NPM_AGENTS=(
    # "Claude Code:@anthropic-ai/claude-code"   # excluded on purpose — see note above
    "Codex (ChatGPT):@openai/codex"
    "Gemini CLI:@google/gemini-cli"
    "GitHub Copilot CLI:@github/copilot"
  )
  for entry in "${NPM_AGENTS[@]}"; do
    label="${entry%%:*}"; pkg="${entry##*:}"
    say "installing ${label} (npm i -g ${pkg})"
    npm i -g "$pkg" || warn "${label}: install failed — verify the package name / your npm auth."
  done
else
  warn "npm not found — install Node.js first (brew install node), then re-run."
fi

# ── App-based agents (manual download; can't script a signed .app/.dmg) ──────
say "App-based agents — install by hand, then launch + sign in once so their"
say "config dir is created (that's what ai-broker detects):"
cat <<'EOF'
  Cursor           https://cursor.com                 → ~/.cursor/  (+ its cursor-agent CLI)
  Windsurf         https://windsurf.com               → ~/.codeium/
  (Claude Desktop is intentionally omitted — don't install/retarget Claude on a
   machine you care about; use a throwaway box if you need to test its legs.)
EOF

# ── Lower-priority / gated agents (opt-in) ───────────────────────────────────
if [[ "$ALL" -eq 1 ]]; then
  say "lower-priority / gated agents (best-effort; verify each vendor's install):"
  if command -v brew >/dev/null 2>&1; then
    brew install amazon-q            2>/dev/null || warn "amazon-q: check the current formula/cask name."
    brew install sst/tap/opencode    2>/dev/null || warn "opencode: try 'npm i -g opencode-ai' instead."
  else
    warn "brew not found — skipping amazon-q / opencode."
  fi
  cat <<'EOF'
  Also install by hand if you want them covered (detection dirs in parens):
    Devin CLI     Cognition's installer          (~/.config/devin/)
    Grok CLI      xAI's grok CLI                 (~/.grok/)
    Kiro          AWS Kiro app                   (~/.kiro/)
    Continue      VS Code / JetBrains extension  (~/.continue/)
    Antigravity   Google Antigravity app         (~/.gemini/antigravity*)
EOF
fi

# ── Report what ai-broker detects ────────────────────────────────────────────
say "detection report (installed=true means ai-broker sees the agent's config dir):"
BROKER=""
if command -v ai-broker-mon >/dev/null 2>&1; then
  BROKER="ai-broker-mon"
else
  # Fall back to a build from this repo checkout.
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/../mon/Cargo.toml" ]]; then
    BROKER="cargo run --quiet --manifest-path $here/../mon/Cargo.toml --"
  fi
fi

if [[ -n "$BROKER" ]]; then
  # shellcheck disable=SC2086
  $BROKER --agents || warn "could not run --agents"
else
  warn "ai-broker-mon not on PATH and no local crate found — run \`ai-broker-mon --agents\` yourself."
fi

say "done. Reminder: many agents only create their config dir after you launch"
say "them and sign in once — re-run \`--agents\` after that if one shows installed=false."
