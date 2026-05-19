#!/usr/bin/env bash
# sprint-pre-merge-gate.sh — Pre-push review gate during active sprint.
#
# AC-13 (sprint-system-100, Gap H). Checks that the PR body for the current
# sprint branch has both `reviewer: ✓` and `security: ✓` marks. If missing,
# queues spawn-requests for `reviewer` + `security-architect` agents to a
# `state.pending_review_spawns[]` queue (Claude with MCP drains it).
#
# Mode: warn-first for the first 7 days post-rollout, then escalate to block.
# Override per-push: SPRINT_NO_REVIEW_GATE=1 git push
#
# Usage: bash scripts/sprint-pre-merge-gate.sh [<remote-name>] [<remote-url>]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

# Resolve current branch + active sprint
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"

# No-op when not in sprint branch
if [ -z "$SLUG" ] || [[ "$CURRENT_BRANCH" != sprint/* ]]; then
  exit 0
fi

STATE_FILE="docs/sprints/$SLUG/state.json"

# Per-push override
if [ "${SPRINT_NO_REVIEW_GATE:-0}" = "1" ]; then
  echo "[i] SPRINT_NO_REVIEW_GATE=1 — skipping pre-merge gate (logged)."
  if command -v jq >/dev/null 2>&1 && [ -f "$STATE_FILE" ]; then
    NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    atomic_update_state "$SLUG" --arg at "$NOW_ISO" '.gate_bypasses = ((.gate_bypasses // []) + [{at: $at, gate: "pre-merge-review"}])'
  fi
  exit 0
fi

# ── Look up PR for current branch ──────────────────────────────────────────
PR_BODY=""
PR_NUMBER=""
if command -v gh >/dev/null 2>&1; then
  PR_NUMBER="$(gh pr list --head "$CURRENT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || true)"
  if [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != "null" ]; then
    PR_BODY="$(gh pr view "$PR_NUMBER" --json body --jq '.body' 2>/dev/null || true)"
  fi
fi

# No PR yet → allow (gate doesn't fire pre-PR)
if [ -z "$PR_BODY" ]; then
  echo "[sprint-pre-merge-gate] No open PR for $CURRENT_BRANCH yet — push allowed."
  exit 0
fi

# Check for both marks
HAS_REVIEWER=0
HAS_SECURITY=0
printf '%s' "$PR_BODY" | grep -qE 'reviewer\s*:\s*✓' && HAS_REVIEWER=1
printf '%s' "$PR_BODY" | grep -qE 'security\s*:\s*✓' && HAS_SECURITY=1

if [ "$HAS_REVIEWER" = "1" ] && [ "$HAS_SECURITY" = "1" ]; then
  echo "[sprint-pre-merge-gate] ✓ reviewer + security marks present — push allowed."
  exit 0
fi

# ── Missing marks → queue agent spawn + warn ───────────────────────────────
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
MISSING=""
[ "$HAS_REVIEWER" = "0" ] && MISSING="$MISSING reviewer"
[ "$HAS_SECURITY" = "0" ] && MISSING="$MISSING security-architect"
MISSING="${MISSING# }"

if command -v jq >/dev/null 2>&1 && [ -f "$STATE_FILE" ]; then
  for agent_type in $MISSING; do
    atomic_update_state "$SLUG" --arg at "$NOW_ISO" --argjson pr "$PR_NUMBER" --arg type "$agent_type" '.pending_review_spawns = ((.pending_review_spawns // []) + [{at: $at, pr_number: $pr, agent_type: $type, applied: false}])'
  done
fi

# ── Decide: warn-first vs block ────────────────────────────────────────────
# Grace period: 7 days after this script was created
GRACE_END_EPOCH="$(date -j -f "%Y-%m-%d" "2026-05-24" +%s 2>/dev/null || date -d "2026-05-24" +%s 2>/dev/null || echo 0)"
NOW_EPOCH="$(date +%s)"

cat >&2 <<EOF

╔══════════════════════════════════════════════════════════════════════╗
║  PRE-MERGE REVIEW GATE — missing marks                               ║
╚══════════════════════════════════════════════════════════════════════╝
  PR #$PR_NUMBER on $CURRENT_BRANCH
  Missing marks:$([ "$HAS_REVIEWER" = "0" ] && echo " reviewer: ✓")$([ "$HAS_SECURITY" = "0" ] && echo " security: ✓")

  Queued in state.pending_review_spawns[] — next Claude session with MCP
  will spawn these agents:$( [ "$HAS_REVIEWER" = "0" ] && echo ' reviewer')$( [ "$HAS_SECURITY" = "0" ] && echo ' security-architect')

  Once agents complete, paste their ✓ marks into the PR body, then re-push.
  Override (logged): SPRINT_NO_REVIEW_GATE=1 git push
EOF

# Warn-first vs block decision
if [ "$NOW_EPOCH" -lt "$GRACE_END_EPOCH" ]; then
  echo "" >&2
  echo "  [warn-first mode] Grace period active until 2026-05-24. Push ALLOWED." >&2
  exit 0
else
  echo "" >&2
  echo "  [block mode] Push BLOCKED. Use SPRINT_NO_REVIEW_GATE=1 to override." >&2
  exit 1
fi
