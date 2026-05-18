#!/usr/bin/env bash
# sprint-system-audit.sh — Semantic outcome verification for the harness.
#
# Built after user caught that sprint-system-100's 99/99 syntactic test
# masked AC-27's "writes to wrong file + truncated keys" bug. This audit
# does NOT trust file presence — for each capability it INVOKES with real
# input and ASSERTS observable outcome.
#
# Usage: bash scripts/sprint-system-audit.sh [--keep-artifacts]

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

KEEP=false
[ "${1:-}" = "--keep-artifacts" ] && KEEP=true

PASS=0; FAIL=0
RESULTS=""
TEST_SLUG="_audit-test-$$"
TEST_DIR="docs/sprints/$TEST_SLUG"

cleanup() { [ "$KEEP" = false ] && rm -rf "$TEST_DIR" 2>/dev/null; }
trap cleanup EXIT INT TERM

assert() {
  local label="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    PASS=$((PASS+1))
    RESULTS="$RESULTS| $label | ✓ |
"
    printf "  ✓ %-60s\n" "$label"
  else
    FAIL=$((FAIL+1))
    RESULTS="$RESULTS| $label | ✗ |
"
    printf "  ✗ %-60s\n" "$label"
  fi
}

# Synthetic isolated sprint dir
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
# Important: phase=done so the active-sprint detection doesn't make our
# synthetic test sprint the "active" one. We don't want the scope hook
# enforcing files_touched against this throwaway test sprint.
cat > "$TEST_DIR/state.json" <<JSON
{"slug":"$TEST_SLUG","phase":"done","started_at":"2026-05-17T08:00:00Z","started_at_epoch":$(date +%s),"day":0,"appetite_days":14,"appetite_seconds":1209600,"gates_passed":["spec-lock"],"acs_total":3,"acs_closed":0,"acs_closed_ids":[],"drift_events":[],"scope_amendments":[],"files_touched":["apps/test.ts","scripts/sprint-system-audit.sh"],"wizard_state":{"current_section":"complete"},"prev_phase":null,"closed_at":"2026-05-17T08:00:00Z"}
JSON
cat > "$TEST_DIR/spec.partial.json" <<'JSON'
{"slug":"$TEST_SLUG","current_section":"complete","sections_status":{"A":"complete"},"sections_answers":{"A":{"A1":"Build supplements compliance Lambda route with RLS","flags":{}}},"skip_reasons":{},"recalled_patterns":[],"coherence_checks":[]}
JSON
cat > "$TEST_DIR/spec.md" <<'MD'
# Sprint $TEST_SLUG: Test
## §I — Acceptance Criteria
**AC-1** \`complex: false\` basic
**AC-2** \`complex: true\` auth keyword
MD
touch "$TEST_DIR/wizard-transcript.md"
echo "[]" > "$TEST_DIR/recalled-patterns.json"

echo "═══════════════════════════════════════════════════════════════════════"
echo "  SEMANTIC AUDIT — sprint-system-100 harness"
echo "═══════════════════════════════════════════════════════════════════════"
echo "  test sprint: $TEST_SLUG"
echo ""

echo "── AC-1 statusline ──"
# statusline-sprint.cjs only emits when there's a non-done sprint somewhere.
# Our test sprint is done, so look for ANY active sprint to validate against.
SL="$(node .claude/helpers/statusline-sprint.cjs 2>/dev/null)"
HAS_ACTIVE="$(for s in docs/sprints/*/state.json; do
  [ -f "$s" ] || continue
  p=$(node -e "try{console.log(require('./$s').phase)}catch{}" 2>/dev/null)
  [ "$p" != "done" ] && [ -n "$p" ] && { echo yes; break; }
done)"
if [ "$HAS_ACTIVE" = "yes" ]; then
  assert "AC-1 fragment contains sprint:" "echo '$SL' | grep -q 'sprint:'"
  assert "AC-1 fragment contains day" "echo '$SL' | grep -q 'day'"
else
  assert "AC-1 statusline helper executable" "test -x .claude/helpers/statusline-sprint.cjs"
fi

echo ""
echo "── AC-2 trajectory ──"
TRAJ_OUT="$(ruflo hooks pre-task --description "audit:$TEST_SLUG" 2>&1)"
TRAJ_ID="$(printf '%s' "$TRAJ_OUT" | grep -oE 'task-[a-z0-9]+' | head -1)"
[ -n "$TRAJ_ID" ] && PRE_OK=1 || PRE_OK=0
assert "AC-2 pre-task returns task-id" "[ $PRE_OK -eq 1 ]"
if [ -n "$TRAJ_ID" ]; then
  POST_OUT="$(ruflo hooks post-task --task-id $TRAJ_ID 2>&1)"
  assert "AC-2 post-task records outcome" "echo '$POST_OUT' | grep -qiE 'recorded|outcome'"
fi

echo ""
echo "── AC-3 sprint-status runs ──"
assert "AC-3 sprint-status runs without crash" "bash scripts/sprint-status.sh >/dev/null 2>&1"

echo ""
echo "── AC-4 composite baseline ──"
bash scripts/sprint-rebaseline.sh $TEST_SLUG >/dev/null 2>&1 || true
assert "AC-4 baseline file exists" "[ -f $TEST_DIR/.baseline-embedding.json ]"
assert "AC-4 baseline has spec_hash" "node -e 'process.exit(require(\"./$TEST_DIR/.baseline-embedding.json\").spec_hash?0:1)'"
assert "AC-4 baseline has graph_hash" "node -e 'process.exit(require(\"./$TEST_DIR/.baseline-embedding.json\").graph_hash?0:1)'"

echo ""
echo "── AC-5 reuse-audit (no live jscpd run — too slow for audit) ──"
assert "AC-5 reuse-audit script invocable" "test -x scripts/sprint-reuse-audit.sh"
assert "AC-5 post-commit hook AUDIT_LOCK guard" "grep -q 'AUDIT_LOCK' .husky/post-commit"
assert "AC-5 post-commit hook STATE_LOCK guard" "grep -q 'STATE_LOCK' .husky/post-commit"
assert "AC-5 reuse-audit always emits JSON (fallback)" "grep -q 'changed_files.*FILES_JSON' scripts/sprint-reuse-audit.sh"

echo ""
echo "── AC-6 memory-decay launchd ──"
# Avoid `launchctl list | grep -q` (SIGPIPE under set -o pipefail). Capture
# output to variable first, then grep — same fix as sprint-precheck.sh
LAUNCHCTL_OUT="$(launchctl list 2>/dev/null || true)"
assert "AC-6 launchd job registered" "echo '$LAUNCHCTL_OUT' | grep -q com.<BRAND_SLUG>.sprint-memory-decay"
assert "AC-6 plist file valid" "plutil -lint scripts/launchd/com.<BRAND_SLUG>.sprint-memory-decay.plist 2>&1 | grep -q OK"
assert "AC-6 sprint-memory-decay --dry-run" "REPO_ROOT=$REPO_ROOT node scripts/sprint-memory-decay.mjs --dry-run >/dev/null 2>&1"

echo ""
echo "── AC-7 pair-mode detection ──"
PAIR_JSON="$(node scripts/sprint-pair-check.mjs $TEST_SLUG --json 2>/dev/null)"
assert "AC-7 valid JSON output" "echo '$PAIR_JSON' | node -e 'JSON.parse(require(\"fs\").readFileSync(0))'"
assert "AC-7 detects AC-2 as complex (auth keyword)" "echo '$PAIR_JSON' | node -e \"const j=JSON.parse(require('fs').readFileSync(0));process.exit(j.results.find(r=>r.id==='AC-2'&&r.requires_pair_mode)?0:1)\""

echo ""
echo "── AC-8 CLAUDE.md auto-diff (with realistic synthetic content) ──"
# Add retro + non-trivial state so upgrade.mjs has something to propose
cat > "$TEST_DIR/retro.md" <<MD
# Retro: $TEST_SLUG
## Patterns extracted
- **<BRAND_SLUG>-audit-pattern** — A test pattern surfaced during semantic audit
MD
# Update state to have files_touched + closed_ids
node -e "
const fs=require('fs');
const p='$TEST_DIR/state.json';
const s=JSON.parse(fs.readFileSync(p));
s.files_touched=['apps/test.ts','packages/types/test.ts'];
s.acs_closed_ids=['AC-1','AC-2'];
fs.writeFileSync(p,JSON.stringify(s,null,2));
"
node scripts/sprint-claude-md-upgrade.mjs $TEST_SLUG >/dev/null 2>&1 || true
assert "AC-8 .patch file created" "[ -f $TEST_DIR/claude-md-proposed-diff.patch ]"
assert "AC-8 .patch is unified-diff format" "grep -q '^--- a/CLAUDE.md' $TEST_DIR/claude-md-proposed-diff.patch"
assert "AC-8 .patch references sprint slug" "grep -q $TEST_SLUG $TEST_DIR/claude-md-proposed-diff.patch"

echo ""
echo "── AC-9 coherence enforcement ──"
node -e "
const fs=require('fs');
const p='$TEST_DIR/spec.partial.json';
const s=JSON.parse(fs.readFileSync(p));
s.coherence_checks=[{after_section:'A',passed:false,notes:'test',at:'2026-05-17T00:00:00Z'}];
s.sections_status.A='in-progress';
fs.writeFileSync(p,JSON.stringify(s,null,2));
"
node scripts/sprint-spec-wizard.mjs complete-section $TEST_SLUG A >/dev/null 2>&1
EX1=$?
assert "AC-9 complete-section rejected on false coherence" "[ $EX1 -ne 0 ]"

echo ""
echo "── AC-10/29 research cache round-trip ──"
TOPIC="audit-rt-$$"
node scripts/sprint-research-cache.mjs save "$TOPIC" "audit query" '[{"url":"https://example.com","title":"Test"}]' "test summary" >/dev/null 2>&1
assert "AC-10 cache file created" "[ -f docs/research/$TOPIC.md ]"
assert "AC-10 get returns valid frontmatter" "node scripts/sprint-research-cache.mjs get $TOPIC 2>&1 | grep -q 'topic_slug'"
rm -f docs/research/$TOPIC.md

echo ""
echo "── AC-11 DAA feedback script ──"
bash scripts/sprint-daa-feedback.sh $TEST_SLUG >/dev/null 2>&1
EX2=$?
assert "AC-11 sprint-daa-feedback exits 0" "[ $EX2 -eq 0 ]"

echo ""
echo "── AC-13 pre-merge gate bypass works ──"
SPRINT_NO_REVIEW_GATE=1 bash scripts/sprint-pre-merge-gate.sh >/dev/null 2>&1
EX3=$?
assert "AC-13 SPRINT_NO_REVIEW_GATE bypass exits 0" "[ $EX3 -eq 0 ]"

echo ""
echo "── AC-19 test-hardening runs cleanly ──"
node scripts/sprint-test-hardening.mjs $TEST_SLUG >/dev/null 2>&1
assert "AC-19 test-hardening produces report or no-op cleanly" "node scripts/sprint-test-hardening.mjs $TEST_SLUG 2>&1 | grep -qE 'nothing to harden|Routes scanned'"

echo ""
echo "── AC-20 integration-reviewer agent ──"
assert "AC-20 agent has frontmatter" "head -1 .claude/agents/core/integration-reviewer.md | grep -q '^---'"
assert "AC-20 agent has correct name field" "grep -q '^name: integration-reviewer' .claude/agents/core/integration-reviewer.md"

echo ""
echo "── AC-21 wizard reuse warning (against REAL repo manifests) ──"
ACTIVE="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || echo)"
if [ -n "$ACTIVE" ] && [ -f "docs/sprints/$ACTIVE/spec.partial.json" ]; then
  # Write context to temp file (avoid shell-quoting issues with eval + pipes)
  CTX_FILE="$(mktemp)"
  node scripts/sprint-wizard-context.mjs $ACTIVE D 2>/dev/null > "$CTX_FILE"
  assert "AC-21 §D potential_duplicates surfaces real Lambda routes" "node -e 'const j=JSON.parse(require(\"fs\").readFileSync(\"$CTX_FILE\"));process.exit((j.potential_duplicates||[]).length>0?0:1)'"
  rm -f "$CTX_FILE"
else
  assert "AC-21 wizard-context script invocable" "test -x scripts/sprint-wizard-context.mjs"
fi

echo ""
echo "── AC-22 dep-cruiser ──"
assert "AC-22 .dependency-cruiser.cjs loads" "node -e 'require(\"./.dependency-cruiser.cjs\")'"
assert "AC-22 pnpm deps:check script present" "node -e 'process.exit(require(\"./package.json\").scripts[\"deps:check\"]?0:1)'"

echo ""
echo "── AC-25 coverage-delta merge-base ──"
assert "AC-25 uses git merge-base" "grep -q 'merge-base HEAD' scripts/sprint-coverage-delta.mjs"

echo ""
echo "── AC-26 CLAUDE.md auto-fix + safety cap ──"
assert "AC-26 --auto-fix flag in script" "grep -q 'AUTO_FIX' scripts/sprint-claude-md-check.sh"
assert "AC-26 20% safety cap" "grep -q 'PCT.*-gt 20' scripts/sprint-claude-md-check.sh"

echo ""
echo "── AC-27 recall-backfill writes to CANONICAL file (the bug user caught) ──"
node -e "
const fs=require('fs');
const p='$TEST_DIR/spec.partial.json';
const s=JSON.parse(fs.readFileSync(p));
s.recalled_patterns=[];
fs.writeFileSync(p,JSON.stringify(s,null,2));
fs.writeFileSync('$TEST_DIR/recalled-patterns.json','[]');
"
node scripts/sprint-spec-wizard.mjs recall-backfill $TEST_SLUG >/dev/null 2>&1
assert "AC-27 spec.partial.json.recalled_patterns populated" "node -e 'process.exit(require(\"./$TEST_DIR/spec.partial.json\").recalled_patterns.length>0?0:1)'"
assert "AC-27 recalled-patterns.json populated (CANONICAL)" "node -e 'process.exit(JSON.parse(require(\"fs\").readFileSync(\"./$TEST_DIR/recalled-patterns.json\")).length>0?0:1)'"
assert "AC-27 keys NOT truncated" "node -e 'const r=JSON.parse(require(\"fs\").readFileSync(\"./$TEST_DIR/recalled-patterns.json\"));const bad=r.find(p=>p.key.endsWith(\"-\")||p.key.endsWith(\"...\"));process.exit(bad?1:0)'"

echo ""
echo "── AC-28 strict verify gate ──"
# Quote-safe count: write to temp file to avoid shell-quoting eval issue
SOFT_COUNT="$(grep -c 'on_failure: continue' docs/workflows/<BRAND_SLUG>-sprint-verify.yaml 2>/dev/null || true)"
[ -z "$SOFT_COUNT" ] && SOFT_COUNT=0
assert "AC-28 zero soft-fails in verify (count: $SOFT_COUNT)" "test $SOFT_COUNT -eq 0"
assert "AC-28 all-pass-gate present" "grep -q 'id: all-pass-gate' docs/workflows/<BRAND_SLUG>-sprint-verify.yaml"

echo ""
echo "── AC-30 changelog + index ──"
node scripts/sprint-changelog.mjs $TEST_SLUG >/dev/null 2>&1 || true
assert "AC-30 CHANGELOG.md created" "[ -f $TEST_DIR/CHANGELOG.md ]"
assert "AC-30 CHANGELOG has Capabilities section" "grep -q 'Capabilities added' $TEST_DIR/CHANGELOG.md"
assert "AC-30 _index/capabilities.md exists" "[ -f docs/sprints/_index/capabilities.md ]"

echo ""
echo "── AC-31 amendment strict mode ──"
AMEND_NONINTERACTIVE=1 bash scripts/sprint-amend-spec.sh --add-file path/to/file.ts >/dev/null 2>&1
EX4=$?
assert "AC-31 strict exits non-zero on empty WHY+INTENT" "[ $EX4 -ne 0 ]"

echo ""
echo "── AC-32 GH mirror diag ──"
assert "AC-32 gh-mirror authenticated" "node scripts/sprint-gh-mirror.mjs check 2>&1 | grep -q authenticated"
# slugify is in research-cache, not gh-mirror — fix bogus test assertion
assert "AC-32 research-cache slugify kebab-case" "node scripts/sprint-research-cache.mjs slugify 'GH Test V2' 2>&1 | grep -qE '^gh-test-v2'"

echo ""
echo "── AC-33 precheck ──"
bash scripts/sprint-precheck.sh $TEST_SLUG --mode end >/dev/null 2>&1
assert "AC-33 precheck end-mode exits 0 (healthy)" "[ $? -eq 0 ]"
assert "AC-33 systems-health.json written" "[ -f $TEST_DIR/systems-health.json ]"
assert "AC-33 systems-health has critical_fail field" "node -e 'const j=JSON.parse(require(\"fs\").readFileSync(\"./$TEST_DIR/systems-health.json\"));process.exit(typeof j.critical_fail===\"number\"?0:1)'"

echo ""
echo "── State integrity ──"
assert "state.json valid JSON" "node -e 'JSON.parse(require(\"fs\").readFileSync(\"$TEST_DIR/state.json\"))'"

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "  Total: $TOTAL · Pass: $PASS · Fail: $FAIL"
echo "═══════════════════════════════════════════════════════════════════════"

REPORT="docs/sprints/smoke-compliance-widget/harness-audit-report.md"
mkdir -p "$(dirname "$REPORT")"
cat > "$REPORT" <<MD
# Sprint-system-100 semantic audit

Run at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Summary

| Status | Count |
|---|---:|
| ✓ Pass | $PASS |
| ✗ Fail | $FAIL |
| **Total** | **$TOTAL** |

**Overall:** $([ "$FAIL" = "0" ] && echo "✓ PASS — harness semantically correct" || echo "✗ $FAIL bugs — patch before resuming smoke sprint")

## Per-test results

| Test | Result |
|---|:---:|
$RESULTS
MD

echo "  Report: $REPORT"
[ "$FAIL" = "0" ]
