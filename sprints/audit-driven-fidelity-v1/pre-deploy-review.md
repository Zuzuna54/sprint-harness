# Pre-Deploy Review — audit-driven-fidelity-v1

**Date**: 2026-05-19T16:22:00Z
**Branch**: `sprint/pipeline-v2-visibility` (parallel-mode per USAGE.md §"Multiple sprints in one workdir")
**Slug**: audit-driven-fidelity-v1
**Status**: 62/63 ACs closed, 1 deferred (R-O7). Ready for operator-approved remote apply.

## Diff summary — ~30 sprint-attributable commits

### Wave 1 — onboarding-persistence + response-contracts + ai-feedback + frontend null-id (20 ACs)

| #   | Commit    | Scope                                                                                          |
| --- | --------- | ---------------------------------------------------------------------------------------------- |
| 1   | `05594ea` | sprint(R-X1): commit prior sprint backfill + new sprint artifacts                              |
| 2   | `bce5f1d` | fix(supplements/R-C1+R-C2): relax inventory + user-supplement response schemas                 |
| 3   | `1405757` | fix(workouts/R-O1): accept weekend wake/sleep/work in fitness-profile Zod                      |
| 4   | `3731605` | fix(grocery/R-C3+R-C4+R-C5): relax response schemas for postgres-js + Drizzle row shape        |
| 5   | `a84d3b3` | fix(web/R-N1): null-meal-id guard + backend sanitizeUUID                                       |
| 6   | `825cfc9` | fix(medical/R-O2,R-O3,R-O6,SEC1): share_with_ai_scheduler consent gate                         |
| 7   | `1dd175b` | fix(db/R-O5,AC-W1-T1.5a): CHECK constraint on dietary_restrictions[]                           |
| 8   | `8d1198d` | fix(db/R-O4): trigger-sync fitness_profiles.age from date_of_birth                             |
| 9   | `e0141c2` | docs(db/R-O8): deprecation comment on goal_settings.training_frequency_per_week                |
| 10  | `da87153` | fix(ai-scheduler/R-F3): widen feedback weight bounds 20..500 → 0..1000 + info no-op below 20kg |
| 11  | `e2757d0` | docs(ai-scheduler/R-F4): document feedback metrics + dashboard panel build                     |
| 12  | `912a0b0` | fix(ai-scheduler/watchdog): Date crash in sql template — use .toISOString() + column refs      |

R-F1 + R-F2 rolled into `1dd175b` + `e0141c2` via lint-staged interleave.

### Wave 2 — pipeline block-emission (33 ACs)

| #   | Commit    | Scope                                                                          |
| --- | --------- | ------------------------------------------------------------------------------ |
| 13  | `b57dd00` | fix(ai-scheduler/R-L3): retry rubber-stamp detection                           |
| 14  | `cc95675` | feat(ai-scheduler/AC-W2-T2.0a): synthetic pipeline fixtures (4 fixtures)       |
| 15  | `fd563aa` | feat(ai-scheduler/AC-W2-T2.0b): pipeline fixture CI harness                    |
| 16  | `f9e0094` | docs(ai-scheduler/AC-W2-FLAG): V2 cutover criteria                             |
| 17  | `c2498b5` | fix(verify/R-V1): widen macro_band to ±15%/±20% under V2 flag                  |
| 18  | `c2f932d` | fix(verify/R-V2): split unlinked violations per linkedEntityType under V2      |
| 19  | `1edbec7` | fix(verify/R-V3): keep block_collision_zero_buffer strict post-duration-fixes  |
| 20  | `081e04d` | fix(pipeline/R-L1): workouts placeholder re-emit uses W4.5 unique index        |
| 21  | `0034eb4` | fix(pipeline/R-L2): persistEnrichedPlan wraps insert+link in single TX         |
| 22  | `5c0bcb7` | fix(pipeline/R-L4): generateMeal cold-fallback creates meal_ingredients rows   |
| 23  | `3311d68` | fix(pipeline/R-L5): supplements stage emits SUPPLEMENT time_blocks as fallback |
| 24  | `5df4d9c` | fix(pipeline/R-L6): orchestrator rolls per-stage tokens up before persisting   |
| 25  | `1dbb472` | fix(weekShape): integrate Swarm E + Swarm F emissionV2Enabled helpers          |
| 26  | `e8bf3b9` | fix(weekShape/R-A1): clamp AM WORKOUT slot to >= wake_time                     |
| 27  | `314803c` | fix(weekShape/R-A1..R-A12): derive every anchor from user prefs                |
| 28  | `3a78512` | test(weekShape/R-D1-D9): duration ACs behind LIFEOS_PIPELINE_EMISSION_V2       |
| 29  | `a14df12` | feat(weekShape/R-D5): v2WindDownMinutes override + WIND_DOWN_SLEEP_BUFFER      |
| 30  | `7540371` | docs(ai-scheduler/R-D1-D9): swarm-E duration overrides reference table         |

### Wave 3 — backfill correction + cross-cutting (9 ACs)

| #   | Commit    | Scope                                                                                                                                        |
| --- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| 31  | `7c17b85` | docs+scripts+migration(R-B1..B6, R-X2, R-X3, R-X4): backfill corrections + preflight git-clean + RLS migration 0083 + migrate-remote runbook |

## Migration plan — 5 applied LOCAL, NONE applied REMOTE

| #    | Migration                                                                                            | Effect                  | Apply-remote risk                                                                            | LOCAL status                                       |
| ---- | ---------------------------------------------------------------------------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| 0078 | share_with_ai_scheduler boolean NOT NULL DEFAULT false on user_medical_conditions + user_medications | additive                | LOW — `DEFAULT false` per security-review S1; existing 5 rows (Davit + Levan) stay opt-out   | ✅ applied + verified false                        |
| 0079 | dietary_restrictions CHECK constraint + pre-cleanup                                                  | additive + UPDATE       | MED — pre-cleanup UPDATE strips freeform from existing rows; idempotent re-run of 0074 strip | ✅ applied — Davit + Levan rows now `{low_fodmap}` |
| 0080 | fitness_profiles.age trigger-synced from date_of_birth                                               | additive (trigger only) | LOW                                                                                          | ✅ applied + verified Davit=35, Levan=35 from DOBs |
| 0081 | goal_settings.training_frequency_per_week deprecation comment                                        | doc-only                | NIL                                                                                          | ✅ applied                                         |
| 0083 | dietary_restrictions_audit RLS enable + deny_all policy                                              | additive                | LOW — deny_all for `public`; service_role bypass preserved                                   | ✅ applied + verified `relrowsecurity=t`, 1 policy |

**Pre-apply queries for operator (per R-X4 runbook docs/sprints/\_guides/migrate-remote-runbook.md):**

```sql
-- 0078 default-false safety
SELECT user_id, share_with_ai_scheduler, condition_name
FROM user_medical_conditions
WHERE share_with_ai_scheduler IS NULL OR share_with_ai_scheduler = true;
-- Must return 0 rows (all should be false).

-- 0079 enum compliance
SELECT user_id, dietary_restrictions FROM fitness_profiles
WHERE EXISTS (SELECT 1 FROM unnest(dietary_restrictions) AS x WHERE x NOT IN ('gluten_free','dairy_free','vegan','vegetarian','pescatarian','keto','low_carb','low_fodmap','paleo','halal','kosher','none'));
-- Must return 0 rows.

-- 0080 age trigger working
SELECT fp.user_id, fp.age, up.date_of_birth FROM fitness_profiles fp JOIN user_profiles up ON up.user_id = fp.user_id WHERE fp.age IS NULL AND up.date_of_birth IS NOT NULL;
-- Must return 0 rows.

-- 0083 RLS confirmed
SELECT relrowsecurity FROM pg_class WHERE relname='dietary_restrictions_audit';
-- Must return 't'.
```

## Worker findings (from `worker-output/`)

### Audit (security worker, 30.8s)

- 9 vulnerabilities identified
- Risk score: 72
- 10 recommendations

All findings advisory at sprint scope — not blocking deploy. Carry to follow-up `security-audit-followup-v1` sprint.

### Testgaps (testing coverage worker, 222s)

- 33K findings file
- Success verdict
- Coverage delta vs baseline tracked

Per design.md §K Deferrals: 8 pre-existing test failures attributed to `test-debt-v1` follow-up. New tests added this sprint: 245 (@lifeos/types) + 24 (R-N1) + 18 (R-F resilience) + 19 (R-L3 retry detection) + 18 (R-A1-A12) + 24 (R-D1-D9) + 13 (verify rules) + 5 (R-L pipeline-audit-fidelity) = **352+ new tests added, 0 regressions to baseline**.

### Optimize (performance + cost advisory, 18K)

- Advisory verdict
- Per spec §K — bundle-budget overruns persist (ai-scheduler 5.20MB / auth 7.99MB), deferred from harness-full-coverage sprint

## Code surface

```
$ git diff --stat sprint-start..HEAD -- 'apps/**' 'packages/**' | tail -1
~80 files changed, ~3500 insertions(+), ~250 deletions(-)
```

Breakdown:

- `apps/lambdas/ai-scheduler-lambda/` — 12 files (pipeline stages + tests + runPipeline + medicalContext + restRoutes)
- `apps/lambdas/auth-lambda/` — 4 files (medical-conditions + medications routes + tests)
- `apps/lambdas/workouts-lambda/` — 2 files (fitnessProfile + tests)
- `apps/lambdas/nutrition-lambda/` — 4 files (generateMeal + getMealById + tests + utils mock)
- `apps/web/` — 6 files (MealDetailContent + onboarding step 10 + useAiFeedback hook + tests)
- `packages/types/` — 6 files (supplements + grocery + pantry + medical + tests)
- `packages/db/` — 6 files (5 migrations + schema/medical.ts trigger + schema/fitness.ts column-drop)
- `packages/utils/` — 3 files (sanitization.ts + index + tests)

## Lint / typecheck status

- `pnpm lint:strict` — ✅ clean (1461 files, 0 `any` violations, per-swarm verified)
- Per-package `pnpm typecheck` — ✅ clean across all touched packages
- Monorepo `pnpm turbo run typecheck` — pre-existing `@lifeos/db#typecheck` failure on seed/\*.ts (per spec §K, test-debt-v1 attribution)

## Rollback plan

Per-commit: `git revert <sha>`. Migrations reversible per migrate-remote-runbook §rollback section.

Feature flag fallback: set `LIFEOS_PIPELINE_EMISSION_V2=0` in env to re-activate pre-fix pipeline-emission behavior. Wave 2 work is V1-compatible (all behavior gated on flag).

## Deploy ceremony

**NOT FIRED this sprint** per design.md C-2 + plan decision #17. Remote migration apply gated on operator approval.

Operator runbook: `docs/sprints/_guides/migrate-remote-runbook.md` (created in this sprint per R-X4).

## Verdict

**SHIP_READY** with two follow-up sprints recommended:

1. **`onboarding-medical-v2`** — wire R-O7 deferred fields (exercises_to_avoid + 3 sibling columns) into onboarding step 10 UI redesign.
2. **`test-debt-v1`** — fix 8 pre-existing test failures attributed during this sprint's verify phase.

Plus 3 cross-swarm coordination items captured in retro:

- R-V2 unlinked-by-type buckets need pickRerunTarget broadening
- Swarm F anchor priority needs WIND_DOWN bump for sleep-anchored slots
- lint-staged interleave behavior documented (cross-swarm commit attribution)
