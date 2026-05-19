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

VALIDATE_MODE=false
SLUG=""
for arg in "$@"; do
  case "$arg" in
    --validate) VALIDATE_MODE=true ;;
    *)          SLUG="$arg" ;;
  esac
done
if [ -z "$SLUG" ]; then
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint." >&2
  exit 1
fi

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"
HILL_FILE="$SPRINT_DIR/hill-chart.md"
CHECKIN_FILE="$SPRINT_DIR/check-in-day5.md"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ── AC-11 (deterministic-phases-v1): --validate mode ─────────────────────────
# Checks check-in-day5.md has the 3 sentinel H3 headings (Cut/Push/Pivot)
# with ≥30 chars of content under each. Records sub-steps day-5-question-{cut,push,pivot}.
# Used by sprint-advance-phase.sh's day-5-checkin manifest predicates.
if [ "$VALIDATE_MODE" = true ]; then
  if [ ! -f "$CHECKIN_FILE" ]; then
    echo "[!] check-in-day5.md not found at $CHECKIN_FILE" >&2
    echo "[!] Run 'bash scripts/sprint-checkin.sh $SLUG' first to generate template." >&2
    exit 1
  fi
  fail_count=0
  # shellcheck disable=SC1091
  source "$(dirname "$0")/lib/sub-step.sh" 2>/dev/null || true
  for q in "Cut" "Push" "Pivot"; do
    q_lc=$(echo "$q" | tr 'A-Z' 'a-z')  # bash 3.2 compat (no ${q,,})
    body=$(awk -v h="### $q" '
      NR > 1 && match($0, /^#+/) {
        n = RLENGTH
        if ($0 == h) { found=1; next }
        if (found && n <= 3) exit
      }
      found { print }
    ' "$CHECKIN_FILE")
    # Strip italic-only placeholder lines; require real content.
    # `|| true` handles the case where grep -v matches nothing (empty body) under pipefail.
    real=$(echo "$body" | grep -vE '^[[:space:]]*$|^_[^_]*_[[:space:]]*$' | tr -d '\n' | tr -d ' ' || true)
    if [ "${#real}" -lt 30 ]; then
      echo "[FAIL] day-5-question-$q_lc: '### $q' has ${#real} non-placeholder chars (need ≥30)" >&2
      fail_count=$((fail_count + 1))
    else
      echo "[OK] day-5-question-$q_lc: '### $q' has ${#real} chars" >&2
      if declare -F record_sub_step >/dev/null 2>&1; then
        record_sub_step "$SLUG" "day-5-question-$q_lc" pass "$CHECKIN_FILE" || true
      fi
    fi
  done
  if [ "$fail_count" -gt 0 ]; then
    echo "[SUMMARY] day-5 validate: $fail_count question(s) need ≥30 chars under their H3 heading." >&2
    exit 1
  fi
  echo "[OK] All 3 day-5 questions answered. Sub-steps recorded." >&2
  exit 0
fi

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

### Cut

_drop AC(s): list specific AC IDs and rationale (≥30 chars). Run \`bash scripts/sprint-amend-spec.sh --cut AC-X,AC-Y\` to apply._

### Push

_keep current scope, accept the appetite cost. Write the rationale (≥30 chars)._

### Pivot

_change solution shape. Describe what's pivoting and why (≥30 chars). Run \`bash scripts/sprint-amend-spec.sh --pivot\` after._

## Notes

_(any blockers, surprises, course corrections)_
MARK

# Update state (gates_passed mid-checkin tracker — also sub-step gates)
atomic_update_state "$SLUG" ".day = 5 | .last_checkin_at = \"$NOW_ISO\""

# AC-11 (deterministic-phases-v1): record hill-chart-refreshed sub-step.
# day-5-question-cut/push/pivot sub-steps are recorded by --validate after operator fills the sentinels.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/sub-step.sh" 2>/dev/null || true
if declare -F record_sub_step >/dev/null 2>&1; then
  record_sub_step "$SLUG" "day-5-hill-chart-refreshed" pass "$HILL_FILE" || true
fi

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
