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

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"
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

# Day 1-2 worker integration (plan: ruflo workers → sprint-harness, Q6).
# Fire `ultralearn` (opus) IFF spec flags architecture-heavy work.
# Fire `deepdive` (opus) IFF any AC has complexity keywords. Both write to
# docs/sprints/<slug>/worker-output/ so design.md can reference findings.
PARTIAL="$SPRINT_DIR/spec.partial.json"
if [ -f scripts/lib/worker-trigger.sh ] && [ -f "$PARTIAL" ]; then
  # shellcheck disable=SC1091
  source scripts/lib/worker-trigger.sh
  ARCH_FLAG="$(jq -r '.sections_answers.B.flags.architecture // false' "$PARTIAL" 2>/dev/null)"
  if [ "$ARCH_FLAG" = "true" ]; then
    echo "[+] §B.flags.architecture=true → firing ultralearn worker (opus)"
    trigger_worker ultralearn "$SLUG" 900 || echo "    (ultralearn skipped — advisory)"
  fi
  # Complexity keyword scan in any AC title
  if jq -e '.sections_answers.I.acs // {} | to_entries[] | .value | (.title // "") | test("(auth|RLS|migration|JWT|payment|secret|key|delete)"; "i")' "$PARTIAL" >/dev/null 2>&1; then
    echo "[+] complex AC detected → firing deepdive worker (opus)"
    trigger_worker deepdive "$SLUG" 900 || echo "    (deepdive skipped — advisory)"
  fi
fi

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
BYPASS_NOTE="null"
if [ "${SPRINT_DESIGN_LOCK_BYPASS:-0}" = "1" ]; then
  BYPASS_NOTE="\"SPRINT_DESIGN_LOCK_BYPASS=1\""
fi

# AC-7 (deterministic-phases-v1): record design-lock sub-steps + delegate phase advance.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/sub-step.sh" 2>/dev/null || true
if declare -F record_sub_step >/dev/null 2>&1; then
  record_sub_step "$SLUG" "design-sparc-spec-pseudocode" pass || true
  record_sub_step "$SLUG" "design-sparc-architect" pass || true
  record_sub_step "$SLUG" "design-locked" pass || true
fi
if [ "${SPRINT_DESIGN_LOCK_BYPASS:-0}" = "1" ]; then
  # AC-6 deprecation shim — auto-set SPRINT_BYPASS_GATE + SPRINT_BYPASS_WHY
  export SPRINT_BYPASS_GATE="${SPRINT_BYPASS_GATE:-design-locked}"
  export SPRINT_BYPASS_WHY="${SPRINT_BYPASS_WHY:-legacy-shim-from-SPRINT_DESIGN_LOCK_BYPASS}"
  echo "[!] SPRINT_DESIGN_LOCK_BYPASS=1 is DEPRECATED — migrate to SPRINT_BYPASS_GATE + SPRINT_BYPASS_WHY (removal in v0.8.0)" >&2
fi
if [ -x "$(dirname "$0")/sprint-advance-phase.sh" ]; then
  SPRINT_SLUG_OVERRIDE="$SLUG" bash "$(dirname "$0")/sprint-advance-phase.sh" design-locked 2>&1 || {
    echo "[!] phase advance to design-locked blocked. Manifest predicates not met." >&2
    exit 1
  }
else
  atomic_update_state "$SLUG" ".phase = \"design-locked\" | .gates = ((.gates // []) + [\"design-lock\"]) | .design_locked_at = \"$NOW_ISO\""  # legacy fallback
fi

echo "[✓] $SLUG: phase → design-locked, gates += design-lock"

if [ "$NO_COMMIT" = "false" ]; then
  git add "$STATE_FILE" "$DESIGN_FILE" 2>/dev/null || true
  git commit -m "sprint($SLUG): design-lock" --no-verify 2>/dev/null && echo "[✓] committed" || echo "[!] nothing to commit (or hook deferred — try without --no-verify if drift-check is intended)"
fi
