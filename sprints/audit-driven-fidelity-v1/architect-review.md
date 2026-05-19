# Architect Review — audit-driven-fidelity-v1

> Reviewer: principal architect (Claude). Date: 2026-05-19. Scope: 58 ACs / 21 days / 3 waves / 6 tracks. Source: spec.md + master-requirements-2026-05-19.md.

---

## TL;DR Verdict

**NEEDS_CHANGES** — ship-blocking issues are narrow and addressable in 1 day of spec amendment. Wave structure is sound; Wave 1 parallelism is safe; Wave 2 is the genuine risk and is under-specified on fixture strategy; Wave 3 is feasible but only if R-X1 (untracked sprint dir restore) is done on Day 1. See §6.

---

## 1. Wave 1 Boundary Integrity (Days 1-7, ~18 ACs)

**Claim:** T1 (8) + T3 (5) + T4 (4) + T5 (1-2) parallelize cleanly across 5 lambdas.

**Module-touch matrix:**

| Track | Lambda(s)                            | DB migrations | UI files             | Shared deps                            |
| ----- | ------------------------------------ | ------------- | -------------------- | -------------------------------------- |
| T1    | workouts-lambda, auth-lambda         | 0078-0082     | onboarding step 9,10 | packages/types/fitnessProfile, medical |
| T3    | supplements-lambda, grocery-lambda   | none          | none                 | packages/types HF-A pattern            |
| T4    | ai-scheduler-lambda (`/ai/feedback`) | none          | LiveFeedbackRow.tsx  | env config                             |
| T5    | nutrition-lambda (read-side guard)   | none          | MealSwapModal        | useQuery enabled-gate                  |

**Cross-cutting risk:**

- T1 R-O5 (CHECK constraint on `dietary_restrictions`) + T2 Wave-2 `meals` stage both read dietary_restrictions. Wave 1 fixes write-side enforcement; Wave 2 trusts it. **Safe**, ordering is correct.
- T1 R-O6 (`share_with_ai_scheduler` column) is consumed by `medicalContext.ts` which Wave-2 workouts stage uses. Wave 1 adds the column + default-false; Wave 2 prompt builder needs to honor it. **Soft coupling — list as Wave-2 input dep, not blocker.**
- T1 R-O4 (age column) touches `fitness_profiles` — same table as T2 reads in foundation/weekShape. Generated-column migration is safe; readers unaffected. **Safe.**
- T3 + T5 are fully independent (separate routes, separate lambdas, no shared types).
- T4 timeout config touches an env var only — fully isolated.

**Parallelism verdict: SAFE.** Distinct files, distinct lambdas, additive migrations only. No two ACs touch the same line.

**Sequencing recommendation inside Wave 1:**

1. Day 1: R-X1 (commit untracked prior sprint), R-O5 dietary_restrictions pre-migration cleanup query (audit existing Levan+Davit rows).
2. Days 2-3: migrations 0078-0082 land first (everything else depends on column existence).
3. Days 4-7: T1 Zod + UI, T3 schemas, T4 timeout, T5 guard — fan out.

**Wave 1 gaps:**

- Spec doesn't name owners per track. With 18 ACs across 4 tracks in 7 days, single-agent serial work = 0.5 AC/day pace which is tight. Either parallelize across agents or extend Wave 1 by 2 days.
- R-O5 pre-migration cleanup is mentioned in §J as a risk but not as an AC. **Add explicit AC: "T1.5a — Pre-migration audit + clean of freeform `dietary_restrictions` rows."**

---

## 2. Wave 2 Risk Surface (Days 8-14, 30 ACs)

**This is the load-bearing wave.** T2 = 30 ACs all in or adjacent to `weekShape.ts` (already 800+ lines per the A7-A12 line references). Single file = single regression surface.

**Observations:**

| Sub-track                             | ACs | Risk                                                           |
| ------------------------------------- | --- | -------------------------------------------------------------- |
| 2A duration fixes (R-D1..D9)          | 9   | LOW per-AC; HIGH aggregate (every emit path changes)           |
| 2B anchor positioning (R-A1..A12)     | 12  | HIGH — collision resolution algorithm is new logic, not a swap |
| 2C linkage + duplicate-key (R-L1..L6) | 6   | HIGH — R-L1/L2/L3 are the bug that broke both onboardings      |
| 2D verify rules (R-V1..V3)            | 3   | MED — macro_band fix is meals-math, not weekShape              |

**Test fixture strategy — UNDER-SPECIFIED.** §J mentions "tight regression tests against snapshot fixtures of Davit's week" but spec doesn't define:

- Fixture format (JSON snapshot? SQL dump? synthetic generator?)
- Fixture count (Davit + Levan is N=2; insufficient for 12 anchor rules)
- Golden-file diff tooling
- How to test BEFORE Wave 2 work begins (need at least 1 synthetic + 1 real fixture frozen Day 8)

**Recommendation:** Add Wave 2 Day 8 pre-work AC:

- **T2.0a — Freeze 4 fixture profiles:** Davit (real), Levan (real), synthetic-edge (early-bird 04:00 wake, late-night work), synthetic-default. Snapshot each user's `fitness_profile + goal_settings + work_schedule + user_supplements + meals_preferences` as JSON. Build `runPipelineFromFixture(fixtureId)` test harness emitting time_blocks for assertion.
- **T2.0b — Golden-file harness** for `weekShape.emit()` output. Each anchor/duration AC commits a golden-diff in same PR.

**Feature flag `LIFEOS_PIPELINE_EMISSION_V2` is correct** but spec doesn't define cutover criteria. Recommend: flag flips to default-on only when all 4 fixtures pass 0-verify-violations.

**Single-stage failure cascade risk (R-L3):** the spec correctly identifies that pipeline retry rubber-stamps. R-L3 fix needs to be Day-8 before any of D1-D9 lands, otherwise dev-loop testing produces false greens.

**Wave 2 sequencing (recommended):**

1. Day 8: T2.0a fixtures + T2.0b harness + R-L3 (no-op retry detection).
2. Day 9: R-L1 (workouts ON CONFLICT) + R-L2 (orphan cleanup) — unblock workouts stage.
3. Days 10-11: R-D1..D9 (duration reads from profile columns).
4. Days 12-13: R-A1..A12 (anchor collision spreader + relative-anchor refactor).
5. Day 14: R-V1..V3 + flag flip + Davit-synthetic E2E.

**Concern:** 30 ACs in 7 days = ~4.3/day with deep refactor. Single-engineer pace is unrealistic. **Either staff this with 2 engineers or descope R-A7..A12 (the P2 hard-coded-anchor refactors) to a Wave 4 follow-up.**

---

## 3. Wave 3 Feasibility (Days 15-21, ~10 ACs)

**Composition:** T6 backfill (6 paperwork ACs) + cross-cutting (R-X1..X4, 4 ACs).

**Time budget:** 6 docs ACs ≈ 0.5d each = 3 days. R-X1 is 1-line `git add + commit` if done Day 1 (see §1). R-X2 (sprint-close pre-flight) is ~1 day. R-X3 (RLS audit on dietary_restrictions_audit) is ~0.5 day. R-X4 (migration tracker hygiene) is operator-gated and may slip.

**Total Wave 3: ~5 working days vs 7 allocated.** Fits with headroom for spillover from Wave 2.

**Risk:** If Wave 2 slips by even 1 day, Wave 3 absorbs it cleanly. But R-X1 must NOT wait for Wave 3 — the untracked dir loses backfill on next `git clean -fd`. **Move R-X1 to Wave-1 Day-1 as a hard prerequisite.**

**T6 backfill validation pattern:** spec doesn't define how a "Production" claim is re-verified. Recommend: each R-B* AC produces `proof/W*.md`with live SQL`\d table_name` output showing column existence (or absence) at HEAD.

---

## 4. Conflict Analysis: 6 Deferred Follow-ups

| Prior deferred                              | This sprint covers?                                                              | Conflict?                                                                          |
| ------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| W4.1-macros (drop goal_settings macro cols) | Mentioned in §C as "drop after consumer audit confirms zero readers" — but no AC | **GAP**: not in 58-AC list. Either add as T1.9 or explicitly defer to next sprint. |
| W4.2-training-freq reconciliation           | YES — R-O8 (P2)                                                                  | No conflict; same fix.                                                             |
| W4.2-cook-at-home reconciliation            | Partial — §C mentions but no R-ID                                                | **GAP**: add R-O8b or explicitly defer.                                            |
| W4.3-notes-json (work_schedules)            | Not covered                                                                      | **DEFER OK** — orthogonal to audit findings.                                       |
| W4.5b (deferred consumer-migration)         | YES — R-O8                                                                       | No conflict.                                                                       |
| HF-D meal cold-fallback unlinked            | YES — R-L4                                                                       | No conflict; R-L4 reopens it.                                                      |

**Net:** 1 hard gap (W4.1-macros) + 1 soft gap (cook-at-home). Both are P2 cleanup; can be deferred explicitly. **Add a §K — Explicit Deferrals section to spec.md** naming what is NOT in scope, so prior-sprint deferrals don't silently reappear unresolved.

---

## 5. Risk Register

| ID  | Risk                                                                                            | Sev  | Likelihood              | Mitigation                                                                                                                                                         |
| --- | ----------------------------------------------------------------------------------------------- | ---- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| H1  | Wave 2 weekShape.ts refactor breaks live planner for Levan/Davit                                | HIGH | MED                     | Feature flag `LIFEOS_PIPELINE_EMISSION_V2` (already specced); Day-8 fixture freeze; golden-file diffs per AC.                                                      |
| H2  | 30 ACs in 7 days for Wave 2 is overcommitted for solo engineer                                  | HIGH | HIGH                    | Descope R-A7..A12 (P2 hard-coded-anchor cleanup) to Wave 4 follow-up sprint, OR staff with 2 engineers.                                                            |
| H3  | R-X1 (untracked sprint dir) lost to `git clean`                                                 | HIGH | LOW-MED                 | Move to Wave-1 Day-1 prereq, before any other work.                                                                                                                |
| H4  | Pipeline retry rubber-stamp (R-L3) produces false greens during Wave 2 dev                      | HIGH | HIGH if not fixed first | Sequence R-L3 as Day-8 first task, before D1-D9.                                                                                                                   |
| H5  | CHECK constraint on dietary_restrictions rejects existing rows                                  | HIGH | HIGH                    | Pre-migration cleanup AC (T1.5a, recommended §1).                                                                                                                  |
| M1  | AI feedback timeout extension unmasks Gemini rate-limit issues                                  | MED  | MED                     | Add p95 dashboard (R-F4) BEFORE flipping timeout.                                                                                                                  |
| M2  | Test fixture coverage insufficient (N=2 real users) for 12 anchor rules                         | MED  | HIGH                    | Add 2 synthetic edge-case fixtures (T2.0a recommended §2).                                                                                                         |
| M3  | share_with_ai_scheduler default=false silently breaks medicalContext prompts that worked before | MED  | LOW                     | Backfill query: `UPDATE … SET share_with_ai_scheduler=true WHERE user_id IN (Davit, Levan)` if they want to keep current behavior, else accept new opt-in default. |
| M4  | Backfill state.json corrections reopen ACs that operators thought were closed                   | MED  | LOW                     | T6 ACs name the specific claim being corrected with proof file.                                                                                                    |
| L1  | Token-count rollup (R-L6) is observability-only, not user-facing                                | LOW  | LOW                     | Defer if Wave 2 over-runs.                                                                                                                                         |
| L2  | R-A7..A12 are P2 cosmetic refactors                                                             | LOW  | LOW                     | Already P2; descope freely.                                                                                                                                        |
| L3  | RLS audit (R-X3) finds a missing policy                                                         | LOW  | LOW                     | One-line policy add if so.                                                                                                                                         |

---

## 6. Verdict Rationale: NEEDS_CHANGES

**Sound:**

- Wave decomposition (mechanical → deep → paperwork) is correct.
- Track parallelism analysis holds (different lambdas, different files).
- Feature flag + per-wave rollback strategy is defined.
- AC-to-evidence linkage (Davit + Levan rows, log lines, file:line) is exceptional — every fix is traceable to a defect.

**Required changes before kicking off Day 1:**

1. **Move R-X1 to Wave-1 Day-1 prereq.** Don't risk losing the prior sprint dir for 14 days.
2. **Add T2.0a + T2.0b fixture+harness ACs to Wave 2 Day 8.** Without these, 30 ACs ship blind.
3. **Sequence R-L3 as Wave-2 Day-8 first task.** Otherwise retry rubber-stamps mask regressions during dev.
4. **Add T1.5a pre-migration cleanup AC.** R-O5 CHECK constraint will reject existing rows otherwise.
5. **Add explicit "§K Deferrals" section.** Name W4.1-macros + W4.2-cook-at-home + W4.3-notes-json as out-of-scope so they don't silently re-orphan.
6. **Pick ONE of:** (a) staff Wave 2 with 2 engineers, or (b) descope R-A7..A12 (P2 hard-coded-anchor cleanup) to a follow-up sprint. Spec currently implies solo at 4.3 ACs/day — unrealistic.
7. **Define `LIFEOS_PIPELINE_EMISSION_V2` cutover criteria** (e.g., "flag flips to default-on when all 4 fixtures pass 0-verify-violations"). Otherwise the flag is decorative.

**With those 7 edits, this becomes SHIP_READY.** All are spec amendments, not work additions — ~1 day of architect time to finalize.

---

## 7. Open Questions

- Who owns Wave 2? Solo or pair?
- Is the synthetic-Davit fixture user a seed file in `packages/db/seed/` or generated at test time?
- For R-O6 default=false — do we backfill existing Davit/Levan rows to `true` (preserve current Gemini behavior) or accept new opt-in default (silently changes prompt)?
- Does the spec assume migrations 0078-0082 are applied locally + remotely before Wave 2 starts? Migration tracker drift (recent memory key) suggests this needs an explicit gate.

---

## 8. Relevant Files

- `/Users/gio/Desktop/lifeos/docs/sprints/audit-driven-fidelity-v1/spec.md` — spec under review
- `/Users/gio/Desktop/lifeos/docs/sprints/_index/master-requirements-2026-05-19.md` — requirements source-of-truth
- `/Users/gio/Desktop/lifeos/docs/sprints/pipeline-onboarding-fidelity/retro.md` — deferred items from prior sprint
- `/Users/gio/Desktop/lifeos/docs/sprints/pipeline-onboarding-fidelity/spec.md` — W4.\* defer rationale
