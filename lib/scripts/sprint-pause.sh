#!/usr/bin/env bash
# sprint-pause.sh — Pause the active sprint.
#
# Disables drift-prone daemon workers (refactor, document) — they would
# propose mid-sprint changes that could drift from spec. Snapshots state.
# Records pause event for retro analysis.
#
# Usage:
#   bash scripts/sprint-pause.sh [reason]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

REASON="${1:-(no reason given)}"
SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"

if [ -z "$SLUG" ]; then
  echo "[!] No active sprint." >&2
  exit 1
fi

STATE_FILE="docs/sprints/$SLUG/state.json"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Read current phase (so resume can return to it)
PREV_PHASE="$(grep -o '"phase":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"

if [ "$PREV_PHASE" = "paused" ]; then
  echo "[i] Sprint $SLUG is already paused."
  exit 0
fi

# Update state.json: prev_phase + pause_events, then delegate phase=paused to advance-phase.sh.
# AC-7 (deterministic-phases-v1): pause has empty required artifacts per manifest, so the
# advance always succeeds. prev_phase is written first so resume can restore.
if command -v jq >/dev/null 2>&1; then
  REASON_JSON="$(printf '%s' "$REASON" | jq -Rs .)"
  atomic_update_state "$SLUG" --arg pp "$PREV_PHASE" --arg at "$NOW_ISO" --argjson reason "$REASON_JSON" \
    '.prev_phase = $pp | .pause_events += [{at: $at, reason: $reason, prev_phase: $pp}]'
  if [ -x "$(dirname "$0")/sprint-advance-phase.sh" ]; then
    SPRINT_SLUG_OVERRIDE="$SLUG" bash "$(dirname "$0")/sprint-advance-phase.sh" paused 2>&1 || {
      echo "[!] phase advance to paused blocked. Falling back to direct write." >&2
      atomic_update_state "$SLUG" '.phase = "paused"'  # legacy fallback (pause requires no predicates)
    }
  else
    atomic_update_state "$SLUG" '.phase = "paused"'  # legacy fallback
  fi
else
  echo "[!] jq not available — state.json update may be partial" >&2
fi

# Disable drift-prone daemon workers
if command -v ruflo >/dev/null 2>&1; then
  ruflo daemon enable -w refactor false >/dev/null 2>&1 || \
    ruflo daemon disable -w refactor >/dev/null 2>&1 || true
  ruflo daemon enable -w document false >/dev/null 2>&1 || \
    ruflo daemon disable -w document >/dev/null 2>&1 || true
  echo "[+] Disabled daemon workers: refactor, document"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Sprint paused: $SLUG"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Reason:      $REASON"
echo "  Prev phase:  $PREV_PHASE"
echo "  Drift checks SUSPENDED until resume."
echo ""
echo "  Resume:      bash scripts/sprint-resume.sh"
echo ""
