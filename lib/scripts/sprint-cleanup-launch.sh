#!/usr/bin/env bash
# sprint-cleanup-launch.sh — Trigger the cleanup workflow.
#
# AC-24 (sprint-system-100). Day 11-12 of sprint, after verify completes
# and before deploy starts. Invokes docs/workflows/<BRAND_SLUG>-sprint-cleanup.yaml.
#
# Usage: bash scripts/sprint-cleanup-launch.sh [<slug>] [--commit-deadcode]

set -uo pipefail

# Fail-fast: state-mutating cleanup script must not silent-continue mid-flight.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
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

# If ruflo can run workflows, delegate. Else, run steps inline.
if command -v ruflo >/dev/null 2>&1 && ruflo workflow --help >/dev/null 2>&1; then
  echo "[+] Delegating to ruflo workflow execute <BRAND_SLUG>-sprint-cleanup"
  if [ "$COMMIT_DEADCODE" = true ]; then
    SPRINT_DEADCODE_COMMIT=1 ruflo workflow execute <BRAND_SLUG>-sprint-cleanup --input slug="$SLUG" 2>&1 | tail -30
  else
    ruflo workflow execute <BRAND_SLUG>-sprint-cleanup --input slug="$SLUG" 2>&1 | tail -30
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

tmp=$(mktemp); jq '.phase = "cleaning"' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
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
  tmp_w=$(mktemp)
  jq --arg at "$(date -u +%FT%TZ)" --argjson rc "$CMD_RC" \
    '.cleanup_warnings = ((.cleanup_warnings // []) + [{step:"claude-md-auto-clean", rc:$rc, at:$at}])' \
    "$STATE_FILE" > "$tmp_w" && mv "$tmp_w" "$STATE_FILE"
fi

# Return phase
tmp=$(mktemp)
jq '.phase = "pre-deploy" | .gates_passed = (.gates_passed + ["cleanup"] | unique)' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
echo ""
echo "[+] phase → pre-deploy, gates_passed += cleanup"
echo "═══ Cleanup complete ═══"
