# Troubleshooting

Common sprint-harness issues + the symptoms that flag them. Cross-references the [bypass cheatsheet](./bypass-cheatsheet.md) and [state.json recovery](./state-json-recovery.md).

---

## "git commit hangs for 30+ seconds"

**Likely cause:** post-commit `pnpm dlx jscpd` first-time download (~50 MB) on cold pnpm cache.

**Fix:**

1. **Pre-warm cache once:** `pnpm dlx jscpd --version` — installs to `~/Library/Caches/pnpm/dlx/`
2. **Or skip:** `SPRINT_SKIP_REUSE_AUDIT=1 git commit ...`
3. **Or wait once:** first commit downloads, subsequent are <2s

**Root cause** (fixed in `c809568`): the post-commit hook used to fire jscpd without a lockfile guard. Concurrent Claude sessions stacked up scans (~1-3 GB each). Now there's an `AUDIT_LOCK` PID file + stale-lock reclaim.

---

## "node process count > 40 / RAM > 5 GB"

**Symptom:** `ps aux | grep node | wc -l` returns 40+; system slow.

**Diagnostic:**

```bash
ps -axo pid,ppid,pmem,rss,etime,command | grep node | sort -k4 -rn | head -10
```

If you see multiple `jscpd` processes (~1-3 GB each) — concurrent reuse audits. Kill all + verify lockfile guard in place:

```bash
pkill -9 -f jscpd
pkill -9 -f sprint-reuse-audit
grep -q AUDIT_LOCK .husky/post-commit || echo "MISSING — re-apply commit c809568"
```

---

## "Sprint-status returns no active sprint despite running sprint"

**Likely cause 1:** state.json corrupt. See [state.json recovery](./state-json-recovery.md) Recipe 3.

**Likely cause 2:** Another sprint's state.json has phase != "done" and is winning the most-recent-mtime tiebreaker:

```bash
for s in docs/sprints/*/state.json; do
  slug=$(basename $(dirname $s))
  phase=$(node -e "console.log(require('./$s').phase)" 2>/dev/null)
  [ "$phase" != "done" ] && echo "  NON-DONE: $slug ($phase)"
done
```

Mark the wrong one done:

```bash
tmp=$(mktemp); jq '.phase = "done"' docs/sprints/<wrong>/state.json > "$tmp" && mv "$tmp" docs/sprints/<wrong>/state.json
```

---

## "Phantom sprint keeps re-asserting itself as active"

**Symptom:** You mark a sprint `phase=done`, run something, then `sprint-status` shows it active again.

**Cause:** A background daemon worker is auto-progressing the phase. Most likely the ruflo daemon's `audit` or `consolidate` worker mis-applied a state update.

**Fix:**

```bash
# 1. Stop the daemon
ruflo daemon stop

# 2. Force phantom done with permanent marker
tmp=$(mktemp); jq '.phase = "done" | .abandoned_permanent = true' \
  docs/sprints/<phantom>/state.json > "$tmp" && mv "$tmp" docs/sprints/<phantom>/state.json

# 3. Touch your real sprint's state.json to win mtime tiebreaker
touch docs/sprints/<real-slug>/state.json

# 4. Verify
bash scripts/sprint-status.sh --slug-only

# 5. Restart daemon if needed
ruflo daemon start
```

This pattern hit us 5+ times during sprint-system-100. The deeper fix is in the AC-15 follow-up: explicit phase-immutability in the daemon worker.

---

## "Drift check blocks legitimate commits"

**Symptom:** Commits touching files in `state.files_touched[]` still score < 0.65 / 0.75.

**Cause:** The commit's content (msg + diff sample) is too semantically different from the spec text. Common with:

- Pure refactors (no new keywords, just code moves)
- Comment-only commits
- Migration commits (different language than spec narrative)

**Three options** (post-commit hook prompts):

1. `bash scripts/sprint-amend-spec.sh --add-file <new-file>` — widens scope, rebaselines
2. `git reset HEAD~ --soft` — undo the commit
3. `SPRINT_DRIFT_BYPASS=1 git commit` — logged for retro

**Tuning** (if too aggressive):

```bash
SPRINT_DRIFT_THRESHOLD=0.55 git commit ...
```

After 3 sprints of data, look at `metrics.json.drift.below_threshold_paused` — average count tells you whether to permanently lower the threshold.

---

## "Hook blocks an out-of-scope edit I need to make"

**Error:** `Out-of-scope edit during sprint X: path Y is not in spec's Files touched list`

**Fix:** Amend scope (uses AC-31 strict — requires WHY+INTENT):

```bash
AMEND_WHY="reason..." AMEND_INTENT="success criterion..." \
  bash scripts/sprint-amend-spec.sh --add-file path/to/file
```

Or emergency override (logged):

```bash
SPRINT_DRIFT_BYPASS=1 # the same env var also bypasses scope hook
```

---

## "Wizard skipped a section I wanted answered"

**Cause:** `sections_answers.A.flags` set wrong (e.g., `backend_only: true` but you DO want UI).

**Fix:**

```bash
$EDITOR docs/sprints/<slug>/spec.partial.json
# edit sections_answers.A.flags, then:
node scripts/sprint-spec-wizard.mjs section <slug> <X>
```

---

## "Coherence check refuses to advance to next section"

**Cause** (AC-9 enforcement): last coherence_check for this section recorded `passed: false`.

**Fix:**

```bash
node scripts/sprint-wizard-coherence.mjs <slug> <section> --record true "Resolved: <how>"
node scripts/sprint-spec-wizard.mjs complete-section <slug> <section>
```

Or re-do the conflicting prior section:

```
"redo §<X>"  (tell Claude — it clears that section and re-asks)
```

---

## "Hive-mind spec-lock fails with daemon-down error"

**Diagnostic:** `ruflo daemon status` shows STOPPED.

**Fix:**

```bash
ruflo daemon start --workspace .
sleep 3
ruflo daemon status   # should show RUNNING
bash scripts/sprint-hive-mind-spec-lock.sh <slug>
```

If daemon won't stay up, check `.claude-flow/daemon.log` for crash reason. Most often: `~/Library/Caches/pnpm` is stale; `pnpm store prune` then retry.

Emergency bypass: `SPRINT_HIVE_MIND_BYPASS=1` — sprint-lock proceeds without consensus signal (logged).

---

## "recalled-patterns.json is empty after wizard"

**Cause** (AC-27 originally fixed this): wizard `assemble` didn't auto-call `recall-backfill`.

**Fix:** Manually backfill:

```bash
node scripts/sprint-spec-wizard.mjs recall-backfill <slug>
cat docs/sprints/<slug>/spec.partial.json | jq '.recalled_patterns | length'
```

Should return >0 patterns above 0.5 similarity threshold.

---

## "GH PR body auto-fill didn't run"

**Cause:** GH Actions disabled, or PR not from `sprint/*` branch.

**Manual fix:**

```bash
node scripts/sprint-pr-body.mjs <slug> --pr <number>
```

Or check `.github/workflows/sprint-pr-body.yml` is enabled in GH UI.

---

## "Memory recall returns empty / score 0"

**Diagnostic:**

```bash
sqlite3 .swarm/memory.db "SELECT count(*) FROM memory_entries"
# Expect >0; if 0, memory.db never populated
ruflo memory search -q "test query" --limit 3
```

**Fix:** ensure daemon is running + memory_search MCP tool reachable. If sqlite shows entries but search returns nothing, rebuild HNSW index:

```bash
ruflo memory search -q "anything" --build-hnsw --limit 1
```

---

## "Pair-mode banner never fires"

**Test:** make a commit with msg `"feat(test): AC-12 some change"` where AC-12 is `complex:true` in spec.

```bash
# Verify spec marks the AC as complex
node scripts/sprint-pair-check.mjs <slug> --json | \
  jq '.results[] | select(.id=="AC-12") | .requires_pair_mode'
# Should print "true"
```

If `false`, the keyword detection in `sprint-pair-check.mjs` didn't catch it. Check AC body for one of the keyword list (auth/RLS/migration/JWT/secret/delete/password/hash/encrypt/payment/billing/charge). Add `` `complex: true` `` to the AC header to force-flag.

---

## "Launchd memory-decay never fires"

**Diagnostic:**

```bash
launchctl list | grep com.<BRAND_SLUG>.sprint-memory-decay
# Should show "-  0  com.<BRAND_SLUG>.sprint-memory-decay"
launchctl print gui/$(id -u)/com.<BRAND_SLUG>.sprint-memory-decay 2>&1 | head -20
```

If exit code != 0:

```bash
cat .swarm/memory-decay.err
# Most common: PATH stripped → node not found. The plist exports PATH=/opt/homebrew/bin:... — verify it's correct for your system.

bash scripts/launchd/install-memory-decay.sh   # re-install + reload
```

**Verify it fired:**

```bash
ls -la .swarm/memory-decay.log
tail -10 .swarm/memory-decay.log
```

---

## "I'm stuck — give me a full status dump"

```bash
bash scripts/sprint-status.sh --json | jq .          # state.json
bash scripts/sprint-precheck.sh <slug> --mode end    # systems health
node scripts/sprint-velocity.mjs <slug>              # metrics
node scripts/sprint-system-test.sh <slug>            # full functional test (~30s)
node scripts/sprint-harness-readiness.mjs <slug>     # per-AC Production verdict count
```

Or tell Claude: _"give me a 2-minute brief on where we are with sprint-system-100"_.

---

## "Gate caught a real violation but exit was 0 — looks like a silent bug"

This is the `<BRAND_SLUG>-exit-vs-summary-divergence` pattern. Affected harness-full-coverage's `sprint-bundle-budget.mjs` and `sprint-perf-check.mjs` until fixed. Symptom: script prints "✗ FAIL: 2 over budget" but `process.exit(0)`.

**Diagnosis:** the summary boolean drove the log line but the exit was unconditional. Fix:

```javascript
process.exit(summary.pass ? 0 : 1) // tie exit to summary
```

When reviewing a new gate, capture exit code via `${PIPESTATUS[0]}` or direct invocation (not through `| tail`):

```bash
node scripts/some-gate.mjs > /tmp/log 2>&1
echo "true exit: $?"   # this is the gate's exit, not tail's
```

---

## "ruflo workflow run -f file.yaml says 'no steps array'"

Upstream Ruflo #1916 — YAML workflow decomposition isn't implemented for our schema. Workaround:

```bash
bash scripts/run-workflow.sh docs/workflows/<BRAND_SLUG>-sprint-verify.yaml slug=<slug>
```

Our shim parses `steps:` array via awk, executes each `cmd:` sequentially, honors `on_failure: pause`. Use this until ruflo ships native YAML support.

---

## "Proof verdict claims Production but no inject test was performed"

This is the `<BRAND_SLUG>-presence-isnt-production` trap (caught in harness-full-coverage's 4th close). Fix: run the helper:

```bash
PROOF_FILE=docs/sprints/<slug>/proof/AC-N.md \
AC_ID=AC-N \
GATE_NAME="<gate>" \
ASSERT_PATTERN="<expected catch substring>" \
  bash scripts/sprint-inject-violation.sh <fixture> "<gate-command>"
```

If no fixture exists for your gate, create one in `scripts/violation-fixtures/<name>.patch` (use `git diff` against a real injection edit).

---

## "WebSearch invocation contains PII"

Pipe through redaction before invocation:

```bash
QUERY="search for $USER_EMAIL settings"
SAFE_QUERY=$(echo "$QUERY" | bash scripts/sprint-pii-redact.sh 2>/dev/null)
# Now invoke WebSearch with $SAFE_QUERY
```

`sprint-pii-redact.sh` strips 6 PII pattern classes: email, UUID, JWT, API key, password=, postgresql://. Per spec §J of harness-full-coverage, verified end-to-end against real WebSearch tool call.
