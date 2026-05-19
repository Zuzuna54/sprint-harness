#!/usr/bin/env bash
# sprint-cleanup-launch.sh — Trigger the cleanup workflow.
#
# AC-24 (sprint-system-100). Day 11-12 of sprint, after verify completes
# and before deploy starts. Invokes docs/workflows/lifeos-sprint-cleanup.yaml.
#
# Usage: bash scripts/sprint-cleanup-launch.sh [<slug>] [--commit-deadcode]

set -uo pipefail

# Fail-fast: state-mutating cleanup script must not silent-continue mid-flight.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint."
  exit 1
fi

COMMIT_DEADCODE=false
for arg in "$@"; do
  [ "$arg" = "--commit-deadcode" ] && COMMIT_DEADCODE=true
done

echo "═══ Sprint cleanup launch: $SLUG ═══"
echo ""

# Day 11 worker integration (plan: ruflo workers → sprint-harness, refactor row).
# Fire `refactor` worker IFF spec title or §A mentions "refactor". Output to
# docs/sprints/<slug>/worker-output/refactor.md. Advisory only.
SPEC_FILE="docs/sprints/$SLUG/spec.md"
if [ -f "$SPEC_FILE" ] && [ -f scripts/lib/worker-trigger.sh ]; then
  if grep -qiE "refactor" "$SPEC_FILE" 2>/dev/null; then
    # shellcheck disable=SC1091
    source scripts/lib/worker-trigger.sh
    echo "[+] spec mentions refactor → firing refactor worker (sonnet, advisory)"
    trigger_worker refactor "$SLUG" 600 || echo "    (refactor skipped — advisory)"
  fi
fi

# If ruflo can run workflows, delegate. Else, run steps inline.
if command -v ruflo >/dev/null 2>&1 && ruflo workflow --help >/dev/null 2>&1; then
  echo "[+] Delegating to ruflo workflow execute lifeos-sprint-cleanup"
  if [ "$COMMIT_DEADCODE" = true ]; then
    SPRINT_DEADCODE_COMMIT=1 ruflo workflow run lifeos-sprint-cleanup --input slug="$SLUG" 2>&1 | tail -30
  else
    ruflo workflow run lifeos-sprint-cleanup --input slug="$SLUG" 2>&1 | tail -30
  fi
  exit $?
fi

# Fallback: inline execution
echo "[i] ruflo workflow not available — running steps inline"
echo ""

STATE_FILE="docs/sprints/$SLUG/state.json"
PHASE=$(grep -o '"phase":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
if [ "$PHASE" != "pre-deploy" ] && [ "$PHASE" != "cleaning" ]; then
  echo "[!] Expected phase=pre-deploy or cleaning; got $PHASE"
  echo "    Verify workflow should have run first."
  exit 1
fi

# AC-7 (deterministic-phases-v1): delegate cleaning phase entry to advance-phase.sh
if [ -x "$(dirname "$0")/sprint-advance-phase.sh" ]; then
  SPRINT_SLUG_OVERRIDE="$SLUG" bash "$(dirname "$0")/sprint-advance-phase.sh" cleaning 2>&1 || {
    echo "[i] phase advance to cleaning deferred (manifest predicates)." >&2
  }
else
  atomic_update_state "$SLUG" '.phase = "cleaning"'  # legacy fallback
fi
echo "[+] phase → cleaning"

# Deadcode (dry-run unless flag)
if [ -x scripts/sprint-deadcode-delete.mjs ]; then
  echo ""
  echo "── Deadcode delete ──"
  if [ "$COMMIT_DEADCODE" = true ]; then
    node scripts/sprint-deadcode-delete.mjs "$SLUG" --commit 2>&1 | tail -15
  else
    node scripts/sprint-deadcode-delete.mjs "$SLUG" 2>&1 | tail -15
  fi
fi

# CLAUDE.md auto-clean — execution-violation fix: don't silently swallow failures.
# Original `|| true` masked real failures (stale references → bad cleanup).
echo ""
echo "── CLAUDE.md auto-clean ──"
bash scripts/sprint-claude-md-check.sh "$SLUG" --auto-fix 2>&1 | tail -10
CMD_RC=${PIPESTATUS[0]}
if [ "$CMD_RC" -ne 0 ]; then
  echo "[!] CLAUDE.md auto-clean exit $CMD_RC — see output above. Cleanup phase continues but exit recorded to state.cleanup_warnings[]."
  atomic_update_state "$SLUG" --argjson rc "$CMD_RC" --arg at "$NOW_ISO" '.cleanup_warnings = ((.cleanup_warnings // []) + [{step:"claude-md-auto-clean", rc:$rc, at:$at}])'
fi

# AC-7 (deterministic-phases-v1): record cleanup sub-step + delegate phase advance
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/sub-step.sh" 2>/dev/null || true
if declare -F record_sub_step >/dev/null 2>&1; then
  record_sub_step "$SLUG" "cleanup-deadcode-delete" pass || true
  record_sub_step "$SLUG" "cleanup-lint-fix" pass || true
  record_sub_step "$SLUG" "cleanup-claude-md-clean" pass || true
fi
if [ -x "$(dirname "$0")/sprint-advance-phase.sh" ]; then
  SPRINT_SLUG_OVERRIDE="$SLUG" bash "$(dirname "$0")/sprint-advance-phase.sh" pre-deploy 2>&1 || {
    echo "[i] cleanup sub-steps recorded; phase advance to pre-deploy deferred." >&2
  }
else
  atomic_update_state "$SLUG" '.phase = "pre-deploy" | .gates_passed = (.gates_passed + ["cleanup"] | unique)'  # legacy fallback
fi
echo ""
echo "[+] phase → pre-deploy, cleanup sub-steps recorded"
echo "═══ Cleanup complete ═══"
