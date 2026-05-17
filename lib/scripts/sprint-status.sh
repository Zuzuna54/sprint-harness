#!/usr/bin/env bash
# sprint-status.sh — Print current sprint state.
#
# Resolution order (branch-aware for parallel sprints in one workdir, 2026-05-17):
#   1. --slug <name>            — explicit override
#   2. $SPRINT_SLUG_OVERRIDE     — env var override
#   3. Current git branch matches `sprint/<slug>` pattern → use <slug>
#   4. Fallback: most-recently-modified non-done sprint
#   5. --list mode shows ALL active sprints
#
# Usage:
#   bash scripts/sprint-status.sh                 # full status (current branch)
#   bash scripts/sprint-status.sh --slug-only     # just the active slug
#   bash scripts/sprint-status.sh --slug <name>   # status for specific sprint
#   bash scripts/sprint-status.sh --list          # all active sprints in workdir
#   bash scripts/sprint-status.sh --json          # raw state.json

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG_ONLY=false
JSON_OUT=false
LIST_MODE=false
EXPLICIT_SLUG=""
i=0
for arg in "$@"; do
  case "$arg" in
    --slug-only) SLUG_ONLY=true ;;
    --json) JSON_OUT=true ;;
    --list) LIST_MODE=true ;;
    --slug)
      # Next arg is the slug
      shift_to=$((i+2))
      EXPLICIT_SLUG="${!shift_to:-}"
      ;;
  esac
  i=$((i+1))
done

# Helper: phase of a sprint dir
phase_of() {
  grep -o '"phase":[[:space:]]*"[^"]*"' "$1" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# --list mode: enumerate all non-done sprints
if [ "$LIST_MODE" = true ]; then
  for d in docs/sprints/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "_template" ] && continue
    STATE="$d/state.json"
    [ -f "$STATE" ] || continue
    PHASE="$(phase_of "$STATE")"
    [ "$PHASE" = "done" ] && continue
    BRANCH="$(grep -o '"git_branch":[[:space:]]*"[^"]*"' "$STATE" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    printf "  %s\tphase=%s\tbranch=%s\n" "$(basename "$d")" "$PHASE" "${BRANCH:-?}"
  done
  exit 0
fi

# Resolution chain
ACTIVE=""

# 1. Explicit --slug
if [ -n "$EXPLICIT_SLUG" ] && [ -d "docs/sprints/$EXPLICIT_SLUG" ]; then
  ACTIVE="$EXPLICIT_SLUG"
fi

# 2. SPRINT_SLUG_OVERRIDE env var
if [ -z "$ACTIVE" ] && [ -n "${SPRINT_SLUG_OVERRIDE:-}" ] && [ -d "docs/sprints/$SPRINT_SLUG_OVERRIDE" ]; then
  ACTIVE="$SPRINT_SLUG_OVERRIDE"
fi

# 3. Current git branch (sprint/<slug>)
if [ -z "$ACTIVE" ]; then
  BRANCH_NOW="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
  if [[ "$BRANCH_NOW" =~ ^sprint/(.+)$ ]]; then
    CANDIDATE="${BASH_REMATCH[1]}"
    if [ -d "docs/sprints/$CANDIDATE" ]; then
      STATE="docs/sprints/$CANDIDATE/state.json"
      if [ -f "$STATE" ] && [ "$(phase_of "$STATE")" != "done" ]; then
        ACTIVE="$CANDIDATE"
      fi
    fi
  fi
fi

# 4. Fallback: most-recently-modified non-done sprint
if [ -z "$ACTIVE" ]; then
  LATEST_MTIME=0
  for d in docs/sprints/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "_template" ] && continue
    STATE="$d/state.json"
    [ -f "$STATE" ] || continue
    PHASE="$(phase_of "$STATE")"
    [ "$PHASE" = "done" ] && continue
    MTIME="$(stat -f %m "$STATE" 2>/dev/null || stat -c %Y "$STATE" 2>/dev/null || echo 0)"
    if [ "$MTIME" -gt "$LATEST_MTIME" ]; then
      LATEST_MTIME="$MTIME"
      ACTIVE="$(basename "$d")"
    fi
  done
fi

if [ -z "$ACTIVE" ]; then
  if [ "$SLUG_ONLY" = true ]; then
    exit 0
  fi
  echo "No active sprint."
  echo ""
  echo "To start: bash scripts/sprint-start.sh <slug>"
  exit 0
fi

if [ "$SLUG_ONLY" = true ]; then
  echo "$ACTIVE"
  exit 0
fi

STATE_FILE="docs/sprints/$ACTIVE/state.json"

if [ "$JSON_OUT" = true ]; then
  cat "$STATE_FILE"
  exit 0
fi

# Pretty-print
PHASE="$(grep -o '"phase":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
STARTED="$(grep -o '"started_at":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
DAY="$(grep -o '"day":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$')"
APPETITE="$(grep -o '"appetite_days":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$')"
DRIFT="$(grep -o '"drift_score_latest":[[:space:]]*[^,}]*' "$STATE_FILE" | head -1 | sed 's/.*:[[:space:]]*//')"
BRANCH="$(grep -o '"git_branch":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
GATES="$(node -e "try{const s=JSON.parse(require('fs').readFileSync('$STATE_FILE','utf8'));process.stdout.write((s.gates_passed||[]).map(g=>'\"'+g+'\"').join(', '));}catch{process.stdout.write('');}" 2>/dev/null || echo '')"
WIZARD_SECTION="$(grep -o '"current_section":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"

echo "╔══════════════════════════════════════════════════════════════════════╗"
printf "║  Sprint: %-60s ║\n" "$ACTIVE"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
printf "  Phase:      %s\n" "${PHASE:-unknown}"
printf "  Day:        %s of %s\n" "${DAY:-0}" "${APPETITE:-14}"
printf "  Started:    %s\n" "${STARTED:-?}"
printf "  Branch:     %s\n" "${BRANCH:-?}"
printf "  Drift:      %s\n" "${DRIFT:-N/A}"
printf "  Gates:      %s\n" "${GATES:-(none)}"
if [ "$PHASE" = "spec-wizard" ]; then
  printf "  Wizard at:  §%s\n" "${WIZARD_SECTION:-?}"
fi
echo ""

# ── AC-3 (sprint-system-100, Gap I): time-box check ─────────────────────────
# Warn if elapsed time exceeds appetite by 10% or more. Per Shape Up: at this
# point you should CUT scope, not extend appetite.
APPETITE_SEC="$(grep -o '"appetite_seconds":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$' || echo 0)"
STARTED_EPOCH="$(grep -o '"started_at_epoch":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$' || echo 0)"
if [ "$APPETITE_SEC" -gt 0 ] && [ -n "$STARTED_EPOCH" ] && [ "$STARTED_EPOCH" != "0" ]; then
  NOW_EPOCH="$(date +%s)"
  ELAPSED_SEC=$((NOW_EPOCH - STARTED_EPOCH))
  THRESHOLD=$((APPETITE_SEC * 110 / 100))
  if [ "$ELAPSED_SEC" -gt "$THRESHOLD" ]; then
    OVER_HOURS=$(((ELAPSED_SEC - APPETITE_SEC) / 3600))
    PCT=$((ELAPSED_SEC * 100 / APPETITE_SEC))
    echo "  ⚠️  TIME-BOX EXCEEDED: ${PCT}% of appetite (${OVER_HOURS}h over)"
    echo ""
    echo "    Shape Up says: CUT SCOPE, do not extend appetite."
    echo "    Options:"
    echo "      (a) Cut scope: bash scripts/sprint-amend-spec.sh --cut <AC-N,AC-M>"
    echo "      (b) Extend appetite (logged in retro): edit state.json.appetite_days"
    echo "      (c) Abort sprint: bash scripts/sprint-end.sh $ACTIVE --skip-patterns"
    echo ""
  fi
fi

echo "  State file: $STATE_FILE"
echo "  Sprint dir: docs/sprints/$ACTIVE/"
echo ""
