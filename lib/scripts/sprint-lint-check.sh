#!/usr/bin/env bash
# sprint-lint-check.sh — Workspace-wide lint gate using ESLint directly.
#
# Rationale: `pnpm turbo run lint` is non-functional in this workspace because
# only apps/web declares a `lint` script (and it runs interactive `next lint`).
# `.eslintrc.<BRAND_SLUG>.json` currently has a schema bug. This script bypasses both
# and invokes the local ESLint binary with an inline rule set.
#
# Usage: bash scripts/sprint-lint-check.sh [path1 path2 ...]
# Exit 0 = no errors. Exit 1 = errors found. Exit 2 = config error.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ESLINT="apps/web/node_modules/.bin/eslint"
[ -x "$ESLINT" ] || { echo "[!] eslint not found at $ESLINT"; exit 2; }

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(scripts)

# Inline rule config — JS/MJS only (no TS parser available at workspace root).
RULES='{
  "parserOptions": { "ecmaVersion": 2022, "sourceType": "module" },
  "rules": {
    "no-debugger": "error",
    "no-eval": "error",
    "no-var": "error"
  }
}'

CFG="$(mktemp).json"
echo "$RULES" > "$CFG"

echo "═══ sprint-lint-check ═══"
"$ESLINT" --no-eslintrc --config "$CFG" --ext .js,.mjs "${TARGETS[@]}"
RC=$?
rm -f "$CFG"
[ $RC -eq 0 ] && echo "✓ lint clean" || echo "✗ lint errors found (exit $RC)"
exit $RC
