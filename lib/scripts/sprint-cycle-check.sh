#!/usr/bin/env bash
# sprint-cycle-check.sh — Detect cyclic import dependencies.
#
# Uses madge (pnpm dlx, no install required) to find circular dependencies in
# apps/lambdas + packages. Gates on new cycles only — existing cycles are
# baselined.
#
# Usage: bash scripts/sprint-cycle-check.sh [<slug>] [--baseline]
#
# Exit codes:
#   0 = no new cycles
#   1 = new cycles introduced
#   2 = config error

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG="${1:-}"
WRITE_BASELINE=false
for arg in "$@"; do
  case "$arg" in
    --baseline) WRITE_BASELINE=true ;;
    --*) ;;
    *) [ -z "$SLUG" ] && SLUG="$arg" ;;
  esac
done

if [ -z "$SLUG" ]; then
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi

if [ -z "$SLUG" ]; then
  echo "[!] No active sprint and no slug given."
  exit 2
fi

SPRINT_DIR="docs/sprints/$SLUG"
BASELINE_FILE="$SPRINT_DIR/cycles-baseline.txt"
CURRENT_FILE="$SPRINT_DIR/cycles-current.txt"
LOG_FILE="$SPRINT_DIR/cycles.log"

mkdir -p "$SPRINT_DIR"

echo "═══ Cyclic dependency check: $SLUG ═══" | tee "$LOG_FILE"
echo "Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Run madge — circular only, on lambdas + packages
echo "Scanning apps/lambdas + packages for cycles..." | tee -a "$LOG_FILE"

# Use pnpm dlx so we don't require madge as a project dep
MADGE_OUT=$(pnpm dlx madge --circular --extensions ts,tsx apps/lambdas packages 2>&1 || true)
echo "$MADGE_OUT" > "$CURRENT_FILE"

# madge prints "1) a > b > a" lines per cycle. `grep -c | head -1` produces
# a single integer line even when grep finds zero matches (would otherwise
# return rc=1 and stray "0" output).
CYCLE_COUNT=$(grep -cE "^[[:space:]]*[0-9]+\)" "$CURRENT_FILE" 2>/dev/null | head -1)
CYCLE_COUNT=${CYCLE_COUNT:-0}

echo "Current cycles: $CYCLE_COUNT" | tee -a "$LOG_FILE"

if [ "$WRITE_BASELINE" = true ]; then
  cp "$CURRENT_FILE" "$BASELINE_FILE"
  echo "[+] Baseline written: $BASELINE_FILE" | tee -a "$LOG_FILE"
  exit 0
fi

if [ ! -f "$BASELINE_FILE" ]; then
  echo "[i] No baseline; writing current as baseline (first run)." | tee -a "$LOG_FILE"
  cp "$CURRENT_FILE" "$BASELINE_FILE"
  exit 0
fi

BASELINE_COUNT=$(grep -cE "^[[:space:]]*[0-9]+\)" "$BASELINE_FILE" 2>/dev/null | head -1)
BASELINE_COUNT=${BASELINE_COUNT:-0}
DELTA=$((CYCLE_COUNT - BASELINE_COUNT))

echo "Baseline cycles: $BASELINE_COUNT" | tee -a "$LOG_FILE"
echo "Delta:           $DELTA" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ "$DELTA" -gt 0 ]; then
  echo "✗ FAIL: $DELTA new cyclic dependencies introduced." | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "New cycles (best-effort diff):" | tee -a "$LOG_FILE"
  diff "$BASELINE_FILE" "$CURRENT_FILE" | grep "^>" | head -20 | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "Refactor needed: break the cycle by extracting a shared module, inverting" | tee -a "$LOG_FILE"
  echo "dependencies, or using dependency injection." | tee -a "$LOG_FILE"
  exit 1
fi

echo "✓ No new cycles introduced." | tee -a "$LOG_FILE"
exit 0
