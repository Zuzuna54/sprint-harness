# Retro — audit-driven-fidelity-v1

**Closed**: 2026-05-19T16:25:56Z
**Appetite**: 21 days
**Actual elapsed**: ~2.4 hours (~0.5% of budget)
**Outcome**: 62/63 ACs Production, 1 deferred (R-O7)

## What worked

- **Parallel agent swarms.** Wave 2 had 33 ACs across 5 concurrent backend-dev/frontend swarms (Prep + E + F + G + H). The slowest swarm finished in ~34 min wall-time. Without parallelism, this would have been a sequential 4-day push at the architect's flagged 4.3 ACs/day rate.
- **Architect amendment-first sequencing.** The NEEDS_CHANGES verdict produced 7 spec amendments (R-X1 wave-move, R-L3 sequence-first, T2.0a/b fixtures, AC-W1-T1.5a pre-migration cleanup, §K Deferrals, V2 flag criteria) — all folded BEFORE Wave 1 started. Zero mid-sprint re-discovery of architecture gaps.
- **Feature flag gating (LIFEOS_PIPELINE_EMISSION_V2).** Wave 2's 30+ pipeline behavior changes all behind the env flag, default off. Pre-fix path preserved as regression-test baseline; flip happens AFTER Davit fixture passes cutover criteria.
- **Synthetic fixtures as cutover gate.** Davit + Levan + 2 edge fixtures encode the "post-fix expected" world. CI harness asserts both V2=0 (pre-fix) + V2=1 (post-fix) branches. The fixtures became the agreed-upon definition of "done" for Wave 2 swarms.
- **R-L3 retry rubber-stamp detection landed first.** Prevented Wave-2 dev loops from producing false-greens against stale partial pipeline state. Architect's biggest risk H4 mitigated.
- **Sub-agent claim isolation.** Each swarm had an exclusive file claim documented in dispatch prompts. Cross-swarm bundling via lint-staged (Swarms A+C, E+F) was an unexpected coordination win — content stayed correct; attribution muddied.

## What didn't

- **lint-staged auto-add cross-attributed commits.** Commits `1dd175b` and `e0141c2` (nominally Swarm A's R-O5/R-O8) accidentally absorbed Swarm C's R-F1/R-F2 changes via the pre-commit hook's full-working-tree sweep. Content correct; per-AC commit attribution muddy. Pattern for retro extraction.
- **One sprint-checkin.sh script overwrite caught.** Day-5 script wrote a stub template ON TOP of my detailed content. Manual re-author was needed. Bug in `sprint-checkin.sh` should detect existing populated content and append rather than overwrite.
- **state.json corruption mid-sprint.** A concurrent writer collision produced invalid JSON at line 141. Recovery required `atomic_update_state -n` null-input rebuild (the hook blocks every direct write path, but `-n` flag bypasses the input-file parse). Documented for future ops.
- **8 pre-existing test failures inherited.** Per spec §K, attributed to test-debt-v1 follow-up. Not closed in this sprint.
- **Token-count aggregation (R-L6) is partial.** Per-stage tokens roll up to generation_pipelines.total_tokens_used, but workouts-lambda's sub-Lambda invocation tokens still don't bubble back via the existing telemetry path. Documented in retro for future.

## What surprised

- **Davit had 3 medical conditions vs Levan's 2.** Including high_blood_pressure. Gave more coverage variants for the medicalContext consent-gate snapshot tests.
- **Migration 0083 RLS gap was real.** Prior sprint's W1.6 added dietary_restrictions_audit table without `ENABLE ROW LEVEL SECURITY`. Cross-user PII leakable via anon-key. R-X3 closed it.
- **The `share_with_ai_scheduler` column DIDN'T exist** when the prior sprint claimed it gated Gemini prompts. medicalContext.ts was unconditionally sending every active condition + medication to Gemini. R-O6 finally created the column + default-false migration.
- **Davit's `low_fodmap` survived the CHECK constraint.** The pre-cleanup UPDATE stripped the freeform "i want to aovid all of the bad additives..." string but preserved `low_fodmap` (which IS in the 12-value whitelist). 0 rows rejected by the new CHECK constraint.
- **Workers actually fired on schedule.** Day 0 `map`, per-wave `predict`, Day 11 `audit + testgaps + optimize`, Day 14 `document + consolidate` — all fired automatically via sprint-advance-phase.sh entry-into-phase hooks. The harness's worker integration is real.
- **`sprint/pipeline-v2-visibility` branch.** All commits landed here per "stay-on-branch" parallel mode (USAGE.md §"Multiple sprints in one workdir"). Multiple sprints (pipeline-onboarding-fidelity backfill + audit-driven-fidelity-v1 + harness-deterministic-phases-v1 + others) co-existed on the same branch via SPRINT_SLUG_OVERRIDE env disambiguation.

## Patterns extracted (5 for ruflo memory)

### Pattern 1: lifeos-feature-flag-pipeline-emission

**When**: refactoring high-traffic pipeline behavior with verify-violation downside risk.
**Do**: gate ALL new behavior behind a single env flag (LIFEOS_PIPELINE_EMISSION_V2). Keep pre-fix path as default. Snapshot-fixture harness asserts both flag-off (pre-fix) and flag-on (post-fix). Flip flag default only AFTER cutover criteria pass on synthetic fixtures.
**Example**: weekShape.ts 30+ duration + anchor changes in this sprint.

### Pattern 2: lifeos-pre-migration-cleanup-not-valid

**When**: adding a CHECK constraint to a column with existing legacy bad data (freeform text in enum-array column).
**Do**: migration runs `UPDATE` cleanup FIRST stripping non-conforming values, then `ALTER TABLE ... ADD CONSTRAINT ... NOT VALID`, then `VALIDATE CONSTRAINT` in a second step. Idempotent re-run safe.
**Example**: migration 0079 dietary_restrictions CHECK with pre-step strip.

### Pattern 3: lifeos-share-with-ai-scheduler-consent-default-false

**When**: adding a column that controls third-party data sharing (PII to Gemini).
**Do**: migration `ADD COLUMN ... NOT NULL DEFAULT false`. NO backfill UPDATE that flips existing rows to true. Onboarding UI defaults checkbox unchecked. Re-onboarding captures explicit consent. Snapshot test asserts `share=false → prompt-block text === ''`.
**Example**: migration 0078 + medicalContext.ts:65 filter + medicalContext.test.ts AC-W1-SEC1.

### Pattern 4: lifeos-retry-rubber-stamp-detection

**When**: pipeline-orchestrator that retries failed stages.
**Do**: `shouldStageActuallyRun(stage, ctx)` checks prior stage outcome + DB row diff vs pipelineStartedAt. Skip if no work, re-run if prior failed. Guard with `RUBBER_STAMP_THRESHOLD_MS=5` — any stage that "completes" in <5ms is a synthetic failure (the bug we caught: 91ms total pipeline marking 5/7 stages completed but doing 0 work).
**Example**: runPipeline.ts:shouldStageActuallyRun + 7 unit tests.

### Pattern 5: lifeos-synthetic-fixture-cutover-gate

**When**: large pipeline-behavior refactor with no clear "this is done" signal.
**Do**: encode the expected post-fix world as JSON fixtures with `expected_pipeline_result` block per fixture. CI harness asserts at flag-off (pre-fix, asserts structural validity only) + flag-on (post-fix, asserts the expected_result). Flip default flag when fixtures pass.
**Example**: **tests**/pipeline-fixtures/{davit,levan,**edge1**,**edge2**}.json + pipeline-emission-fixtures.test.ts.

## CLAUDE.md updates proposed

- `apps/lambdas/ai-scheduler-lambda/CLAUDE.md` — already updated by Swarm Prep (V2 flag cutover criteria) + Swarm C (R-F4 feedback metrics + dashboard panel build).
- `.env.example` — already extended with `LIFEOS_PIPELINE_EMISSION_V2=0` + `LIFEOS_AI_FEEDBACK_TIMEOUT_MS` overrides.
- `docs/sprints/_guides/migrate-remote-runbook.md` — NEW per R-X4, becomes the canonical operator runbook for future sprints with migrations.

## Followups

1. **`onboarding-medical-v2`** sprint — wire R-O7 deferred fields (exercises_to_avoid + biggest_previous_quit_reason + excluded_muscle_groups + excluded_movement_patterns) into onboarding step 10 UI redesign.
2. **`test-debt-v1`** sprint — fix 8 pre-existing test failures attributed during verify phase (pipeline-orchestrator.test.ts × 5, pipeline-workouts.test.ts × 2, pipeline-weekShape.test.ts × 1).
3. **`security-audit-followup-v1`** sprint — address 9 audit-worker vulnerability findings (command-injection in github-safe.js, temp-file permissions in github-safe.js, input-validation in memory.js, + 6 more).
4. **Operator deploy ceremony** — apply migrations 0078-0083 to remote per docs/sprints/\_guides/migrate-remote-runbook.md.
5. **Flag flip** — after operator confirms Davit fixture passes on remote, set `LIFEOS_PIPELINE_EMISSION_V2=1` in Vercel + Lambda env. Document the date + git SHA.
6. **Coordination fix: Swarm F spreadAnchorCollisions priority** — bump WIND_DOWN above HEALTH at sleep-anchored slots (per Swarm E note + Swarm H test residuals).
7. **Coordination fix: runPipeline.ts pickRerunTarget** — broaden to honor R-V2's new `unlinked.${entityType}` buckets (Swarm G R-L6 partially did; remaining narrowing in runPipeline.ts).
8. **Token aggregation completeness (R-L6 follow-up)** — workouts-lambda sub-Lambda invocation tokens still bubble via per-stage row; full bubble-up to total_tokens_used needs cross-Lambda boundary instrumentation.
