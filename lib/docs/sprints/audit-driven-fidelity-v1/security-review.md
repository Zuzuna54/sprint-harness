# Security Review — audit-driven-fidelity-v1

**Reviewer:** security sub-agent (returned inline; persisted by parent)
**Date:** 2026-05-19
**Scope:** Sprint `audit-driven-fidelity-v1`, master requirements R-O1 through R-X4 (58 ACs)
**Verdict:** **PASS_WITH_FOLLOWUP** — net security posture IMPROVES (consent gating, write-time enum constraint); 4 follow-up items required before sprint-close.

---

## 1. PII surface — `share_with_ai_scheduler` consent gating

**Current state (live DB):** `information_schema.columns WHERE column_name='share_with_ai_scheduler'` returns 0 rows. The prior sprint W3.1 claim that this column gates Gemini prompts is **factually false** (per master-requirements R-B3). `apps/lambdas/ai-scheduler-lambda/src/pipeline/medicalContext.ts:62-103` currently sends **every** active condition + medication name to Gemini unconditionally — there is no opt-in. R-O6 closes this gap.

**Required posture after R-O6 ships:**

| Surface                                | Default                                                                        | Verification                                                                                                                                            |
| -------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `user_medical_conditions` column       | `NOT NULL DEFAULT false`                                                       | Migration MUST add the column with `DEFAULT false` and NOT use a backfill `UPDATE … SET share_with_ai_scheduler = true`. Audit migration diff.          |
| `user_medications` column              | `NOT NULL DEFAULT false`                                                       | Same.                                                                                                                                                   |
| Onboarding step 10 form                | unchecked checkbox                                                             | Zod schema MUST default to `false`, never `.default(true)`.                                                                                             |
| `medicalContext.ts:65` filter          | `prefs.medications.filter(m => m.shareWithAiScheduler && !m.discontinuedDate)` | Existing filter only checks `discontinuedDate`. Add `shareWithAiScheduler === true` AND apply same filter to conditions (line 66 currently passes all). |
| Snapshot test `medicalContext.test.ts` | new case: 2 conditions both `share=false` → `block.text === ''`                | Add regression case before R-O6 closes.                                                                                                                 |

**Migration safety check (BLOCKING follow-up before merge):**

The migration adding the column MUST be of the form:

```sql
ALTER TABLE user_medical_conditions
  ADD COLUMN IF NOT EXISTS share_with_ai_scheduler boolean NOT NULL DEFAULT false;
```

NOT a backfill UPDATE that flips existing rows to true.

Existing Davit + Levan rows MUST land at `false` so prior implicit consent does NOT survive as opt-in. Re-onboarding will surface the toggle and capture explicit consent.

**Telemetry leak check:** `medicalContext.ts:18-26` documents that condition/medication names are NEVER logged at `info`. Confirm structured logger never includes `block.text` in CloudWatch — only `meta.conditionsCount` + `meta.medicationsCount`. Sprint must NOT introduce a debug-log statement that logs the assembled text.

---

## 2. RLS implications of new columns + CHECK constraint

**New columns** (`share_with_ai_scheduler`, `weekend_*`, `severity`, `diagnosed_date`, `dose_amount`, etc.) inherit existing parent-table RLS policies on `user_medical_conditions`, `user_medications`, `fitness_profiles`. **No new RLS surface.** Drizzle column-level RLS is not in use; PG row-level security covers all columns of a row uniformly.

**CHECK constraint on `fitness_profiles.dietary_restrictions[]`** (R-O5): purely a domain constraint, no security implication. Will reject INSERT/UPDATE of rows containing values outside the 12-element whitelist. Risk: existing Levan + Davit rows already contain freeform strings. Mitigation: migration 0074 (already shipped) pre-cleans the column via `dietary_restrictions_audit`. The new migration must use `NOT VALID` then `VALIDATE CONSTRAINT` (idempotent), OR run cleanup pre-step in same migration file.

Spec §J top-risk #1 already flags this.

---

## 3. `dietary_restrictions_audit` RLS posture (R-X3)

**Current state:** Table created by `packages/db/src/migrations/0074_dietary_restrictions_cleanup.sql:31-36`. The file does NOT issue `ENABLE ROW LEVEL SECURITY` or any `CREATE POLICY`. The prior sprint's `security-review.md:12-28` flagged this as a follow-up that was never closed.

**Risk:** Table contains `user_id` + `dropped_value` (the freeform original input — may contain PII). With RLS disabled, anon-key Supabase client can `SELECT *` and harvest cross-user PII.

**Required (BLOCKING, R-X3):**

```sql
ALTER TABLE dietary_restrictions_audit ENABLE ROW LEVEL SECURITY;
-- No authenticated/anon policies. service_role bypasses RLS by design,
-- so admin Lambda access continues to work. Authenticated clients see nothing.
```

Must ship as own migration in this sprint (numbered ≥ 0078). Verify with `SELECT * FROM pg_policies WHERE tablename = 'dietary_restrictions_audit';` post-apply.

---

## 4. AI feedback timeout 600→2000ms (R-F1)

**Auth surface:** Unchanged. `POST /ai/feedback` already calls `requireUser()` / `getUserId(event)`. Time-budget extension does not alter route auth, request validation, response shape, or CORS.

**PII surface:** Unchanged. Same payload sent to Gemini regardless of timeout.

**Tail risk:** Longer AbortController window means Lambda warm ~1.4s longer per call. Mitigation: outbound Lambda traffic uses default Node TLS verification; no proxy override.

**Rate-limit alignment (advisory):** Retain circuit-breaker 10-failures-in-60s. R-F2 exponential-backoff change must NOT extend breaker-open window allowing degraded Gemini endpoint to keep retrying with full prompts. Acceptable as-is — backoff caps retries.

**Verdict:** No new auth/PII surface. **PASS.**

---

## 5. Generated `age` column from `date_of_birth` (R-O4)

PG `GENERATED ALWAYS AS … STORED` column: RLS implication is **zero** — generated columns inherit parent row's RLS. Drop-and-compute-in-handler path: also zero RLS impact, removes denormalization risk.

**Prefer drop-column-+-handler-compute** to avoid GENERATED column edge cases with future schema changes.

**Verdict:** No new surface. **PASS.**

---

## 6. Frontend null-meal-id guard (R-N1)

**Current bug:** `apps/web/components/nutrition/MealDetailContent.tsx` fires `GET /nutrition/meals/null` (literal string) on mount when `mealId` is falsy. Backend returns 400 cleanly — not a DoS vector (12 occurrences bounded by component mounts).

**Recommended guard:** `enabled: typeof mealId === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(mealId)`. Stricter than spec's "falsy/string-null" guard.

**NOT a DoS vector:** TanStack Query's `enabled: false` disables refetch entirely; no retry storm.

**Advisory:** Pair frontend guard with backend `sanitizeUUID()` boundary check at `GET /nutrition/meals/:id` (defense-in-depth).

**Verdict:** No DoS vector. **PASS** with advisory.

---

## 7. Overall verdict

**PASS_WITH_FOLLOWUP**

Net delta: security posture **improves** materially.

| Item                                               | Direction                                                  |
| -------------------------------------------------- | ---------------------------------------------------------- |
| `share_with_ai_scheduler` consent gating (R-O6)    | + IMPROVES (closes real PII-to-third-party leak)           |
| Dietary CHECK constraint at write time (R-O5)      | + IMPROVES (defense-in-depth on top of meals-stage filter) |
| `dietary_restrictions_audit` RLS enablement (R-X3) | + IMPROVES (closes cross-user PII leak via anon key)       |
| AI feedback timeout extension (R-F1)               | NEUTRAL                                                    |
| `age` generated column / handler compute (R-O4)    | NEUTRAL                                                    |
| Null-meal-id guard (R-N1)                          | NEUTRAL (cosmetic + log hygiene)                           |

**Follow-ups required before sprint close:**

1. **BLOCKING:** Verify R-O6 migration uses `DEFAULT false` and contains no backfill UPDATE flipping existing rows to true. Diff review.
2. **BLOCKING:** Ship R-X3 RLS migration for `dietary_restrictions_audit` (service-role-only) — open since prior sprint.
3. **BLOCKING:** Add `medicalContext.test.ts` snapshot case asserting `block.text === ''` when all rows have `share_with_ai_scheduler = false`.
4. **Advisory:** Add backend `sanitizeUUID` boundary check at `GET /nutrition/meals/:id` (defense-in-depth pair with R-N1).
5. **Advisory:** Add E2E assertion onboarding step-10 share toggle defaults unchecked.

No CRITICAL findings. No new auth/CORS/secrets/injection surfaces introduced.

**Inspected paths:**

- `/Users/gio/Desktop/lifeos/docs/sprints/audit-driven-fidelity-v1/spec.md`
- `/Users/gio/Desktop/lifeos/docs/sprints/_index/master-requirements-2026-05-19.md`
- `/Users/gio/Desktop/lifeos/apps/lambdas/ai-scheduler-lambda/src/pipeline/medicalContext.ts` (line 62-113 — gate currently missing)
- `/Users/gio/Desktop/lifeos/packages/db/src/migrations/0074_dietary_restrictions_cleanup.sql` (line 31-36 — RLS never enabled)
- `/Users/gio/Desktop/lifeos/docs/sprints/pipeline-onboarding-fidelity/security-review.md` (line 12-28 — prior open follow-up)
- `/Users/gio/Desktop/lifeos/apps/web/components/nutrition/MealDetailContent.tsx` (R-N1 fix site)
