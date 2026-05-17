#!/usr/bin/env bash
# sprint-audit-deps.sh — Run pnpm audit + check for new high/critical CVEs.
#
# Compares current `pnpm audit --json` output against a baseline (recorded at
# sprint-start). Fails if NEW high or critical vulnerabilities are introduced
# in the sprint branch.
#
# Usage: bash scripts/sprint-audit-deps.sh [<slug>] [--baseline]
#
# Exit codes:
#   0 = no new high/critical CVEs
#   1 = new high/critical CVE(s) introduced
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
BASELINE_FILE="$SPRINT_DIR/audit-baseline.json"
CURRENT_FILE="$SPRINT_DIR/audit-current.json"
LOG_FILE="$SPRINT_DIR/audit.log"

mkdir -p "$SPRINT_DIR"

echo "═══ Dependency audit: $SLUG ═══" | tee "$LOG_FILE"
echo "Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Run pnpm audit; JSON output. Exit code is non-zero if vulnerabilities exist,
# but we want to capture all data regardless.
pnpm audit --json --audit-level=low > "$CURRENT_FILE" 2>>"$LOG_FILE" || true

if [ ! -s "$CURRENT_FILE" ]; then
  echo "[!] pnpm audit produced no output." | tee -a "$LOG_FILE"
  exit 2
fi

# Count current high/critical
HIGH_COUNT=$(grep -oE '"severity":[[:space:]]*"high"' "$CURRENT_FILE" | wc -l | tr -d ' ')
CRITICAL_COUNT=$(grep -oE '"severity":[[:space:]]*"critical"' "$CURRENT_FILE" | wc -l | tr -d ' ')

echo "Current state:" | tee -a "$LOG_FILE"
echo "  High:     $HIGH_COUNT" | tee -a "$LOG_FILE"
echo "  Critical: $CRITICAL_COUNT" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ "$WRITE_BASELINE" = true ]; then
  cp "$CURRENT_FILE" "$BASELINE_FILE"
  echo "[+] Baseline written: $BASELINE_FILE" | tee -a "$LOG_FILE"
  exit 0
fi

# Compare against baseline
if [ ! -f "$BASELINE_FILE" ]; then
  echo "[i] No baseline; writing current as baseline (first run)." | tee -a "$LOG_FILE"
  cp "$CURRENT_FILE" "$BASELINE_FILE"
  exit 0
fi

BASELINE_HIGH=$(grep -oE '"severity":[[:space:]]*"high"' "$BASELINE_FILE" | wc -l | tr -d ' ')
BASELINE_CRITICAL=$(grep -oE '"severity":[[:space:]]*"critical"' "$BASELINE_FILE" | wc -l | tr -d ' ')

NEW_HIGH=$((HIGH_COUNT - BASELINE_HIGH))
NEW_CRITICAL=$((CRITICAL_COUNT - BASELINE_CRITICAL))

echo "Delta vs baseline:" | tee -a "$LOG_FILE"
echo "  New high:     $NEW_HIGH" | tee -a "$LOG_FILE"
echo "  New critical: $NEW_CRITICAL" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ "$NEW_HIGH" -gt 0 ] || [ "$NEW_CRITICAL" -gt 0 ]; then
  echo "✗ FAIL: sprint introduces $((NEW_HIGH + NEW_CRITICAL)) new high/critical CVE(s)." | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "Mitigation:" | tee -a "$LOG_FILE"
  echo "  1. pnpm audit --fix (where possible)" | tee -a "$LOG_FILE"
  echo "  2. Investigate dependency upgrades introduced in this sprint" | tee -a "$LOG_FILE"
  echo "  3. If false positive / unfixable: add to ignore list with rationale" | tee -a "$LOG_FILE"
  exit 1
fi

echo "✓ No new high/critical CVEs vs baseline." | tee -a "$LOG_FILE"
exit 0
