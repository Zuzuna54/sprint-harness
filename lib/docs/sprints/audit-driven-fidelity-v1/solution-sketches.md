# Solution Sketches — audit-driven-fidelity-v1

> Per USAGE.md Day ½ — alternatives + rejection rationale per wave / track.

## Sketch S1 — Wave-1 mechanical (Days 1-7, 18 ACs across T1+T3+T4+T5)

### Alternative A — Parallel-track agent swarm (CHOSEN)

Spawn 4 specialized agents in parallel:

- `backend-dev` claim → T1 onboarding-persistence (R-O1..O8, 8 ACs across 4 lambdas)
- `backend-dev` claim → T3 response-contract-completion (R-C1..C5, 5 ACs across supplements + grocery)
- `backend-dev` claim → T4 ai-feedback-resilience (R-F1..F4, 4 ACs in ai-scheduler-lambda only)
- `frontend` claim → T5 null-meal-id guard (R-N1, 1 AC in nutrition route fetcher)

Each agent runs TDD: failing test → fix → green → review-agent diff. Claims dispatcher prevents file-collisions.

**Pros:** parallelism = 7-day window fits 18 ACs. T4 isolates to one lambda (no cross-collision). T5 is frontend-only.

**Cons:** T1 touches 4 lambdas (auth, workouts, supplements, grocery) + 1 web area — coordination risk. Mitigation: explicit file-claim per AC at wave-start.

### Alternative B — Single-author sequential

Run all 18 ACs in one branch by one author. **Rejected**: 18 ACs × ~30min each = 9h work in a 7-day window leaves no buffer for the 30-AC Wave 2.

### Alternative C — Defer T4 (ai-feedback) entirely

Treat AbortError fallback as acceptable since rules return correct verdicts. **Rejected**: the 100% fallback rate means users never see Gemini-nuance feedback. Strategic regression vs onboarding-flow-v2's intent.

---

## Sketch S2 — Wave-2 pipeline block-emission (Days 8-14, 30 ACs)

### Alternative A — Single-author refactor with feature flag (CHOSEN)

Land all 30 ACs behind `LIFEOS_PIPELINE_EMISSION_V2=1` flag in weekShape.ts + workouts.ts. Default off. Existing snapshot-fixture tests run both branches in CI. Flag flips on at Wave-2-day-6 after Davit-synthetic-fixture passes.

**Pros:** atomic switch; can rollback by flag flip not git revert; CI safety net.

**Cons:** flag adds branching in the hottest pipeline code. Mitigation: flag is config-only — branches converge after one release.

### Alternative B — Per-AC branches → merge train

Each R-D/R-A/R-L/R-V gets its own branch. **Rejected**: weekShape.ts is one file; merge conflicts after 3 simultaneous branches kill velocity.

### Alternative C — Rewrite weekShape.ts as v2 from scratch

Greenfield `weekShape-v2.ts` reading durations from a config map; flip imports at wave end. **Rejected**: 1100-line file; greenfield risk too high in 7 days. Refactor-in-place + flag is safer.

---

## Sketch S3 — Wave-3 backfill + cross-cutting (Days 15-21, 10 ACs)

### Alternative A — One PR per backfill correction + 1 PR for cross-cutting (CHOSEN)

R-B1..B6 are doc-only edits to prior sprint's state.json + proof/_.md + retro.md. Each commit clearly named `docs(sprints/pipeline-onboarding-fidelity): correct W_.\* claim`. R-X1..X4 fold into a single cross-cutting commit.

**Pros:** atomic, easy to audit each correction.

**Cons:** 6 small PRs is paperwork-heavy. Mitigation: bundle in one PR titled `chore(sprints): backfill correction batch`.

### Alternative B — Single squash commit

**Rejected**: harder to identify which prior-sprint claim was corrected.

---

## Sketch S4 — Schema migration approach (R-O5 dietary_restrictions CHECK)

### Alternative A — CHECK constraint with array_unnest cast (CHOSEN)

```sql
ALTER TABLE fitness_profiles
  ADD CONSTRAINT fitness_profiles_dietary_restrictions_enum
  CHECK (
    NOT EXISTS (
      SELECT 1 FROM unnest(dietary_restrictions) AS x
      WHERE x NOT IN ('gluten_free','dairy_free','vegan','vegetarian','pescatarian','keto','low_carb','low_fodmap','paleo','halal','kosher','none')
    )
  );
```

**Pros:** declarative, future writes auto-rejected, doesn't require trigger maintenance.

**Cons:** existing rows with freeform text (Davit + Levan) need cleanup BEFORE constraint applies. Migration pre-step: `UPDATE fitness_profiles SET dietary_restrictions = (SELECT array_agg(x) FROM unnest(dietary_restrictions) AS x WHERE x IN (...)) WHERE EXISTS(...)`.

### Alternative B — BEFORE INSERT/UPDATE trigger

**Rejected**: trigger maintenance over time is heavier than a CHECK.

### Alternative C — Application-layer enforcement only

Already in place at meals stage (W1.6 strip). **Rejected**: doesn't prevent DB pollution at write time, only sanitizes at read.

---

## Sketch S5 — `age` column reconciliation (R-O4)

### Alternative A — PG GENERATED COLUMN (CHOSEN)

```sql
ALTER TABLE fitness_profiles
  DROP COLUMN age,
  ADD COLUMN age INT GENERATED ALWAYS AS (
    DATE_PART('year', AGE(NOW(), (SELECT date_of_birth FROM user_profiles WHERE user_profiles.user_id = fitness_profiles.user_id)))::INT
  ) STORED;
```

**Pros:** single source-of-truth (DOB); no app-layer sync needed.

**Cons:** depends on user_profiles row existing. Mitigation: FK constraint guarantees it.

### Alternative B — Drop both age columns

**Rejected**: 9 readers reference fitness_profiles.age (audit found in prior sprint). Migration cost too high.

### Alternative C — App-layer compute on every read

**Rejected**: scatters age-computation logic across N consumers.

---

## Sketch S6 — Wave structure cadence (3×7 vs other splits)

### Alternative A — 3×7 days (CHOSEN per user decision)

Week 1 = mechanical, Week 2 = deep, Week 3 = paperwork+verify. Each ends with a hard wave-close commit + 1-day buffer to next.

**Pros:** clean cadence; matches AC complexity gradient.

**Cons:** Week 3 may run short if backfill + verify finishes early; buffer can be used for hardening or rolled into early ship.

### Alternative B — 5+10+6 (mechanical heavier, deep gets more time)

**Rejected** by user. Sticking with 7+7+7.
