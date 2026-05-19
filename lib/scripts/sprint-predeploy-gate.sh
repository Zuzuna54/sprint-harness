#!/usr/bin/env bash
# sprint-predeploy-gate.sh — AC D2 (harness-portability-v4)
#
# Phase-transition gate: verifying → pre-deploy.
# Called by sprint-orchestrator skill (Phase 6 step 3) after reviewer +
# security-architect subagents have both signed off on the diff.
#
# Effects:
#   - asserts state.json.phase in {verifying, building} AND verify reports green
#   - sets state.json.phase = pre-deploy
#   - appends "pre-deploy" to state.json.gates[]
#   - commits the state.json change with message "sprint(<slug>): pre-deploy"
#
# Override (escape hatch, logs to state.gate_bypasses[]):
#   SPRINT_PREDEPLOY_BYPASS=1 bash scripts/sprint-predeploy-gate.sh
#
# Usage:
#   bash scripts/sprint-predeploy-gate.sh                          # uses active sprint
#   bash scripts/sprint-predeploy-gate.sh --slug <slug>             # explicit slug
#   bash scripts/sprint-predeploy-gate.sh --reviewer <md-path>      # attach review evidence
#   bash scripts/sprint-predeploy-gate.sh --security <md-path>      # attach security review
#   bash scripts/sprint-predeploy-gate.sh --no-commit                # update state only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

SLUG=""
NO_COMMIT=false
REVIEWER_FILE=""
SECURITY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) shift; SLUG="${1:-}"; shift ;;
    --reviewer) shift; REVIEWER_FILE="${1:-}"; shift ;;
    --security) shift; SECURITY_FILE="${1:-}"; shift ;;
    --no-commit) NO_COMMIT=true; shift ;;
    -h|--help)
      sed -n '1,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "[!] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SLUG" ]; then
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint and no --slug provided" >&2
  exit 2
fi

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"

[ -f "$STATE_FILE" ] || { echo "[!] state.json missing: $STATE_FILE" >&2; exit 2; }

if [ -f scripts/lib/state-lock.sh ]; then
  # shellcheck disable=SC1091
  . scripts/lib/state-lock.sh
fi

PHASE="$(jq -r '.phase // ""' "$STATE_FILE")"
case "$PHASE" in
  verifying|building|pre-deploy)
    : # OK
    ;;
  *)
    if [ "${SPRINT_PREDEPLOY_BYPASS:-0}" != "1" ]; then
      echo "[!] Phase is '$PHASE' but must be 'verifying' or 'building' to advance to pre-deploy" >&2
      echo "    Override with SPRINT_PREDEPLOY_BYPASS=1 (logged)" >&2
      exit 1
    fi ;;
esac

# Verify reports check — look for verify summary in state.json or verify.log
VERIFY_GREEN="$(jq -r '.verify_status // ""' "$STATE_FILE")"
if [ "$VERIFY_GREEN" != "green" ] && [ "$VERIFY_GREEN" != "passed" ] && [ "${SPRINT_PREDEPLOY_BYPASS:-0}" != "1" ]; then
  if [ ! -f "$SPRINT_DIR/verify.log" ] || ! grep -qiE "all (checks )?(pass|green)" "$SPRINT_DIR/verify.log"; then
    echo "[!] No verify-green signal found (state.json.verify_status != green AND verify.log doesn't show pass)" >&2
    echo "    Run /<BRAND_SLUG>-sprint-verify workflow or set verify_status=green explicitly" >&2
    echo "    Override with SPRINT_PREDEPLOY_BYPASS=1 (logged)" >&2
    exit 1
  fi
fi

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
BYPASS_NOTE="null"
if [ "${SPRINT_PREDEPLOY_BYPASS:-0}" = "1" ]; then
  BYPASS_NOTE="\"SPRINT_PREDEPLOY_BYPASS=1\""
fi
REVIEWER_JSON="null"
[ -n "$REVIEWER_FILE" ] && REVIEWER_JSON="\"$REVIEWER_FILE\""
SECURITY_JSON="null"
[ -n "$SECURITY_FILE" ] && SECURITY_JSON="\"$SECURITY_FILE\""

JQ_EXPR=".phase = \"pre-deploy\" |
         .gates = ((.gates // []) + [\"pre-deploy\"]) |
         .predeploy_at = \"$NOW_ISO\" |
         .predeploy_review = {reviewer: $REVIEWER_JSON, security: $SECURITY_JSON} |
         (if $BYPASS_NOTE != null
            then .gate_bypasses = ((.gate_bypasses // []) + [{at: \"$NOW_ISO\", gate: \"pre-deploy\", reason: $BYPASS_NOTE}])
            else .
          end)"

atomic_update_state "$SLUG" "$JQ_EXPR"

echo "[✓] $SLUG: phase → pre-deploy, gates += pre-deploy"

if [ "$NO_COMMIT" = "false" ]; then
  git add "$STATE_FILE" 2>/dev/null || true
  [ -n "$REVIEWER_FILE" ] && [ -f "$REVIEWER_FILE" ] && git add "$REVIEWER_FILE" 2>/dev/null || true
  [ -n "$SECURITY_FILE" ] && [ -f "$SECURITY_FILE" ] && git add "$SECURITY_FILE" 2>/dev/null || true
  git commit -m "sprint($SLUG): pre-deploy" --no-verify 2>/dev/null && echo "[✓] committed" || echo "[!] nothing to commit"
fi
