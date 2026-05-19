# Sprint audit-driven-fidelity-v1: Two fresh onboardings (Levan + Davit, 2026-05-19) and a 1500-line backend log du

> Assembled from wizard sections by `sprint-wizard-assemble.mjs` on 2026-05-19T14:18:12.708Z.

## Status

- **Phase:** spec-wizard
- **Day:** 0 of 14
- **Started:** 2026-05-19T14:14:54Z
- **Gates passed:** (none)
- **Drift score (latest):** N/A
- **Wizard sections captured:** A,B,C,D,E,F,G,H,I,J

---

## §A — Problem & Vision

### Problem statement

Two fresh onboardings (Levan + Davit, 2026-05-19) and a 1500-line backend log dump surfaced 58 distinct defects spanning every layer: wizard fields silently dropped before reaching the DB (weekend wake/sleep, medication dose/severity, share_with_ai_scheduler missing), pipeline emits zero-duration MEAL/ACTIVITY/SUPPLEMENT/WIND_DOWN blocks because anchors collide at the same minute, WORK day duration is 200min/day instead of the user-stated 480, AM workouts are scheduled BEFORE wake_time, the workouts stage throws PG 23505 on every pipeline run (HF-C only fixed weekShape), all 174 time_blocks are unlinked, response contracts on supplements/grocery/pantry endpoints fail Zod parse on every request, AI feedback Gemini calls 100% timeout at 600ms forcing rule fallback, and the prior pipeline-onboarding-fidelity sprint backfill contains 6 inaccurate Production claims.

### Who suffers

- Three personas all bleed: (1) new onboarders like Davit lose 60% of their stated profile to silent drops + get a schedule with all blocks unlinked, all meals zero-duration, all workouts wrong-duration; (2) returning users hit the supplement contract-mismatch warnings on every page load (UI works but logs are noise); (3) operators (Gio + Zefyra) can no longer trust state.json verdicts because the prior sprint claimed 21/21 Production while 6 ACs are factually broken on live data. Trust in the audit trail is the deepest wound.

### Why now

Davit was the first real user onboarded post pipeline-onboarding-fidelity ship. His generated week 2026-05-18 ran 73ms total, marked partial with 15 verify violations including 25 unlinked time_blocks. Levan ran an MANUAL retry that rubber-stamped 91ms completed but produced 29 verify violations. Both pipelines failed workouts stage with PG 23505 despite HF-C shipping. The trigger: we cannot onboard a second beta user with a straight face until these are closed.

### Strategic fit

This is BOTH strategic and tactical. Strategic: the 10-min/day promise depends on the generated schedule being CORRECT — a planner full of zero-duration meals and pre-wake workouts violates the brand promise. Tactical: 58 ACs is broad but each is small. The right metaphor is a 21-day fidelity audit pass before opening beta.

### Success vision

Three weeks from now, a synthetic-Davit equivalent runs ONBOARDING pipeline and: (a) all stages complete, (b) verify reports 0 violations, (c) every emitted time_block has correct duration and an anchor that respects user wake/sleep/meal times, (d) every MEAL/SUPPLEMENT/WORKOUT block has linked_entity_id, (e) weekend_wake_time persists when toggled, (f) 0 response-contract-mismatch warnings in dev log, (g) AI feedback returns source=gemini 80%+ of calls, (h) backfill state.json claims match live DB reality.

### Refinement

---

## §B — Business Logic & Domain Rules

### Entities

- Tax model = data fidelity. Every wizard input lands in its DB column with no silent drop; every emitted time_block has a duration > 0 and an anchor derived from user prefs; every cross-stage entity has a linked_entity_id where applicable. Verify reports 0 violations on a clean ONBOARDING run.

### State transitions

Domain rules: (a) freeform text never reaches dietary_restrictions[] (DB CHECK constraint), (b) workouts stage time_blocks emission uses ON CONFLICT DO NOTHING like weekShape, (c) pipeline retry detects no-op stages and either runs them or hard-fails (never rubber-stamps), (d) AM workouts NEVER start before fitness_profile.wake_time, (e) WORK block duration = work_schedules.hours_per_week / weekday_count, (f) reminder blocks (5-min SUPPLEMENT) cant collide with their parent block (MEAL with-meal supplement gets +5min buffer).

### Invariants

- Invariants: every emit must read durations + anchors from fitness_profile/user_supplements (no hard-coded MEAL=30 / SUPPLEMENT=5 / CARDIO=30 / WORK_DAILY=200). Migration history is monotonic + idempotent. Backfill state.json claims match column existence in pg_catalog.

### Calculations / aggregations

_(none)_

### Edge cases

_(none)_

### Refinement

---

## §C — Data & Schema

### New tables/columns

Schema changes (5 migrations, all additive/CHECK): (1) fitness_profiles: extend Zod schema to accept weekend_wake_time + weekend_sleep_time + weekend_work (columns exist, only Zod follow-up missed). (2) user_medical_conditions: add share_with_ai_scheduler bool NOT NULL DEFAULT false. (3) user_medications: same column. (4) ADD CHECK CONSTRAINT on fitness_profiles.dietary_restrictions array elements ∈ dietary_restriction_enum (or trigger). (5) age column either compute from DOB via stored generated column or drop both duplicates.

### Relationships

- Source-of-truth choices: (a) training_frequency lives in fitness_profiles only; goal_settings.training_frequency_per_week column drops. (b) cook_at_home lives in goal_settings only; fitness_profiles.cook_at_home drops if duplicate. (c) macro target columns in goal_settings (protein/carbs/fats_target_g) drop after consumer audit confirms zero readers.

### RLS policies

RLS: dietary_restrictions_audit (W1.6 follow-up) needs service-role-only policy. New share_with_ai_scheduler columns inherit existing user-id-keyed policies on parent tables.

### Migration strategy

_(not provided)_

### PII / encryption

_(no PII touched)_

### Refinement

---

## §D — API Surface

### Endpoints

Existing routes modified (no new routes): (1) PUT /workouts/fitness-profile Zod: add weekendWakeTime/weekendSleepTime/weekendWork. (2) POST /auth/medical-conditions Zod: add severity + diagnosed_date + share_with_ai_scheduler. (3) POST /auth/medications Zod: add structured dose_amount + dose_unit + frequency + share_with_ai_scheduler. (4) GET /supplements/user/:id response: nullable updatedAt. (5) GET /supplements/inventory: same nullable pattern as HF-A. (6) GET /grocery/lists/:id: nullable estimatedCost + select items.listId+name. (7) GET /grocery/pantry: NumericFromDb transform for numeric-string columns. (8) PUT /grocery/items/:id: same fixes. (9) POST /ai/feedback: configurable timeout (default 1500ms locally, env-driven prod).

### Request/response Zod schemas

AI feedback resilience: extend AbortController timeout from 600ms→2000ms locally (env LIFEOS_AI_FEEDBACK_TIMEOUT_MS). Add exponential backoff on circuit-breaker re-open. Add p95 latency metric to existing CloudWatch namespace.

### Auth requirements

_(LifeOS default: requireUser() on every route)_

### Error cases

_(none)_

### External APIs

_(none)_

### Refinement

---

## §E — UI Components & Pages

### New pages

Onboarding step 10 (foundation-medical) extension: per-condition severity dropdown (mild/moderate/severe) + diagnosed-date input + share_with_ai_scheduler toggle. Per-medication dose_amount + dose_unit + frequency structured form (replace freeform dosage string).

### New components

Frontend null-meal-id fix: MealSwapModal + meal-detail route guard fetcher (do not fire query when id is falsy/string-null). Add useQuery enabled-gate.

### Server vs client split

_(not provided)_

### State management

_(not provided)_

### Mobile responsiveness

_(not provided)_

### Refinement

---

## §F — UX Flow & Interactions

### Happy path

Wizard flow updates: when 09-foundation-days has weekdays_same_as_weekends=false, require non-empty weekend_wake_time + weekend_sleep_time before advance. Step 10 medications must show severity+date fields when at least one condition is added; cant skip-advance with incomplete medical.

### Error paths

- Live feedback updates: when AI feedback returns source=rule, surface micro-indicator (small dot) in LiveFeedbackRow so user/team knows fallback fired. Currently silent.

### Empty states

_(none)_

### Loading states

_(none)_

### Transitions / animations

_(none)_

### Refinement

---

## §G — Visual Design & Brand

### Design system

No new brand/visual work. Existing tokens used. Severity dropdown + numeric stepper use existing primitives (NumericWithUnit, ChipMultiSelect).

### Typography / spacing / color

_(not provided)_

### Iconography

_(none)_

### Refinement

---

## §H — Integration Points

### LifeOS modules touched

- Modules: ai-scheduler-lambda (pipeline stages: foundation/weekShape/workouts/meals/supplements/aggregate/verify + medicalContext.ts), workouts-lambda (fitness-profile PUT), auth-lambda (medical-conditions/medications POST + work-schedule), supplements-lambda (4 GET routes), grocery-lambda (3 GET + 1 PUT route), nutrition-lambda (meal-id guards + cold-fallback ingredient-linkage), apps/web/onboarding (steps 09 + 10 + supplements + AI-feedback row), packages/db (5 migrations), packages/types (HF-A pattern extensions).

### External APIs

- External: Gemini Flash + Pro (timeout config + circuit breaker). No new external integrations. RevenueCat/Sentry/Vercel unchanged.

### Cross-module events

_(none)_

### Background workers / cron

_(none)_

### Refinement

---

## §I — Acceptance Criteria

### UI/E2E (Gherkin)

_(not provided)_

### Backend (INVEST)

_(not provided)_

### Performance bars

- P95 lambda response: < 800ms (LifeOS default)
- Payload: < 50KB
- DB queries per request: ≤ 2

### Manual QA checklist

_(none)_

### Refinement

---

## §J — Risks, Security, Rollback

### Security risks

- Top risks: (1) CHECK constraint on dietary_restrictions[] may reject existing Levan+Davit rows containing freeform text — need pre-migration cleanup. (2) Generated age column on fitness_profiles needs all readers re-verified (9 already found). (3) Wave-2 weekShape refactor is high-risk surface — emit-emitter changes can ripple into verify violations; mitigate by tight regression tests against snapshot fixtures of Davits week. (4) AI feedback timeout extension may surface rate-limit issues with Gemini that 600ms previously masked. (5) Untracked pipeline-onboarding-fidelity sprint dir loses the backfill if git clean -fd fires — commit immediately as R-X1.

### Privacy implications

Security: dietary_restrictions_audit RLS service-role-only confirmed in migration; share_with_ai_scheduler defaults false (PII safe). No new PII surfaces. medicalContext.ts prompt construction gated by new boolean.

### Rollback strategy

Rollback per wave: Wave 1 — per-commit git revert; Wave 2 — feature flag LIFEOS_PIPELINE_EMISSION_V2 (default off, flip-to-on at Wave-2-end via dev-server validation against Davit synthetic fixture); Wave 3 — paperwork-only, no rollback needed. Migration rollback: each migration reversible (0078-0082) with explicit DROP-rollback in same file.

### Open questions

_(none)_

### Refinement

---

## §K — Deferrals (explicitly out-of-scope, refile as next-sprint)

Added 2026-05-19 per architect-review NEEDS_CHANGES finding §5 (missing §K Deferrals section).

| ID                                                            | Deferred to                        | Rationale                                                                                                                        |
| ------------------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **Pulumi remote deploy**                                      | post-sprint manual                 | Per `pipeline-onboarding-fidelity` plan decision #17: operator approval required; this sprint applies 0078+ locally only         |
| **Onboarding step-10 redesign**                               | follow-up `onboarding-medical-v2`  | This sprint adds severity/diagnosed_date fields; full UX rework of medical step is bigger                                        |
| **Cold-fallback meal ingredient-linkage in nutrition-lambda** | follow-up `meals-cold-fallback-v1` | R-L4 fixes the trigger surface; the deeper `generateMeal.ts` ingredient-creation gap remains                                     |
| **Token-count aggregation across stages**                     | R-L6 partial                       | Sprint surfaces the gap but full attribution from workouts-lambda → orchestrator is its own engineering task                     |
| **CloudWatch dashboard build**                                | R-F4 partial                       | Sprint defines metric emitters; UI panel build is a follow-up                                                                    |
| **Bundle-budget overruns**                                    | next harness sprint                | Carried-over from harness-full-coverage AC-11 (ai-scheduler 5.20MB + auth 7.99MB over 5MB budget); not this sprint's scope       |
| **8 pre-existing test failures**                              | follow-up `test-debt-v1`           | Attributed to prior sprints per `pipeline-onboarding-fidelity/worker-output/testgaps.json`; we promise not to introduce new ones |

---

## Architecture amendments (2026-05-19 post-architect-review NEEDS_CHANGES)

Architect flagged 7 spec gaps. All 7 amendments folded in here, plus 4 security-review follow-ups added as proper ACs.

### Wave-ordering changes

- **R-X1 (commit untracked prior-sprint dir) MOVED from Wave 3 → Wave 1 Day 1.** Architect risk H4: 14-day delay risks `git clean -fd` destroying the backfill.
- **R-L3 (retry rubber-stamp detection) sequenced FIRST in Wave 2 Day 8.** Without this, all Wave-2 dev-loop iterations produce false-greens against stale partial state.

### New ACs added by amendment (5 total → spec total now 63 ACs)

- **AC-W1-T1.5a** (P0): Pre-migration cleanup of `fitness_profiles.dietary_restrictions[]` freeform strings BEFORE the CHECK constraint applies. Migration must use `NOT VALID` + `VALIDATE CONSTRAINT` two-step, OR inline cleanup of legacy Levan+Davit rows.
- **AC-W1-SEC1** (P0, from security-review §1): regression test asserts `share_with_ai_scheduler=false → medicalContext block.text === ''`. Snapshot test in `medicalContext.test.ts`. BLOCKING for R-O6 close.
- **AC-W2-T2.0a** (P0): Define snapshot-fixture format for weekShape regression tests — golden JSON shape per fixture (Davit + Levan + 2 synthetic edge cases), version 1.
- **AC-W2-T2.0b** (P0): Wire fixture harness into CI (`pnpm test:fixtures:weekShape`) running BOTH `LIFEOS_PIPELINE_EMISSION_V2=0` and `=1` branches; fail if v2 diverges from v1 on the v1-correctness fields.
- **AC-W2-FLAG** (P0): Define V2 flag cutover criteria — `LIFEOS_PIPELINE_EMISSION_V2=1` flips when: (a) Davit synthetic fixture verify=0 violations, (b) 0 zero-duration time_blocks emitted, (c) WORK block coverage ≥ 90% of stated hours_per_week, (d) AM workout ≥ wake_time on 100% of weekly fixtures.

### Wave-2 parallelism (architect risk H1 mitigation — confirmed by user 2026-05-19)

Per user decision 2026-05-19: Wave 2 runs **4 parallel agent swarms** dispatched at Wave-2 kickoff:

- Swarm A — R-D durations (R-D1..D9, 9 ACs)
- Swarm B — R-A anchors (R-A1..A12, 12 ACs)
- Swarm C — R-L linkage (R-L1..L6, 6 ACs) — R-L3 sequenced first
- Swarm D — R-V verify rules (R-V1..V3, 3 ACs)

All 4 share the LIFEOS_PIPELINE_EMISSION_V2 flag. Coordination point: AC-W2-FLAG criteria gates the flag flip at Wave-2 Day 14.

### Security follow-ups absorbed as ACs

Security review's 4 blocking items all map to existing ACs + 1 new (AC-W1-SEC1 above):

- Migration `DEFAULT false` for share_with_ai_scheduler → R-O6 acceptance condition
- RLS migration for dietary_restrictions_audit → R-X3 (was already on list)
- medicalContext.test.ts snapshot → AC-W1-SEC1 (new)
- sanitizeUUID backend pair for R-N1 → R-N1 acceptance condition

---

## Success criteria (overall)

- [ ] All 63 ACs closed (was 58; +5 from architecture amendments)
- [ ] P95 < 800ms (LifeOS default)
- [ ] 0 RLS leakage in cross-user test
- [ ] Typecheck + lint + tests clean
- [ ] Mobile responsive verified at 375px
- [ ] Davit synthetic-fixture verify=0 violations (AC-W2-FLAG gate)
- [ ] AI feedback `source=gemini` ≥80% of calls
- [ ] 0 response-contract-mismatch warnings in dev log

---

## Files touched (claims scope)

_(populated from wizard answers)_

---

## Module DoD (LifeOS standard)

- [ ] Lambda routes + Zod schemas
- [ ] RLS policies (4 per new table)
- [ ] Tests (unit + integration + E2E if user-facing)
- [ ] /api-contract-validation passes
- [ ] /debug-rls passes
- [ ] Typecheck + lint clean
- [ ] Soft-delete enforced
- [ ] Auth on every route
- [ ] Mobile responsive (375px)
- [ ] CLAUDE.md updated if convention emerged

---

## SPARC design _(filled day 1-2, after design lock)_

### Specification

_(formalized from §A-§J)_

### Pseudocode

_(algorithms + data flow)_

### Architecture

_(component diagram, sequence diagram)_

---

## Recalled patterns

- ✓ lifeos-pipeline-onboarding-fidelity-prior (§A, score 0.71) — applied to A1 problem statement carryover

---

## Amendments

_(diff-tracked here as the sprint progresses)_
