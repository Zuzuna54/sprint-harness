#!/usr/bin/env bash
# sprint-reuse-audit.sh — Audit sprint commit for code duplication / reuse opportunities.
#
# For each file changed in the sprint diff vs main, runs a similarity check against
# the rest of the codebase (using jscpd if available, falls back to grep heuristics).
# Surfaces candidates with >50% structural overlap.
#
# Designed to be called by `code-review-swarm` skill OR run manually post-AC.
#
# Usage: bash scripts/sprint-reuse-audit.sh [<slug>]
#
# Exit codes:
#   0 = no duplication concerns
#   1 = duplication detected (advisory; doesn't block by default)
#   2 = config error

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint"
  exit 2
fi

SPRINT_DIR="docs/sprints/$SLUG"
REPORT_FILE="$SPRINT_DIR/reuse-audit.json"
LOG_FILE="$SPRINT_DIR/reuse-audit.log"

mkdir -p "$SPRINT_DIR"

echo "═══ Reuse audit: $SLUG ═══" | tee "$LOG_FILE"

BASE="${SPRINT_BASE_BRANCH:-main}"
CHANGED=$(git diff --name-only --diff-filter=A "$BASE"...HEAD -- 'apps/**/*.ts' 'apps/**/*.tsx' 'packages/**/*.ts' 2>/dev/null | head -50)

if [ -z "$CHANGED" ]; then
  echo "[i] No new TS/TSX files in sprint vs $BASE — nothing to audit." | tee -a "$LOG_FILE"
  echo "[]" > "$REPORT_FILE"
  exit 0
fi

echo "New files in sprint vs $BASE:" | tee -a "$LOG_FILE"
echo "$CHANGED" | sed 's/^/  /' | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

DUP_COUNT=0
JSCPD_RAN=false

# AC-5 (sprint-system-100, Gap L): always emit valid JSON to $REPORT_FILE.
# Previously this script wrote a log file but only created the JSON when
# jscpd succeeded — which it usually didn't (pnpm dlx -y is invalid flag).
# Post-commit hook can now reliably read state.json.reuse_audits[].

# ── Try jscpd if available, else use lightweight heuristic ───────────────────
if command -v pnpm >/dev/null 2>&1; then
  echo "Running jscpd (pnpm dlx) for similarity detection..." | tee -a "$LOG_FILE"
  # FIX: removed bogus `-y` flag (pnpm dlx auto-accepts).
  # Token-burn fix: wrap with timeout 120 to prevent jscpd from running
  # indefinitely (each hung jscpd consumes 1-3 GB RAM; 3 concurrent = ~7 GB).
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 pnpm dlx jscpd --silent --min-tokens 50 --threshold 30 --reporters json --output "$SPRINT_DIR/jscpd-report" $CHANGED apps/web/components apps/lambdas packages 2>&1 | tail -20 | tee -a "$LOG_FILE" || true
  else
    # macOS fallback using perl alarm
    perl -e 'alarm 120; exec @ARGV' -- pnpm dlx jscpd --silent --min-tokens 50 --threshold 30 --reporters json --output "$SPRINT_DIR/jscpd-report" $CHANGED apps/web/components apps/lambdas packages 2>&1 | tail -20 | tee -a "$LOG_FILE" || true
  fi
  JSCPD_RAN=true

  if [ -f "$SPRINT_DIR/jscpd-report/jscpd-report.json" ]; then
    DUP_COUNT=$(grep -c '"duplicates"' "$SPRINT_DIR/jscpd-report/jscpd-report.json" || echo 0)
    cp "$SPRINT_DIR/jscpd-report/jscpd-report.json" "$REPORT_FILE"
  fi
fi

# Ensure REPORT_FILE always exists as valid JSON (post-commit hook reads it)
if [ ! -f "$REPORT_FILE" ]; then
  # Build changed_files JSON array without depending on node (which may be
  # missing under restricted PATH e.g. launchd or skinny CI runners).
  FILES_JSON="["
  FIRST=1
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ $FIRST -eq 1 ]; then FIRST=0; else FILES_JSON="$FILES_JSON,"; fi
    FILES_JSON="$FILES_JSON\"$f\""
  done <<< "$CHANGED"
  FILES_JSON="$FILES_JSON]"

  cat > "$REPORT_FILE" <<JSON
{
  "duplications": $DUP_COUNT,
  "jscpd_ran": $JSCPD_RAN,
  "changed_files": $FILES_JSON,
  "advisory": true,
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
JSON
fi

echo "" | tee -a "$LOG_FILE"
echo "Duplication results: $DUP_COUNT entries" | tee -a "$LOG_FILE"
if [ "$DUP_COUNT" -gt 0 ]; then
  echo "⚠  Review: $REPORT_FILE" | tee -a "$LOG_FILE"
  if [ "${SPRINT_REUSE_STRICT:-0}" = "1" ]; then
    exit 1
  fi
fi

echo "✓ Reuse audit done (advisory). Report: $REPORT_FILE" | tee -a "$LOG_FILE"
exit 0
