#!/usr/bin/env bash
# sprint-resume.sh — Resume a paused sprint.
#
# Restores phase from state.prev_phase, re-enables paused daemon workers,
# records the resume event.
#
# Usage:
#   bash scripts/sprint-resume.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
if [ -z "$SLUG" ]; then
  echo "[!] No paused sprint detected." >&2
  exit 1
fi

STATE_FILE="docs/sprints/$SLUG/state.json"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CUR_PHASE="$(grep -o '"phase":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
PREV_PHASE="$(grep -o '"prev_phase":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || echo "spec-wizard")"

if [ "$CUR_PHASE" != "paused" ]; then
  echo "[i] Sprint $SLUG is not paused (phase=$CUR_PHASE). Nothing to resume."
  exit 0
fi

# Restore phase
atomic_update_state "$SLUG" ".phase = \"$PREV_PHASE\" | .pause_events |= (.[:-1] + [(.[-1] // {}) | . + {resumed_at: \"$NOW_ISO\"}])"

# Re-enable workers (best-effort)
if command -v ruflo >/dev/null 2>&1; then
  ruflo daemon enable -w refactor >/dev/null 2>&1 || true
  ruflo daemon enable -w document >/dev/null 2>&1 || true
  echo "[+] Re-enabled daemon workers: refactor, document"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Sprint resumed: $SLUG"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Phase: $PREV_PHASE"
echo ""
echo "  Status: bash scripts/sprint-status.sh"
echo ""
