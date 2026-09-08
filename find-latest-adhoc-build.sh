#!/usr/bin/env bash
# Find the latest ad-hoc [staging] build run for a branch and print its
# databaseId plus a ready-to-run `gh run download` command.
#
# Usage:
#   ./find-latest-adhoc-build.sh [branch] [artifact-name]
#
# Defaults: branch=main-08272026, artifact-name=zscaler-ai-protect-msi-x64
#
# Requires: gh (authenticated), jq.

set -euo pipefail

REPO="SquareX-AI/ai-protect"
BRANCH="${1:-main-08272026}"
ARTIFACT_NAME="${2:-zscaler-ai-protect-msi-x64}"

run_json=$(gh api "repos/${REPO}/actions/runs?branch=${BRANCH}&event=workflow_dispatch&per_page=30" \
  --jq '[.workflow_runs[]
          | select(.display_title | test("\\[staging\\]"))
          | select(.status == "completed" and .conclusion == "success")]
        | sort_by(.created_at)
        | reverse
        | .[0]')

if [[ -z "$run_json" || "$run_json" == "null" ]]; then
  echo "No matching staging run found for branch '${BRANCH}'." >&2
  exit 1
fi

id=$(echo "$run_json" | jq -r '.id')
title=$(echo "$run_json" | jq -r '.display_title')
actor=$(echo "$run_json" | jq -r '.triggering_actor.login')
created=$(echo "$run_json" | jq -r '.created_at')
number=$(echo "$run_json" | jq -r '.run_number')

echo "Latest matching run:"
echo "  Run #${number} (databaseId ${id})"
echo "  Title:   ${title}"
echo "  Actor:   ${actor}"
echo "  Branch:  ${BRANCH}"
echo "  Created: ${created}"
echo
echo "Download command:"
echo "  gh run download ${id} --repo ${REPO} --name ${ARTIFACT_NAME} --dir ~/Downloads"
