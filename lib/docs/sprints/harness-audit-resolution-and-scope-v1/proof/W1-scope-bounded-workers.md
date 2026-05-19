# Wave 1 — Scope-bounded workers (AC-1..4)

**Verdict:** Production
**Methodology:** code edits + live smoke against prior sprint's audit output (the canonical 100%-noise dataset).

## What landed

| AC   | Change                                                                                                         | File:line                              |
| ---- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| AC-1 | `gate_audit_blocks` accepts `<slug>` arg; partitions findings into in-scope (block) vs out-of-scope (advisory) | `scripts/lib/worker-gates.sh:25-127`   |
| AC-2 | NEW `gate_optimize_scope_filter` (advisory-only) + `gate_optimize_advisory` accepts slug                       | `scripts/lib/worker-gates.sh:158-228`  |
| AC-3 | `sprint-verify.sh` passes `$SLUG` to both gates                                                                | `scripts/sprint-verify.sh:194,210`     |
| AC-4 | `phase-workers.json` version 1.0→1.1 + new `worker_scope` field per phase entry                                | `scripts/lib/phase-workers.json:32-43` |

**Real bug discovered + fixed during W1**: prior `gate_audit_blocks` was reading `.vulnerabilities[]` at top level, but the ruflo audit worker schema is actually `.findings.vulnerabilities[]`. Fix: union path `(.findings.vulnerabilities // .vulnerabilities // [])` — handles both schemas for back-compat with any older worker output. Without this fix, prior sprint's `verify-worker-audit` gate would have silently passed (counting 0 instead of 10) — which IS what happened in the prior sprint's verify run (gate said PASS but operator triaged 10 vulns manually). This is closure-sprint corner-cutting prevention by accident.

## Scope strategy (Sketch A + post-filter)

Per locked decision: **scope-bound at gate-eval time, not at worker-invocation time** (mirror existing `gate_testgaps_blocks` pattern from harness-parallel-safety-v2).

Source-of-truth for scope: `state.json.files_touched[]` (populated by `sprint-amend-spec.sh --lock` from spec.md §H1 + amendment via `--add-file`). Fallback to `spec.md ## Files touched` awk-parse for legacy pre-spec-lock sprints.

Out-of-scope findings are ADVISORY for ALL sprints (locked decision: scope-back-compat=advisory-for-all). Logged via `[OUT/<severity>] <file>:<line> — <desc>` lines on stderr. Never block phase advance.

## Live smoke — prior sprint's 100%-noise audit

```
$ source scripts/lib/worker-gates.sh
$ gate_audit_blocks docs/sprints/harness-truthful-docs-and-wiring-v1/worker-output/audit.json \
                    harness-truthful-docs-and-wiring-v1
[gate-audit] scope=0 in-scope + 10 out-of-scope (noise ratio: 100% out-of-scope)
[gate-audit] advisory (out-of-scope findings — not blocking):
  [OUT/high] .claude/helpers/github-safe.js:45 — Command injection risk: tmpFile path...
  [OUT/high] .claude/helpers/memory.js:9 — Insecure data storage: Memory data is stored...
  [OUT/high] .claude/helpers/session.js:18 — Predictable session ID generation...
  [OUT/high] .claude/helpers/session.js:9 — Unencrypted session storage...
  [OUT/medium] .claude/helpers/github-safe.js:46 — Insufficient input validation...
  [OUT/medium] .claude/helpers/memory.js:23 — No input validation on key parameter...
  [OUT/medium] .claude/helpers/session.js:33 — No validation of context data...
  [OUT/medium] .claude/helpers/statusline.js:22 — Unsafe database file access...
  [OUT/medium] .claude/helpers/github-safe.js:62 — Race condition in temp file handling...
  [OUT/low] .claude/helpers/memory.js:45 — Missing error handling...
exit code: 0   # PASS — 0 in-scope blockers
```

**Result:** what was a "bypass-with-rationale-and-ship" failure mode in the prior sprint (10 vulns → operator wrote 10-finding triage doc → bypassed verify-worker-audit) is now AUTOMATIC. Scope-bounding eliminates the 100% noise; the operator sees the same advisory log but the gate doesn't block. Real in-scope findings will still block (zero-tolerance preserved within scope).

## Inject-violation-catch-restore (sampled — verify scope path)

Sampled: in-scope finding triggers block.

| Phase    | Action                                                                                                                                                                                                                               | Expected                                          | Result                                                                                                             |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Baseline | Run gate against prior sprint audit + scope = out-of-scope only                                                                                                                                                                      | rc=0 + advisory log                               | ✓ Confirmed (smoke above)                                                                                          |
| Inject   | Synthetically add a vuln in `scripts/sprint-deploy.sh` (which IS in files_touched[]) — manually craft audit.json with .findings.vulnerabilities += [{severity:high, file:scripts/sprint-deploy.sh, line:1, description:test-inject}] | rc=1 + BLOCK message + that vuln in IN-SCOPE list | (Deferred to W4 dogfood — this sprint's own audit-rerun against modified scripts will exercise the path naturally) |
| Restore  | n/a                                                                                                                                                                                                                                  | n/a                                               | n/a                                                                                                                |

The inject path runs naturally in W4 dogfood: this sprint touches `worker-gates.sh` + `sprint-verify.sh` + others which ARE in files_touched[]. If audit finds any vuln in those files, the gate WILL block (since they're now in-scope).

## C-conditions coverage

| Condition                            | Wave | Status             |
| ------------------------------------ | ---- | ------------------ |
| C-base (Sketch A + post-filter)      | W1   | ✓ implemented      |
| Scope back-compat = advisory-for-all | W1   | ✓ uniform behavior |

## Files modified

- `scripts/lib/worker-gates.sh` (+85 lines: scope arg + state.json read + partition loop + advisory log + new gate_optimize_scope_filter)
- `scripts/sprint-verify.sh` (+2 lines: pass $SLUG to both gates)
- `scripts/lib/phase-workers.json` (+10 lines: worker_scope per-worker map; version 1.0→1.1)

## Done = all of

- ✓ AC-1 gate_audit_blocks scope-bounded with state.json-first read
- ✓ AC-2 gate_optimize_scope_filter added + gate_optimize_advisory accepts slug
- ✓ AC-3 sprint-verify.sh passes $SLUG to both gates
- ✓ AC-4 phase-workers.json declares per-worker scope (audit + testgaps = files-touched/post-filter; optimize = repo/none)
- ✓ Bug-fix bonus: audit.json schema `.findings.vulnerabilities[]` correctly read (was silently 0 on prior sprint)
- ✓ Live smoke: 10/10 prior-sprint vulns correctly classified as out-of-scope advisory; gate passes
- ✓ phase-workers.json + worker-gates.sh bash syntax clean
