#!/usr/bin/env bash
# sprint-checkin.sh — Day-5 mid-cycle check-in (Shape Up hill chart update).
#
# Updates hill-chart.md based on current AC states, writes check-in-day5.md,
# updates state.gates_passed += mid-checkin.
#
# Usage: bash scripts/sprint-checkin.sh [<slug>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint." >&2
  exit 1
fi

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"
HILL_FILE="$SPRINT_DIR/hill-chart.md"
CHECKIN_FILE="$SPRINT_DIR/check-in-day5.md"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Day 5 worker integration (plan: Q10) — fire consolidate worker (local, free)
# to dedup memory entries from waves 1-2 before later waves recall them.
if [ -f scripts/lib/worker-trigger.sh ]; then
  # shellcheck disable=SC1091
  source scripts/lib/worker-trigger.sh
  trigger_worker consolidate "$SLUG" 30 >/dev/null 2>&1 || true
fi

# Refresh hill chart based on current state
node scripts/sprint-hillchart.mjs "$SLUG" --refresh

# Stub check-in file (Claude fills via orchestrator)
cat > "$CHECKIN_FILE" <<MARK
# Day-5 Check-in: $SLUG

Date: $NOW_ISO

## Hill chart snapshot

See \`hill-chart.md\` for the visual.

## Three questions

**1. Which ACs are over the hill (building, moving downhill)?**

_(orchestrator/Claude lists ACs marked downhill or done in state.json)_

**2. Which are stuck under the hill (still figuring out)?**

_(orchestrator/Claude lists ACs marked uphill or stuck)_

**3. Cut, push, or pivot?**

- [ ] **Cut** — drop AC(s): _list_ (run \`bash scripts/sprint-amend-spec.sh --cut AC-X,AC-Y\`)
- [ ] **Push** — keep current scope, accept the appetite cost
- [ ] **Pivot** — change solution shape (run \`bash scripts/sprint-amend-spec.sh --pivot\`)

## Notes

_(any blockers, surprises, course corrections)_
MARK

# Update state
atomic_update_state "$SLUG" ".gates_passed = (.gates_passed + [\"mid-checkin\"] | unique) | .day = 5 | .last_checkin_at = \"$NOW_ISO\""

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Day-5 check-in: $SLUG"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Hill chart: $HILL_FILE"
echo "  Check-in:   $CHECKIN_FILE"
echo ""
echo "  Ask Claude:"
echo "    'walk me through the day-5 check-in for $SLUG'"
echo ""
echo "  Claude will fill the 3 questions based on state.json + ACs, then prompt"
echo "  for your decision (cut/push/pivot)."
echo ""
