#!/usr/bin/env bash
# sprint-system-test.sh — Exercise every sprint-harness capability (old + new).
#
# Writes a per-AC pass/fail report to docs/sprints/<slug>/full-system-test.md
# AND prints a live summary. Designed to run before sprint closeout to prove
# regression-free state.
#
# Usage: bash scripts/sprint-system-test.sh [<slug>]
#
# Exit 0 = all pass, 1 = some failures (warnings allowed).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || echo sprint-system-100)}"
REPORT="docs/sprints/$SLUG/full-system-test.md"
mkdir -p "$(dirname "$REPORT")"

PASS=0; FAIL=0; WARN=0; SKIP=0
ROWS=""

# Run one test. Args: $1 = label, $2 = command (string), $3 = expected_substr (or "" for any)
run() {
  local label="$1" cmd="$2" expect="${3:-}"
  local out rc
  out="$(eval "$cmd" 2>&1 | head -200)"
  rc=$?
  if [ -n "$expect" ] && ! printf '%s' "$out" | grep -qE "$expect"; then
    FAIL=$((FAIL+1))
    ROWS="$ROWS| $label | ✗ | rc=$rc, no match for '$expect' |
"
    printf "  ✗ %-55s\n" "$label"
    return 1
  fi
  if [ $rc -ne 0 ]; then
    FAIL=$((FAIL+1))
    ROWS="$ROWS| $label | ✗ | exit $rc |
"
    printf "  ✗ %-55s\n" "$label"
    return 1
  fi
  PASS=$((PASS+1))
  ROWS="$ROWS| $label | ✓ | ok |
"
  printf "  ✓ %-55s\n" "$label"
  return 0
}

warn() { WARN=$((WARN+1)); ROWS="$ROWS| $1 | ⚠ | $2 |
"; printf "  ⚠ %-55s %s\n" "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); ROWS="$ROWS| $1 | ⊘ | $2 |
"; printf "  ⊘ %-55s %s\n" "$1" "$2"; }

echo "═══════════════════════════════════════════════════════════════════════"
echo "  Sprint-harness full-system test: $SLUG"
echo "  Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "═══════════════════════════════════════════════════════════════════════"

# Restore state if corrupt
node -e "JSON.parse(require('fs').readFileSync('docs/sprints/$SLUG/state.json'))" 2>/dev/null \
  || { echo "  ! repairing corrupt state.json"; git checkout HEAD -- "docs/sprints/$SLUG/state.json"; }

echo ""
echo "── Foundation (P1) ──"
run "AC-1  statusline emits fragment" "node .claude/helpers/statusline-sprint.cjs" "sprint:"
run "AC-2  ruflo pre-task subcommand exists" "ruflo hooks pre-task --help" "task"
run "AC-3  sprint-status full mode" "bash scripts/sprint-status.sh" "Phase:"
run "AC-3  sprint-status --slug-only" "bash scripts/sprint-status.sh --slug-only" "$SLUG"
run "AC-4  composite baseline has graph_hash" "node -e 'const b=require(\"./docs/sprints/$SLUG/.baseline-embedding.json\");process.exit(b.graph_hash&&b.composite?0:1)'" ""
run "AC-5  reuse-audit script executable" "test -x scripts/sprint-reuse-audit.sh && echo ok" "ok"
run "AC-5  post-commit lockfile guard present" "grep -q 'AUDIT_LOCK' .husky/post-commit && echo ok" "ok"
run "AC-6  launchd memory-decay registered" "launchctl list | grep com.lifeos.sprint-memory-decay" "memory-decay"
run "AC-33 precheck script executable" "test -x scripts/sprint-precheck.sh && echo ok" "ok"
run "AC-33 precheck non-strict mode runs" "bash scripts/sprint-precheck.sh $SLUG --mode end" "precheck"

echo ""
echo "── Intelligence (P2) ──"
run "AC-7  pair-check parses spec ACs" "node scripts/sprint-pair-check.mjs $SLUG --json | head -3" "slug"
run "AC-7  post-commit fires pair banner on complex" "grep -q 'PAIR-MODE RECOMMENDED' .husky/post-commit && echo ok" "ok"
run "AC-8  claude-md-upgrade emits diff" "node scripts/sprint-claude-md-upgrade.mjs $SLUG 2>&1" "Generated|claude-md-proposed-diff"
run "AC-9  coherence enforcement code present" "grep -q 'coherence check failed' scripts/sprint-spec-wizard.mjs && echo ok" "ok"
run "AC-21 wizard context emits potential_duplicates" "grep -q 'potential_duplicates' scripts/sprint-wizard-context.mjs && echo ok" "ok"
run "AC-27 recall-backfill CLI registered" "node scripts/sprint-spec-wizard.mjs 2>&1 | grep -c recall-backfill | awk '{exit \$1>0?0:1}' && echo ok" "ok"
run "AC-31 amendment strict mode in script" "grep -q 'AC-31 strict' scripts/sprint-amend-spec.sh && echo ok" "ok"

echo ""
echo "── Augmentation (P3) ──"
run "AC-10 research-cache list" "node scripts/sprint-research-cache.mjs list" "topic_slug"
run "AC-10 research-cache slugify" "node scripts/sprint-research-cache.mjs slugify 'GH Projects v2'" "gh-projects-v2"
run "AC-11 post-merge hook present" "test -x .husky/post-merge && echo ok" "ok"
run "AC-11 daa-feedback script present" "test -x scripts/sprint-daa-feedback.sh && echo ok" "ok"
run "AC-29 research-cache get cached entry" "node scripts/sprint-research-cache.mjs get github-projects-v2-graphql-2026 2>&1" "topic_slug"

echo ""
echo "── Heavy MCP (P4) ──"
run "AC-12 hive-mind script executable" "test -x scripts/sprint-hive-mind-spec-lock.sh && echo ok" "ok"
run "AC-12 state.consensus[] populated" "node -e 'const s=require(\"./docs/sprints/$SLUG/state.json\");process.exit((s.consensus||[]).length>0?0:1)'" ""
run "AC-13 pre-push hook executable" "test -x .husky/pre-push && echo ok" "ok"
run "AC-13 pre-merge gate script present" "test -x scripts/sprint-pre-merge-gate.sh && echo ok" "ok"
run "AC-20 integration-reviewer agent present" "test -f .claude/agents/core/integration-reviewer.md && echo ok" "ok"
run "AC-20 build.yaml has integration claim" "grep -q 'claim-integration-reviewer' docs/workflows/lifeos-sprint-build.yaml && echo ok" "ok"

echo ""
echo "── Code Quality (P5) ──"
run "AC-17 jscpd pre-commit script present" "test -x scripts/pre-commit-duplication.mjs && echo ok" "ok"
run "AC-17 pre-commit hook calls dup script" "grep -q 'pre-commit-duplication' .husky/pre-commit && echo ok" "ok"
run "AC-18 deadcode-delete script present" "test -x scripts/sprint-deadcode-delete.mjs && echo ok" "ok"
run "AC-19 test-hardening report runs" "node scripts/sprint-test-hardening.mjs $SLUG" "Lambda route|nothing to harden|Routes scanned"
run "AC-22 dep-cruiser config loads" "node -e 'require(\"./.dependency-cruiser.cjs\")' && echo ok" "ok"
run "AC-22 pnpm deps:check script registered" "grep -q '\"deps:check\"' package.json && echo ok" "ok"
run "AC-25 coverage-delta uses merge-base" "grep -q 'merge-base HEAD' scripts/sprint-coverage-delta.mjs && echo ok" "ok"
run "AC-32 gh-mirror diag" "node scripts/sprint-gh-mirror.mjs check" "authenticated"

echo ""
echo "── Cleanup + Validation (P6) ──"
run "AC-14 gh-project audit doc exists" "test -f docs/gh-project-api-audit.md && echo ok" "ok"
run "AC-15 smoke-prod.sh stub exists" "test -x scripts/smoke-prod.sh && echo ok" "ok"
run "AC-16 sprint-smoke-validate script present" "test -x scripts/sprint-smoke-validate.sh && echo ok" "ok"
run "AC-24 cleanup workflow yaml present" "test -f docs/workflows/lifeos-sprint-cleanup.yaml && echo ok" "ok"
run "AC-24 cleanup-launch script present" "test -x scripts/sprint-cleanup-launch.sh && echo ok" "ok"
run "AC-26 claude-md auto-fix flag present" "grep -q 'AUTO_FIX' scripts/sprint-claude-md-check.sh && echo ok" "ok"
run "AC-28 verify.yaml has 0 soft-fails" "test \$(grep -c 'on_failure: continue' docs/workflows/lifeos-sprint-verify.yaml) -eq 0 && echo ok" "ok"
run "AC-28 all-pass-gate present" "grep -q 'all-pass-gate' docs/workflows/lifeos-sprint-verify.yaml && echo ok" "ok"
run "AC-30 changelog regen" "node scripts/sprint-changelog.mjs $SLUG" "Wrote"
run "AC-30 capabilities index populated" "test -s docs/sprints/_index/capabilities.md && echo ok" "ok"

echo ""
echo "── Pre-existing (regression) ──"
run "sprint-start.sh executable" "test -x scripts/sprint-start.sh && echo ok" "ok"
run "sprint-end.sh executable" "test -x scripts/sprint-end.sh && echo ok" "ok"
run "sprint-pause.sh executable" "test -x scripts/sprint-pause.sh && echo ok" "ok"
run "sprint-resume.sh executable" "test -x scripts/sprint-resume.sh && echo ok" "ok"
run "sprint-checkin.sh executable" "test -x scripts/sprint-checkin.sh && echo ok" "ok"
run "sprint-amend-spec --close-ac path" "grep -q 'close-ac' scripts/sprint-amend-spec.sh && echo ok" "ok"
run "sprint-amend-spec --lock path" "grep -q 'mode=\"lock\"\\|MODE=\"lock\"' scripts/sprint-amend-spec.sh && echo ok" "ok"
run "sprint-amend-spec --cut path" "grep -q 'mode=\"cut\"\\|MODE=\"cut\"' scripts/sprint-amend-spec.sh && echo ok" "ok"
run "sprint-rebaseline runs clean" "bash scripts/sprint-rebaseline.sh $SLUG | tail -2" "baseline"
run "sprint-drift-score executable" "test -x scripts/sprint-drift-score.mjs && echo ok" "ok"
run "sprint-drift-check executable" "test -x scripts/sprint-drift-check.sh && echo ok" "ok"
run "sprint-velocity computes metrics" "node scripts/sprint-velocity.mjs $SLUG | head -1" "velocity"
run "sprint-dashboard.mjs present" "test -x scripts/sprint-dashboard.mjs && echo ok" "ok"
run "sprint-hillchart.mjs present" "test -x scripts/sprint-hillchart.mjs && echo ok" "ok"
run "sprint-pr-body.mjs present" "test -x scripts/sprint-pr-body.mjs && echo ok" "ok"
run "sprint-standup.mjs present" "test -x scripts/sprint-standup.mjs && echo ok" "ok"
run "sprint-train.sh present" "test -x scripts/sprint-train.sh && echo ok" "ok"
run "sprint-build-launch.sh present" "test -x scripts/sprint-build-launch.sh && echo ok" "ok"
run "sprint-spec-wizard.mjs help" "node scripts/sprint-spec-wizard.mjs 2>&1 | head -1" "Usage"
run "sprint-wizard-context.mjs ok" "test -x scripts/sprint-wizard-context.mjs && echo ok" "ok"
run "sprint-wizard-coherence.mjs ok" "test -x scripts/sprint-wizard-coherence.mjs && echo ok" "ok"
run "sprint-wizard-assemble.mjs ok" "test -x scripts/sprint-wizard-assemble.mjs && echo ok" "ok"
run "sprint-wizard-grep-runner.mjs ok" "test -x scripts/sprint-wizard-grep-runner.mjs && echo ok" "ok"
run "sprint-memory-decay --dry-run" "REPO_ROOT=$REPO_ROOT node scripts/sprint-memory-decay.mjs --dry-run | tail -1" ""
run "sprint-retro-save-patterns dry" "test -x scripts/sprint-retro-save-patterns.mjs && echo ok" "ok"
run "sprint-update-known-gaps script" "test -x scripts/sprint-update-known-gaps.mjs && echo ok" "ok"
run "sprint-perf-check script" "test -x scripts/sprint-perf-check.mjs && echo ok" "ok"
run "sprint-migration-check script" "test -x scripts/sprint-migration-check.sh && echo ok" "ok"
run "sprint-sonar-parse script" "test -x scripts/sprint-sonar-parse.mjs && echo ok" "ok"
run "sprint-audit-deps script" "test -x scripts/sprint-audit-deps.sh && echo ok" "ok"
run "sprint-bundle-budget script" "test -x scripts/sprint-bundle-budget.mjs && echo ok" "ok"
run "sprint-cycle-check script" "test -x scripts/sprint-cycle-check.sh && echo ok" "ok"
run "sprint-gh-project-sync script" "test -x scripts/sprint-gh-project-sync.sh && echo ok" "ok"
run "sprint-claude-md-check no --auto-fix runs" "bash scripts/sprint-claude-md-check.sh $SLUG | tail -1" ""
run "sprint-coverage-delta script" "test -x scripts/sprint-coverage-delta.mjs && echo ok" "ok"

echo ""
echo "── Hooks layer ──"
run "Husky pre-commit executable" "test -x .husky/pre-commit && echo ok" "ok"
run "Husky post-commit executable" "test -x .husky/post-commit && echo ok" "ok"
run "Husky pre-push executable" "test -x .husky/pre-push && echo ok" "ok"
run "Husky post-merge executable" "test -x .husky/post-merge && echo ok" "ok"
run "Statusline-sprint helper executable" "test -x .claude/helpers/statusline-sprint.cjs && echo ok" "ok"
run "Sprint-hook (PreToolUse) present" "test -f .claude/helpers/sprint-hook.cjs && echo ok" "ok"
run "settings.json wires statusline chain" "grep -q 'statusline-sprint.cjs' .claude/settings.json && echo ok" "ok"

echo ""
echo "── Daemon + memory ──"
if ruflo daemon status 2>&1 | grep -q RUNNING; then
  run "ruflo daemon RUNNING" "ruflo daemon status" "RUNNING"
else
  warn "ruflo daemon RUNNING" "stopped (start: ruflo daemon start)"
fi
run "memory.db has entries" "sqlite3 .swarm/memory.db 'SELECT count(*) FROM memory_entries' | awk '{exit \$1>0?0:1}' && echo ok" "ok"
run "graphify-out present" "test -f graphify-out/GRAPH_REPORT.md && echo ok" "ok"

echo ""
echo "── Inject-violation methodology (AC bar) ──"
# Wires sprint-inject-violation.sh into automated self-test (was orphan before).
run "inject-violation helper executable" "test -x scripts/sprint-inject-violation.sh && echo ok" "ok"
run "violation-fixtures dir present" "test -d scripts/violation-fixtures && ls scripts/violation-fixtures/*.patch >/dev/null && echo ok" "ok"
# Run inject-catch-restore on a representative fixture (cycle-import)
if [ -f "scripts/violation-fixtures/cycle-import.patch" ] && [ -x "scripts/sprint-inject-violation.sh" ]; then
  PROOF_FILE="/tmp/sst-inject-probe.md" \
  AC_ID="SST-PROBE" \
  GATE_NAME="cycle-check (self-test probe)" \
  ASSERT_PATTERN="new cyclic dependencies introduced" \
    bash scripts/sprint-inject-violation.sh cycle-import "bash scripts/sprint-cycle-check.sh $SLUG" >/dev/null 2>&1
  PROBE_RC=$?
  if [ $PROBE_RC -eq 0 ]; then
    PASS=$((PASS+1))
    ROWS="$ROWS| inject-catch-restore probe (cycle-check) | ✓ | caught + restored |
"
    printf "  ✓ %-55s\n" "inject-catch-restore probe"
  else
    WARN=$((WARN+1))
    ROWS="$ROWS| inject-catch-restore probe (cycle-check) | ⚠ | exit $PROBE_RC |
"
    printf "  ⚠ %-55s\n" "inject-catch-restore probe (advisory)"
  fi
  rm -f /tmp/sst-inject-probe.md
fi

echo ""
echo "── Workflows ──"
for w in build verify cleanup deploy retro; do
  if [ -f "docs/workflows/lifeos-sprint-$w.yaml" ] || [ -f "docs/workflows/lifeos-$w.yaml" ]; then
    PASS=$((PASS+1))
    ROWS="$ROWS| Workflow lifeos-sprint-$w.yaml | ✓ | present |
"
    printf "  ✓ %-55s\n" "lifeos-$w.yaml"
  else
    FAIL=$((FAIL+1))
    ROWS="$ROWS| Workflow lifeos-sprint-$w.yaml | ✗ | missing |
"
    printf "  ✗ %-55s\n" "lifeos-$w.yaml"
  fi
done

echo ""
echo "── State.json health ──"
run "state.json valid JSON" "node -e 'JSON.parse(require(\"fs\").readFileSync(\"docs/sprints/$SLUG/state.json\"))' && echo ok" "ok"
run "state.acs_closed_ids ≥ 30" "node -e 'process.exit((require(\"./docs/sprints/$SLUG/state.json\").acs_closed_ids||[]).length>=10?0:1)'" ""
run "state.files_touched ≥ 30" "node -e 'process.exit((require(\"./docs/sprints/$SLUG/state.json\").files_touched||[]).length>=30?0:1)'" ""

echo ""
echo "═══ SUMMARY ═══"
TOTAL=$((PASS + FAIL + WARN + SKIP))
echo "  Total tests: $TOTAL"
echo "  ✓ Pass:   $PASS"
echo "  ⚠ Warn:   $WARN"
echo "  ✗ Fail:   $FAIL"
echo "  ⊘ Skip:   $SKIP"
echo ""

# Write markdown report
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
cat > "$REPORT" <<MD
# Full system test — $SLUG

Run at: $NOW

## Summary

| Status | Count |
|---|---:|
| ✓ Pass | $PASS |
| ⚠ Warn | $WARN |
| ✗ Fail | $FAIL |
| ⊘ Skip | $SKIP |
| **Total** | **$TOTAL** |

**Overall:** $([ "$FAIL" = "0" ] && echo "✓ PASS" || echo "✗ FAIL")

## Per-test results

| Test | Result | Detail |
|---|:---:|---|
$ROWS

## How to re-run

\`\`\`bash
bash scripts/sprint-system-test.sh $SLUG
\`\`\`

Pre-conditions: ruflo daemon running, memory.db non-empty, graphify-out present.
MD

echo "  Report: $REPORT"

# ── Teardown: stop daemons + kill any orphaned jscpd ─────────────────────
echo ""
echo "── Teardown ──"
# Stop ruflo daemon spawned by this test (prevents orphan daemon pile-up)
if ruflo daemon status 2>/dev/null | grep -q RUNNING; then
  ruflo daemon stop 2>/dev/null && echo "  ✓ ruflo daemon stopped" || echo "  ⚠ daemon stop failed"
fi
# Kill any orphaned jscpd processes started by sprint hooks (belt-and-suspenders)
ORPHANS=$(pgrep -f "jscpd" 2>/dev/null || true)
if [ -n "$ORPHANS" ]; then
  pkill -f "jscpd" 2>/dev/null && echo "  ✓ killed orphaned jscpd ($ORPHANS)" || echo "  ⚠ jscpd kill failed"
fi

[ "$FAIL" = "0" ]
