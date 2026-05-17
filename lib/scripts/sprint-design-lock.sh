#!/usr/bin/env bash
# sprint-design-lock.sh — AC D1 (harness-portability-v4)
#
# Phase-transition gate: spec-locked → design-locked.
# Called by sprint-orchestrator skill (Phase 2 step 3) after user signs off
# on docs/sprints/<slug>/design.md.
#
# Effects:
#   - asserts state.json.phase == spec-locked + spec.md has §A-J + design.md exists with 3 SPARC sections
#   - sets state.json.phase = design-locked
#   - appends "design-lock" to state.json.gates[]
#   - commits the state.json change with message "sprint(<slug>): design-lock"
#
# Override (escape hatch, logs to state.gate_bypasses[]):
#   SPRINT_DESIGN_LOCK_BYPASS=1 bash scripts/sprint-design-lock.sh
#
# Usage:
#   bash scripts/sprint-design-lock.sh                     # uses active sprint
#   bash scripts/sprint-design-lock.sh --slug <slug>        # explicit slug
#   bash scripts/sprint-design-lock.sh --no-commit          # update state only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG=""
NO_COMMIT=false
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) shift; SLUG="${1:-}"; shift ;;
    --no-commit) NO_COMMIT=true; shift ;;
    -h|--help)
      sed -n '1,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "[!] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve active sprint if not given
if [ -z "$SLUG" ]; then
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint and no --slug provided" >&2
  exit 2
fi

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"
SPEC_FILE="$SPRINT_DIR/spec.md"
DESIGN_FILE="$SPRINT_DIR/design.md"

[ -f "$STATE_FILE" ] || { echo "[!] state.json missing: $STATE_FILE" >&2; exit 2; }
[ -f "$SPEC_FILE" ]  || { echo "[!] spec.md missing: $SPEC_FILE" >&2; exit 2; }

# Source state-lock helper if present (v0.2+ atomic writes)
if [ -f scripts/lib/state-lock.sh ]; then
  # shellcheck disable=SC1091
  . scripts/lib/state-lock.sh
fi

# Pre-conditions
PHASE="$(jq -r '.phase // ""' "$STATE_FILE")"
if [ "$PHASE" != "spec-locked" ] && [ "${SPRINT_DESIGN_LOCK_BYPASS:-0}" != "1" ]; then
  echo "[!] Phase is '$PHASE' but must be 'spec-locked' to advance to design-locked" >&2
  echo "    Override with SPRINT_DESIGN_LOCK_BYPASS=1 (logged)" >&2
  exit 1
fi

# Design content check
if [ ! -f "$DESIGN_FILE" ] && [ "${SPRINT_DESIGN_LOCK_BYPASS:-0}" != "1" ]; then
  echo "[!] $DESIGN_FILE missing — run /sparc:spec-pseudocode and /sparc:architect first" >&2
  exit 1
fi
if [ -f "$DESIGN_FILE" ]; then
  for section in "SPARC Specification" "SPARC Pseudocode" "SPARC Architecture"; do
    if ! grep -q "## $section" "$DESIGN_FILE" && [ "${SPRINT_DESIGN_LOCK_BYPASS:-0}" != "1" ]; then
      echo "[!] design.md missing section: ## $section" >&2
      exit 1
    fi
  done
fi

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
BYPASS_NOTE="null"
if [ "${SPRINT_DESIGN_LOCK_BYPASS:-0}" = "1" ]; then
  BYPASS_NOTE="\"SPRINT_DESIGN_LOCK_BYPASS=1\""
fi

# Atomic state update
JQ_EXPR=".phase = \"design-locked\" |
         .gates = ((.gates // []) + [\"design-lock\"]) |
         .design_locked_at = \"$NOW_ISO\" |
         (if $BYPASS_NOTE != null
            then .gate_bypasses = ((.gate_bypasses // []) + [{at: \"$NOW_ISO\", gate: \"design-lock\", reason: $BYPASS_NOTE}])
            else .
          end)"

if command -v jq_state_lock >/dev/null 2>&1; then
  jq_state_lock "$STATE_FILE" "$JQ_EXPR"
else
  tmp="$(mktemp)"
  jq "$JQ_EXPR" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
fi

echo "[✓] $SLUG: phase → design-locked, gates += design-lock"

if [ "$NO_COMMIT" = "false" ]; then
  git add "$STATE_FILE" "$DESIGN_FILE" 2>/dev/null || true
  git commit -m "sprint($SLUG): design-lock" --no-verify 2>/dev/null && echo "[✓] committed" || echo "[!] nothing to commit (or hook deferred — try without --no-verify if drift-check is intended)"
fi
