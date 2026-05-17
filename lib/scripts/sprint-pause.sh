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

# Update state.json: phase=paused, prev_phase=<current>, record pause event
if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq ".phase = \"paused\" | .prev_phase = \"$PREV_PHASE\" | .pause_events += [{at: \"$NOW_ISO\", reason: $(printf '%s' "$REASON" | jq -Rs .), prev_phase: \"$PREV_PHASE\"}]" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
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
