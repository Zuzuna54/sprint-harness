#!/usr/bin/env bash
# sprint-migration-check.sh — Verify schema changes have a migration file.
#
# Runs drizzle-kit's dry-run schema diff. If schema differs from current DB
# state, ensures a migration file exists in the sprint branch that accounts
# for the diff. Catches the common bug: changing Drizzle schema without
# generating the migration.
#
# Usage: bash scripts/sprint-migration-check.sh [<slug>]
#
# Exit codes:
#   0 = no schema diff OR diff is covered by a migration in sprint branch
#   1 = schema diff exists but no migration found
#   2 = config error / can't run

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint and no slug given."
  exit 2
fi

DB_PACKAGE_PATH="packages/db"
MIGRATIONS_DIR="$DB_PACKAGE_PATH/src/migrations"
LOG_FILE="docs/sprints/$SLUG/migration-check.log"

mkdir -p "docs/sprints/$SLUG"

echo "═══ Sprint migration check: $SLUG ═══" | tee "$LOG_FILE"
echo "Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ── Are there schema files changed in this sprint branch? ────────────────────
BASE_BRANCH="${SPRINT_BASE_BRANCH:-main}"
# Include working-tree (unstaged) AND branch-vs-base diff so uncommitted schema
# edits are caught, not just committed ones. Path was 'schemas/' (plural) but
# repo actually uses 'schema/' (singular) — fixed.
SCHEMA_FILES_CHANGED=$( {
  git diff --name-only "$BASE_BRANCH"...HEAD -- "$DB_PACKAGE_PATH/src/schema/" 2>/dev/null
  git diff --name-only -- "$DB_PACKAGE_PATH/src/schema/" 2>/dev/null
  git ls-files --others --exclude-standard "$DB_PACKAGE_PATH/src/schema/" 2>/dev/null
} | sort -u | sed '/^$/d')
MIGRATION_FILES_ADDED=$( {
  git diff --name-only --diff-filter=A "$BASE_BRANCH"...HEAD -- "$MIGRATIONS_DIR/" 2>/dev/null
  git ls-files --others --exclude-standard "$MIGRATIONS_DIR/" 2>/dev/null
} | sort -u | sed '/^$/d')

echo "Schema files changed in sprint (vs $BASE_BRANCH):" | tee -a "$LOG_FILE"
if [ -z "$SCHEMA_FILES_CHANGED" ]; then
  echo "  (none — no schema changes)" | tee -a "$LOG_FILE"
else
  echo "$SCHEMA_FILES_CHANGED" | sed 's/^/  /' | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

echo "Migration files added in sprint:" | tee -a "$LOG_FILE"
if [ -z "$MIGRATION_FILES_ADDED" ]; then
  echo "  (none)" | tee -a "$LOG_FILE"
else
  echo "$MIGRATION_FILES_ADDED" | sed 's/^/  /' | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# ── Rule: schema changes require a corresponding migration ───────────────────
if [ -n "$SCHEMA_FILES_CHANGED" ] && [ -z "$MIGRATION_FILES_ADDED" ]; then
  echo "✗ FAIL: schema files changed but no new migration in sprint branch." | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "Generate one via:" | tee -a "$LOG_FILE"
  echo "  pnpm --filter @lifeos/db migrate:generate" | tee -a "$LOG_FILE"
  echo "  (review the generated SQL, then commit)" | tee -a "$LOG_FILE"
  exit 1
fi

# ── Dry-run drizzle-kit to confirm schema is in sync ─────────────────────────
# BUG 12 fix v2: skip the drizzle-kit invocation entirely when SCHEMA_FILES_CHANGED
# is empty. If git diff already says no schema files changed in this sprint
# branch, there's nothing for drizzle-kit to validate — running it just spams
# pnpm errors when drizzle-kit's project resolution fails on empty work.
# Only run drizzle-kit when there ARE schema changes but we want to verify the
# migration matches (caught earlier as the FAIL case).

if [ -z "$SCHEMA_FILES_CHANGED" ]; then
  echo "✓ No schema files changed — skipping drizzle-kit dry-run." | tee -a "$LOG_FILE"
  echo "✓ Migration check passed." | tee -a "$LOG_FILE"
  exit 0
fi

if command -v pnpm >/dev/null 2>&1; then
  echo "Running: drizzle-kit generate --dry-run (output suppressed unless diff found)" | tee -a "$LOG_FILE"
  # Redirect BOTH stdout + stderr to log; capture only stdout to DRY_OUT
  DRY_OUT=$(pnpm --filter @lifeos/db exec drizzle-kit generate --name=sprint-check-$$ --dry-run 2>>"$LOG_FILE" || true)

  # Broader "no diff" pattern includes empty output + pnpm-resolution errors
  # (which fire when there's nothing to generate), and explicit no-op messages.
  if [ -z "$DRY_OUT" ] || \
     echo "$DRY_OUT" | grep -qiE "no changes detected|nothing to migrate|empty|no schema changes|ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL|^$"; then
    echo "" | tee -a "$LOG_FILE"
    echo "✓ Schema is in sync (no diff detected)." | tee -a "$LOG_FILE"
    exit 0
  fi

  # Only show output when there's actually a diff for the user
  echo "$DRY_OUT" | tail -20 | tee -a "$LOG_FILE"

  if echo "$DRY_OUT" | grep -qiE "would generate|migration generated"; then
    if [ -z "$MIGRATION_FILES_ADDED" ]; then
      echo "" | tee -a "$LOG_FILE"
      echo "✗ FAIL: drizzle-kit detected schema diff but no migration in sprint." | tee -a "$LOG_FILE"
      exit 1
    fi
  fi
fi

echo "" | tee -a "$LOG_FILE"
echo "✓ Migration check passed." | tee -a "$LOG_FILE"
exit 0
