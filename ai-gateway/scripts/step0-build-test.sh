#!/usr/bin/env bash
# Step 0 — Build and unit tests.
# Non-invasive. Builds the mono-exe and runs the crate's unit + doc tests + clippy.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

note "0. Build and unit tests"
hr

note "cargo build -p ai-broker-mon"
cargo build  -p ai-broker-mon

note "cargo test -p ai-broker-mon -p ai-broker-sdk"
cargo test   -p ai-broker-mon -p ai-broker-sdk

note "cargo clippy -p ai-broker-mon -p ai-broker-sdk --all-targets"
cargo clippy -p ai-broker-mon -p ai-broker-sdk --all-targets

hr
ok "step 0 complete — build + tests + clippy passed"
