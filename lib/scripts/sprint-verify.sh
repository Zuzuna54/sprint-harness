#!/usr/bin/env bash
# sprint-verify.sh — Day 11-12 verify chain orchestrator.
#
# Wraps the USAGE.md verify pipeline:
#   typecheck → lint → tests → /api-contract-validation → /debug-rls →
#   /module-status → audit (BLOCKING) + testgaps (BLOCKING) + optimize (advisory)
#
# Each step writes outcome to state.json.verify_gates and the worker outputs
# land at docs/sprints/<slug>/worker-output/.
#
# Exit codes:
#   0 — all gates pass; ready for pre-deploy review
#   1 — at least one blocking gate failed
#   2 — caller error (no active sprint, missing dependencies)
#
# Usage:
#   bash scripts/sprint-verify.sh                       # auto-resolves slug
#   SPRINT_SLUG_OVERRIDE=foo bash scripts/sprint-verify.sh
#   bash scripts/sprint-verify.sh --slug foo
#   bash scripts/sprint-verify.sh --skip-workers        # only run typecheck/lint/tests
#   bash scripts/sprint-verify.sh --workers-only        # skip typecheck/lint/tests, only run audit/testgaps/optimize
#
# CI: when CI=true and `claude` is not authenticated, hard-fails per Q8.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source scripts/lib/worker-trigger.sh
# shellcheck disable=SC1091
source scripts/lib/worker-gates.sh

SLUG="${SPRINT_SLUG_OVERRIDE:-}"
SKIP_WORKERS=0
WORKERS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --skip-workers) SKIP_WORKERS=1; shift ;;
    --workers-only) WORKERS_ONLY=1; shift ;;
    *) echo "[sprint-verify] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve slug via session-file if not provided.
if [ -z "$SLUG" ] && [ -f scripts/lib/session-file.sh ]; then
  # shellcheck disable=SC1091
  source scripts/lib/session-file.sh
  SLUG="$(read_session_file 2>/dev/null || true)"
fi
if [ -z "$SLUG" ]; then
  # Fallback: read first non-done sprint's state.json
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi
if [ -z "$SLUG" ]; then
  echo "[sprint-verify] no active sprint — pass --slug <name> or set SPRINT_SLUG_OVERRIDE" >&2
  exit 2
fi
if ! [[ "$SLUG" =~ ^[a-z0-9-]{3,64}$ ]]; then
  echo "[sprint-verify] invalid slug: $SLUG" >&2
  exit 2
fi

SPRINT_DIR="docs/sprints/$SLUG"
if [ ! -d "$SPRINT_DIR" ]; then
  echo "[sprint-verify] sprint dir not found: $SPRINT_DIR" >&2
  exit 2
fi

mkdir -p "$SPRINT_DIR/worker-output"

# Track results across all gates. Bash 3.2 (macOS) lacks `declare -A`, so we
# use a tmpfile of "gate-name<TAB>status" lines.
GATE_RESULTS_FILE="$(mktemp)"
trap 'rm -f "$GATE_RESULTS_FILE"' EXIT INT TERM

record_gate() {
  printf '%s\t%s\n' "$1" "$2" >> "$GATE_RESULTS_FILE"
}
print_summary() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════╗"
  echo "║  sprint-verify summary: $SLUG"
  echo "╚════════════════════════════════════════════════════════════════════╝"
  while IFS=$'\t' read -r gate status; do
    printf "  %-22s %s\n" "$gate" "$status"
  done < "$GATE_RESULTS_FILE"
  echo ""
}

# CI auth check per Q8 — hard-fail before doing anything expensive.
if [ "$SKIP_WORKERS" -eq 0 ] && [ -n "${CI:-}" ]; then
  if [ ! -f "$HOME/.claude/credentials.json" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "" >&2
    echo "[CI] worker-gates require local Claude Code OAuth session" >&2
    echo "[CI] run sprint-verify locally (auth via 'claude login') before pushing" >&2
    exit 1
  fi
fi

OVERALL_RC=0

# ──────────────────────────────────────────────────────────────────────────
# Phase 1 — non-worker gates from USAGE.md
# ──────────────────────────────────────────────────────────────────────────
if [ "$WORKERS_ONLY" -eq 0 ]; then
  echo "[sprint-verify] running USAGE.md verify chain for $SLUG..."

  # 1. typecheck — turbo-orchestrated; one TS error stops everything.
  echo "  → typecheck..."
  if pnpm turbo run typecheck 2>&1 | tail -5; then
    record_gate "typecheck" "✓ pass"
  else
    record_gate "typecheck" "✗ FAIL"
    OVERALL_RC=1
  fi

  # 2. lint (project specific — see sprint-lint-check.sh)
  echo "  → lint..."
  if [ -x scripts/sprint-lint-check.sh ]; then
    if bash scripts/sprint-lint-check.sh >/dev/null 2>&1; then
      record_gate "lint" "✓ pass"
    else
      record_gate "lint" "✗ FAIL"
      OVERALL_RC=1
    fi
  else
    record_gate "lint" "⊘ skipped (no helper)"
  fi

  # 3. tests
  echo "  → tests..."
  if pnpm turbo run test:unit 2>&1 | tail -5 >/dev/null; then
    record_gate "tests" "✓ pass"
  else
    record_gate "tests" "✗ FAIL"
    OVERALL_RC=1
  fi
fi

# ──────────────────────────────────────────────────────────────────────────
# Phase 2 — worker-backed gates (audit BLOCKING, testgaps BLOCKING, optimize advisory)
# ──────────────────────────────────────────────────────────────────────────
if [ "$SKIP_WORKERS" -eq 0 ]; then
  echo ""
  echo "[sprint-verify] firing audit + testgaps + optimize workers in parallel..."
  trigger_workers_parallel "$SLUG" audit testgaps optimize
  # ignore parallel rc — we evaluate per-gate below

  # Audit gate (Q2 — zero-tolerance)
  if gate_audit_blocks "$SPRINT_DIR/worker-output/audit.json"; then
    record_gate "audit" "✓ pass"
  else
    record_gate "audit" "✗ BLOCK"
    OVERALL_RC=1
  fi

  # Testgaps gate (Q3 — scope-bounded to files-touched)
  if gate_testgaps_blocks "$SPRINT_DIR/worker-output/testgaps.json" "$SLUG"; then
    record_gate "testgaps" "✓ pass"
  else
    record_gate "testgaps" "✗ BLOCK"
    OVERALL_RC=1
  fi

  # Optimize advisory only
  if gate_optimize_advisory "$SPRINT_DIR/worker-output/optimize.json"; then
    record_gate "optimize" "≈ advisory"
  else
    record_gate "optimize" "≈ advisory (no output)"
  fi
fi

print_summary

# Record verify run to state.json (best-effort).
if [ -f scripts/lib/atomic-state.sh ]; then
  # shellcheck disable=SC1091
  source scripts/lib/atomic-state.sh
  NOW_ISO="$(date -u +%FT%TZ)"
  GATES_ARRAY=$(awk -F'\t' 'BEGIN{first=1} { if (!first) printf ","; printf "{\"gate\":\"%s\",\"status\":\"%s\"}", $1, $2; first=0 }' "$GATE_RESULTS_FILE")
  RESULT_JSON="{\"at\":\"$NOW_ISO\",\"rc\":$OVERALL_RC,\"gates\":[$GATES_ARRAY]}"
  atomic_update_state "$SLUG" \
    ".verify_runs = (.verify_runs // []) + [$RESULT_JSON]" \
    2>/dev/null || true
fi

if [ "$OVERALL_RC" -ne 0 ]; then
  echo "[sprint-verify] ✗ BLOCKED — fix gates above and re-run" >&2
  exit 1
fi
echo "[sprint-verify] ✓ all gates pass — ready for pre-deploy review"
exit 0
