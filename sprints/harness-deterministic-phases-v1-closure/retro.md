# Retro — harness-deterministic-phases-v1-closure

**Slug:** harness-deterministic-phases-v1-closure
**Closed:** 2026-05-19
**Duration:** single autonomous session (compressed timeline; nominal Day 0-14 walked end-to-end)
**Scope:** 53 leftover items from parent sprint `harness-deterministic-phases-v1`, grouped into 6 waves.

## What worked

Following USAGE.md to the teeth this time around — every phase advance flowed through `sprint-advance-phase.sh` with manifest predicates evaluated. The "5-ACs broken with followup" outcome from the parent sprint never recurred because every Wave produced a real proof file BEFORE the wave was marked closed. Sketch B from solution-sketches.md (six wave-mapped ACs, one architect-review + security-review with REAL content, not placeholders) was the right unit of granularity — small enough to commit per wave, large enough to capture context without blowing up cognitive scope.

L17 gate-names.json + L18 schema `_comment` + `deferred_gates` + L19 `--report-file` flag — three small ergonomic wins that compounded. Future CI integration is now a 30-line workflow change.

## What didn't

Wave D mirror was mostly mechanical but `sync-mirror.sh` did NOT actually exist as a single shell helper — Wave D ended up being direct `cp` invocations. The plan named `sync-mirror.sh` as if it were a callable tool; the actual mirror procedure has always been file-by-file `cp` plus brand-strip for workflow yamls. Plan was aspirational; reality was 24 `cp` invocations. Not a functional gap, but the kettle plan misnamed the workflow.

The replay validator surfaced `onboarding-flow-v2/state.json` as malformed JSON (orphan `},` block from a pre-v0.7 sprint that landed manually). First repair attempt with `awk` left it still corrupt — second attempt via Edit succeeded. Validators are only as useful as the recovery procedure documented for the things they catch.

## What surprised us

Wave A L1 ppid walk depth-3 — the synthetic test passed easily but the real Claude Code → Bash → hook chain has variable ppid depth depending on whether Claude is invoked via `claude` CLI vs via SDK vs from a worktree. The depth-3 ancestor walk turned out to be the minimum safe depth; depth-2 fails for SDK-launched sessions. Codified as the new `parentIsAdvancePhase()` in sprint-hook.cjs.

The `[record_sub_step] [WARN] gate 'wave-d-mirror' not declared in phase-manifest.json` warning fired exactly as designed when this closure sprint recorded its own wave-level sub-steps that don't exist in the manifest. L16 was meant as a safety net for typos; it turned out to also be the right UX for sprints that record their own custom gate names — softer-than-error semantics is the right call.

## Patterns extracted

### Pattern 1: `lifeos-toctou-safe-state-write`

**Symptom:** Predicates evaluated at T0 + write at T1 — between, another process advances. Result: predicate-based protections silently bypassed under race conditions.
**Fix:** Wrap the atomic state write's jq filter in `if .phase == $current then <new state> else error("phase changed mid-advance: \(.phase)") end`. Caller passes the just-read phase as `$current`. Closes TOCTOU class entirely for the specific field.
**Where applied:** `scripts/sprint-advance-phase.sh` step 12.
**Generalizes to:** any atomic-update-of-monotonic-field pattern (counters, version stamps, audit cursors).

### Pattern 2: `lifeos-deferred-gates-not-failed-gates`

**Symptom:** Manifest declares 68 gates but only 25 are instrumented (43 await follow-up sprints). Naive enforcement treats unwired gates as FAIL → sprint can never legitimately close.
**Fix:** Top-level manifest field `deferred_gates: string[]` lists gate names that should be reported `[DEFERRED]` not `[FAIL]`. Advance-phase shows deferred but does not block. Replay validator counts deferred as PASS for closed sprints. Follow-up sprint instruments + removes from `deferred_gates[]`.
**Where applied:** `scripts/lib/phase-manifest.json` top-level + `scripts/sprint-advance-phase.sh` check loop + replay validator skip logic.
**Generalizes to:** any feature-flag-style "declared but not enforced yet" rollout. Beats binary all-or-nothing enforcement.

### Pattern 3: `lifeos-hook-depth-3-ppid-walk`

**Symptom:** Hook `parentIsAdvancePhase()` returns false-negative when Claude → Bash → hook chain has variable ppid depth (CLI vs SDK vs worktree contexts).
**Fix:** Walk ppid ancestors up to depth 3 (not just immediate parent), checking each `ps -o command= -p $pid` for the expected sanctioned-writer name. Short-circuit on first match. Fallback to env-var check (`SPRINT_ADVANCE_PHASE_RUNNING=1`) on ps failure.
**Where applied:** `.claude/helpers/sprint-hook.cjs::parentIsAdvancePhase()`.
**Generalizes to:** any PreToolUse hook that needs to distinguish "command launched by sanctioned wrapper" from "command launched directly". Use depth ≥3 for Claude Code contexts.

## CLAUDE.md updates proposed

- `apps/web/CLAUDE.md`: no change (closure sprint scope is harness, not app).
- Root `CLAUDE.md`: phase-manifest already mentioned in active-sprint hooks section (T1.6). No new updates from closure work.

## Open follow-ups

- **v0.7.1**: race-test for L12 TOCTOU (parallel advance-phase invocations).
- **v0.7.1**: env-by-env smoke for 6 untested legacy bypass shims (L9 only tested SPRINT_DRIFT_BYPASS at runtime).
- **v0.7.1**: strict gate-names.json enforcement (any drift between manifest + constants file fails CI).
- **v0.8.0**: rewrite USAGE.md legacy `SPRINT_*_BYPASS` examples to single-bypass UX + remove legacy shim code.
- **harness-verify-instrumentation-v1** (separate appetite): wire the 43 deferred gates. ~41 ACs.
- **L47/L48 push to origin**: gated on `gio` confirmation. sprint-harness@v0.7.0 + lifeos@sprint/pipeline-v2-visibility (231 commits ahead).
- **Wave F**: resume parent `harness-deterministic-phases-v1` sprint, walk to done (this is the immediate next step after closure sprint marks done).
