#!/usr/bin/env bash
# Build and test the workspace. Writes nothing outside target/.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

note "build + test + clippy (workspace)"
note "repo: $REPO_ROOT"
hr

cd "$REPO_ROOT"
cargo build  --workspace
cargo test   --workspace
cargo clippy --workspace --all-targets

hr
ok "build, tests and clippy passed"
