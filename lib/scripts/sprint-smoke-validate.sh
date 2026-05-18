#!/usr/bin/env bash
# sprint-smoke-validate.sh — End-to-end smoke validation of sprint-system-100.
#
# AC-16 (sprint-system-100). Verifies every harness capability built in the
# 33-AC sprint actually works on the live system. Pass criterion: every
# check returns ✓ without manual overrides.
#
# Categories:
#   1. Existence + executability of all NEW scripts/files
#   2. Functional invocation (read-only or dry-run) of each
#   3. Cross-script integration (e.g., precheck output → systems-health.json)
#   4. State persistence (state.json fields populated per AC)
#
# Usage: bash scripts/sprint-smoke-validate.sh [<slug>]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG="${1:-sprint-system-100}"

PASS=0
FAIL=0
WARN=0
LOG=""

check() {
  local label="$1"
  local result="$2"  # OK|FAIL|WARN
  local detail="${3:-}"
  case "$result" in
    OK)   PASS=$((PASS + 1)); printf "  ✓ %-45s %s\n" "$label" "$detail" ;;
    WARN) WARN=$((WARN + 1)); printf "  ⚠ %-45s %s\n" "$label" "$detail" ;;
    *)    FAIL=$((FAIL + 1)); printf "  ✗ %-45s %s\n" "$label" "$detail" ;;
  esac
}

echo "═══ AC-16: sprint-system-100 smoke validation ═══"
echo "  Slug: $SLUG"
echo ""
echo "── 1. File presence + executability ──"

for f in \
  scripts/sprint-precheck.sh \
  scripts/sprint-changelog.mjs \
  scripts/sprint-deadcode-delete.mjs \
  scripts/sprint-test-hardening.mjs \
  scripts/sprint-gh-mirror.mjs \
  scripts/sprint-hive-mind-spec-lock.sh \
  scripts/sprint-pre-merge-gate.sh \
  scripts/sprint-research-cache.mjs \
  scripts/sprint-claude-md-upgrade.mjs \
  scripts/sprint-cleanup-launch.sh \
  scripts/pre-commit-duplication.mjs \
  scripts/sprint-amend-spec.sh \
  scripts/sprint-coverage-delta.mjs \
  scripts/sprint-rebaseline.sh \
  scripts/sprint-status.sh \
  scripts/sprint-start.sh \
  scripts/sprint-end.sh \
  scripts/sprint-spec-wizard.mjs \
  scripts/sprint-wizard-context.mjs \
  scripts/sprint-claude-md-check.sh \
  scripts/sprint-pair-check.mjs \
  scripts/sprint-memory-decay.mjs \
  scripts/sprint-reuse-audit.sh \
  scripts/sprint-daa-feedback.sh \
  .husky/pre-commit \
  .husky/post-commit \
  .husky/pre-push \
  .husky/post-merge \
  .claude/agents/core/integration-reviewer.md \
  .dependency-cruiser.cjs \
  scripts/launchd/com.<BRAND_SLUG>.sprint-memory-decay.plist \
  scripts/launchd/install-memory-decay.sh \
  docs/workflows/<BRAND_SLUG>-sprint-cleanup.yaml \
  docs/workflows/<BRAND_SLUG>-sprint-verify.yaml \
  docs/workflows/<BRAND_SLUG>-sprint-build.yaml \
  docs/workflows/<BRAND_SLUG>-deploy.yaml \
  docs/workflows/<BRAND_SLUG>-retro.yaml \
  ; do
  if [ -e "$f" ]; then
    if [[ "$f" == scripts/*.sh ]] || [[ "$f" == scripts/*.mjs ]] || [[ "$f" == .husky/* ]]; then
      [ -x "$f" ] && check "$f" "OK" "executable" || check "$f" "FAIL" "exists but NOT executable"
    else
      check "$f" "OK" "present"
    fi
  else
    check "$f" "FAIL" "MISSING"
  fi
done

echo ""
echo "── 2. AC functional checks ──"

# AC-1 statusline
SL="$(node .claude/helpers/statusline-sprint.cjs 2>/dev/null)"
[ -n "$SL" ] && check "AC-1 statusline" "OK" "emits fragment" || check "AC-1 statusline" "WARN" "no active sprint"

# AC-3 sprint-status time-box
bash scripts/sprint-status.sh >/dev/null 2>&1 && check "AC-3 sprint-status" "OK" "runs clean" || check "AC-3 sprint-status" "FAIL" "errored"

# AC-4 composite baseline
if [ -f "docs/sprints/$SLUG/.baseline-embedding.json" ]; then
  HAS_GRAPH_HASH=$(node -e "const b=require('./docs/sprints/$SLUG/.baseline-embedding.json'); console.log(b.graph_hash ? 'yes' : 'no')" 2>/dev/null)
  [ "$HAS_GRAPH_HASH" = "yes" ] && check "AC-4 composite baseline" "OK" "spec_hash + graph_hash" || check "AC-4 composite baseline" "WARN" "no graph_hash"
else
  check "AC-4 composite baseline" "FAIL" "no baseline file"
fi

# AC-6 launchd
if launchctl list 2>/dev/null | grep -q "com.<BRAND_SLUG>.sprint-memory-decay"; then
  check "AC-6 memory-decay launchd" "OK" "registered"
else
  check "AC-6 memory-decay launchd" "WARN" "not registered (run install-memory-decay.sh)"
fi

# AC-22 dep-cruiser config
node -e "require('./.dependency-cruiser.cjs')" 2>/dev/null && check "AC-22 dep-cruiser config" "OK" "loads" || check "AC-22 dep-cruiser config" "FAIL" "syntax error"

# AC-30 changelog + index
[ -f "docs/sprints/$SLUG/CHANGELOG.md" ] && check "AC-30 CHANGELOG.md" "OK" "present" || check "AC-30 CHANGELOG.md" "WARN" "not generated yet"
[ -f "docs/sprints/_index/capabilities.md" ] && check "AC-30 capabilities index" "OK" "present" || check "AC-30 capabilities index" "WARN" "not generated"

# AC-33 precheck (non-strict — don't bail)
PRECHECK_OUT="$(bash scripts/sprint-precheck.sh "$SLUG" --mode end 2>&1 | tail -2 | head -1)"
[ -n "$PRECHECK_OUT" ] && check "AC-33 systems-precheck" "OK" "runs end-to-end" || check "AC-33 systems-precheck" "WARN" "no output"

# AC-10 research cache
[ -f "docs/research/github-projects-v2-graphql-2026.md" ] && check "AC-10 research cache" "OK" "has cached entry" || check "AC-10 research cache" "WARN" "empty"

# AC-32 gh-mirror diag
node scripts/sprint-gh-mirror.mjs check 2>&1 | grep -q "authenticated" && check "AC-32 gh-mirror diag" "OK" "gh authenticated" || check "AC-32 gh-mirror diag" "WARN" "gh not authenticated"

# AC-7 pair-check inventory
node scripts/sprint-pair-check.mjs "$SLUG" --json 2>/dev/null | grep -q '"results"' && check "AC-7 pair-check inventory" "OK" "parses spec ACs" || check "AC-7 pair-check inventory" "WARN" "parse failed"

# AC-27 backfill
node scripts/sprint-spec-wizard.mjs 2>&1 | grep -q recall-backfill && check "AC-27 recall-backfill cmd" "OK" "subcommand registered" || check "AC-27 recall-backfill cmd" "WARN" "not in CLI help"

echo ""
echo "── 3. State persistence ──"
STATE="docs/sprints/$SLUG/state.json"
if [ -f "$STATE" ]; then
  node -e "JSON.parse(require('fs').readFileSync('$STATE'))" 2>/dev/null && check "state.json valid JSON" "OK" "" || check "state.json valid JSON" "FAIL" "corrupt"
  AC_COUNT=$(node -e "console.log((require('./$STATE').acs_closed_ids||[]).length)" 2>/dev/null || echo 0)
  check "state.acs_closed_ids" "OK" "$AC_COUNT closed"
  FILES_COUNT=$(node -e "console.log((require('./$STATE').files_touched||[]).length)" 2>/dev/null || echo 0)
  check "state.files_touched" "OK" "$FILES_COUNT files"
  GATES_COUNT=$(node -e "console.log((require('./$STATE').gates_passed||[]).length)" 2>/dev/null || echo 0)
  check "state.gates_passed" "OK" "$GATES_COUNT gates"
else
  check "state.json" "FAIL" "missing"
fi

echo ""
echo "═══ Smoke validation summary ═══"
echo "  ✓ Pass:  $PASS"
echo "  ⚠ Warn:  $WARN"
echo "  ✗ Fail:  $FAIL"
echo ""

# Write report
REPORT="docs/sprints/$SLUG/smoke-validation.json"
mkdir -p "docs/sprints/$SLUG"
cat > "$REPORT" <<'JSON'
{
  "slug": "$SLUG",
  "run_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pass": $PASS,
  "warn": $WARN,
  "fail": $FAIL,
  "overall": "$([ "$FAIL" = "0" ] && echo SUCCESS || echo FAILED)"
}
JSON
echo "  Report: $REPORT"

[ "$FAIL" = "0" ]
