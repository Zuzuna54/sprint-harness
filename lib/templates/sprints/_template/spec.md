# Sprint <SPRINT_ID>: <TITLE>

> Template assembled from wizard sections A-J. Fields marked `<...>` are filled by the wizard; sections may be skipped if §A flagged them N/A.

## Status

- **Phase:** spec-wizard | spec-locked | design-locked | building | mid-checkin | verifying | pre-deploy | deploying | done | paused
- **Day:** <N> of 14
- **Started:** <ISO_DATE>
- **Gates passed:** <list>
- **Drift score (latest):** <0.00-1.00>
- **Wizard sections captured:** <list of A through J that were filled>

---

## §A — Problem & Vision

### Problem statement

<what's broken or missing today, in user voice>

### Who suffers

- <persona 1: role + how impacted>
- <persona 2: role + how impacted>

### Why now

<what changed, what's the trigger event, what alternatives were considered>

### Strategic fit

<how this advances <BRAND_SLUG_TITLE> "10 min/day, get rest of life scheduled" promise — or "not strategic, tactical fix">

### Success vision

<describe the world after we ship — 2-3 sentences of what changes for users>

---

## §B — Business Logic & Domain Rules

### Entities

<repeating per entity:>
- **<EntityName>** — <description>
  - **States:** `{STATE_1, STATE_2, ...}`
  - **Transitions:** STATE_1 → STATE_2 (trigger: <event>)

### Invariants

<things that must always hold true>
- Inv 1: <e.g., "muscle group cannot be trained twice within 48h">
- Inv 2: ...

### Calculations / aggregations

- <Name>: formula = <expression>
- ...

### Edge cases

- Edge 1: <unusual scenario> → <expected behavior>
- Edge 2: ...

---

## §C — Data & Schema _(skipped if "no schema change" in §A)_

### New tables/columns

```sql
-- proposed
CREATE TABLE <table_name> (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  -- ...
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ  -- soft-delete only
);
```

### Relationships

- FK: <from>.<col> → <to>.<col> (<cascade strategy>)
- ...

### RLS policies (4 per table — <BRAND_SLUG_TITLE> standard)

```sql
-- SELECT
CREATE POLICY "<table>_select_own" ON <table>
  FOR SELECT USING (auth.uid() = user_id AND deleted_at IS NULL);

-- INSERT
CREATE POLICY "<table>_insert_own" ON <table>
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- UPDATE
CREATE POLICY "<table>_update_own" ON <table>
  FOR UPDATE USING (auth.uid() = user_id AND deleted_at IS NULL)
  WITH CHECK (auth.uid() = user_id);

-- DELETE (soft-only, so we forbid hard DELETE; UPDATE deleted_at instead)
CREATE POLICY "<table>_delete_none" ON <table>
  FOR DELETE USING (false);
```

### Migration strategy

- Additive only / Destructive (requires ADR)
- Forward + rollback plan

### PII / encryption _(if applicable)_

<what user data touches; encryption-at-rest status; retention>

---

## §D — API Surface _(skipped for frontend-only)_

### Endpoints

| Method                   | Path   | Purpose            | Auth                               |
| ------------------------ | ------ | ------------------ | ---------------------------------- |
| <GET\|POST\|PUT\|DELETE> | <path> | <one-line purpose> | <requireUser \| public \| scope:X> |

### Request/response Zod schemas

```typescript
// apps/lambdas/<module>/src/schemas/<name>.ts
export const <Name>Request = z.object({
  // ...
});

export const <Name>Response = z.object({
  // ...
});
```

### Error cases

- 400: <when>
- 401: <when>
- 403: <when>
- 404: <when>
- 409: <when>
- 422: <when>
- 500: <when>

### External APIs _(if applicable)_

- <API name>: <purpose> · timeout: <Nms> · retry: <strategy> · circuit-breaker: <yes/no>

---

## §E — UI Components & Pages _(skipped for backend-only)_

### New pages

| Route  | Component       | Server/Client | Purpose    |
| ------ | --------------- | ------------- | ---------- |
| <path> | <Component.tsx> | server/client | <one-line> |

### New components

| Component | Path                                  | Type          | Reuses                |
| --------- | ------------------------------------- | ------------- | --------------------- |
| <Name>    | apps/web/components/<area>/<Name>.tsx | server/client | <existing components> |

### Server vs client split

- **Server:** <list> — display only, no interactivity
- **Client (`'use client'`):** <list> — uses hooks/state/event handlers

### State management

- **Server state (TanStack Query):** <queries with QUERY_KEYS>
- **UI state (Redux):** <slices if any> — usually NONE per <BRAND_SLUG_TITLE> convention

### Mobile responsiveness

- 375px: <changes>
- 768px: <changes>
- 1024px+: <baseline>

---

## §F — UX Flow & Interactions _(skipped for backend-only)_

### Happy path

1. <step>
2. <step>
3. <step>
   ...

### Error paths

- **Network fail:** <UI response — toast / inline / redirect>
- **Validation fail:** <UI response>
- **Permission fail:** <UI response>
- **Domain rule violation:** <UI response>

### Empty states

- **No data yet:** <CTA>
- **First-time user:** <onboarding hint>

### Loading states

- <surface>: skeleton / spinner / optimistic update

### Transitions / animations

- <surface>: <Framer Motion behavior>

---

## §G — Visual Design & Brand _(skipped if no UI)_

### Design system

- Existing shadcn/ui components used: <list>
- New tokens needed: <none / list>

### Typography / spacing / color

- Follows <BRAND_NAME> brand book sections: <§12 color, §13 typography, ...>
- Deviations: <none / list>

### Iconography

- Lucide icons: <list>
- New icons needed: <none / list>

---

## §H — Integration Points _(always asked)_

### <BRAND_SLUG_TITLE> modules touched

- <module>: <how>

### External APIs

- <none / list with purpose>

### Cross-module events

- <event>: <emitter> → <consumer> (<side effect>)

### Background workers / cron

- <none / list>

---

## §I — Acceptance Criteria _(always asked)_

### UI/E2E (Gherkin)

**AC-1** `complex: <true/false>`

> Mark `complex: true` if the AC body contains any of: `auth`, `RLS`, `migration`, `JWT`, `secret`, `delete`, `password`, `hash`, `encrypt`, `payment`, `billing`, `charge`, `key`, `credential`, `policy`, `drop table`, `row-level`. The AC-7 post-commit hook will fire a pair-mode advisory when commits reference this AC.

- **GIVEN** <initial state>
- **WHEN** <action>
- **THEN** <expected outcome>

**AC-2** `complex: <true/false>`

- ...

### Backend (INVEST)

**AC-N** `complex: <true/false>`

- Independent: <how>
- Negotiable: <how>
- Valuable: <how>
- Estimable: <how>
- Sized: <S/M — Shape Up appetite, no points>
- Testable: <how>

### Performance bars

- P95 lambda response: < <N>ms
- Payload: < <N>KB
- DB queries per request: ≤ <N>

### Manual QA checklist

- [ ] iOS Safari 375px renders cleanly
- [ ] No console errors
- [ ] Cross-user test: user A can't see user B's data
- [ ] <additional surface-specific items>

### Production verdict bar (per AC)

> **Lesson from harness-full-coverage (2026-05-17):** "File exists + script runs + returns something" is NOT Production. Each AC requires inject-violation-catch-restore evidence.

For each AC, document in `proof/AC-N.md`:

1. **Baseline:** gate runs on clean main, exits 0
2. **Inject:** apply a known violation (fixture in `scripts/violation-fixtures/` or inline edit)
3. **Catch:** re-run gate, assert it CATCHES the violation (non-zero exit OR output substring match)
4. **Restore:** reverse-apply fixture, gate goes back to green

Use `scripts/sprint-inject-violation.sh` as the standard helper.

**Two terminal verdicts only:** ✓ Production (all 4 phases proven) OR ✗ Broken-with-followup-AC (filed as next-sprint TODO). No "Scaffolded" / "Partial" / "Wire-only" middle bucket — these were caught as scope-laundering in harness-full-coverage retro.

---

## §J — Risks, Security, Rollback _(always asked)_

### Security risks

- <risk>: <mitigation>

### Privacy implications

- Data touched: <list>
- Retention: <policy>
- Encryption-at-rest: <yes — already enabled / no — needs work>

### Rollback strategy

- <Vercel preview / feature flag / blue-green / soft-delete-only>
- Forward: <how>
- Backward: <how>

### Open questions

- <q>: <status — decided / spike needed / accept ambiguity>

---

## Success criteria (overall)

- [ ] All ACs closed
- [ ] P95 < 800ms (<BRAND_SLUG_TITLE> default)
- [ ] 0 RLS leakage in cross-user test
- [ ] Typecheck + lint + tests clean
- [ ] Mobile responsive verified at 375px
- [ ] <additional sprint-specific criteria>

---

## Files touched (claims scope)

> Used by PreToolUse:Write|Edit hook to enforce out-of-scope detection. Amendments require user approval via `scripts/sprint-amend-spec.sh --add-file <path>` (AC-31 strict mode requires `AMEND_WHY` + `AMEND_INTENT`).
>
> **Path format:** wrap each path in backticks. The §H1 parser at `scripts/sprint-amend-spec.sh:60` extracts paths from this section AND the §H Integration Points block.

- **backend:** `apps/lambdas/<module>-lambda/src/routes/<name>.ts`
- **frontend:** `apps/web/components/<area>/<Name>.tsx`
- **database:** `packages/db/schemas/<name>.ts`, `packages/db/migrations/NNNN_<desc>.sql`
- **types:** `packages/types/src/<name>.ts`
- **infra:** `infra/<name>.ts`

---

## Module DoD (<BRAND_SLUG_TITLE> standard)

- [ ] Lambda routes + Zod schemas
- [ ] RLS policies (4 per new table)
- [ ] Tests (unit + integration + E2E if user-facing)
- [ ] /api-contract-validation passes
- [ ] /debug-rls passes
- [ ] Typecheck + lint clean
- [ ] Soft-delete enforced (no hard DELETE)
- [ ] Auth on every route
- [ ] Mobile responsive (375px)
- [ ] CLAUDE.md updated if convention emerged

---

## SPARC design _(filled day 1-2, after design lock)_

### Specification

<formalized from §A-J>

### Pseudocode

<algorithms + data flow>

### Architecture

<component diagram, sequence diagram>

---

## Code references

- **Reuses:** <existing files with paths>
- **Extends:** <existing files with paths>
- **New:** <new files with paths>

---

## Recalled patterns

> Memories surfaced by the wizard during spec-time; user accepted/rejected each.

- ✓ <pattern-key> (accepted, applied to <section>)
- ✗ <pattern-key> (rejected — <reason>)

---

## Amendments

> Diff-tracked in this same file. Each amendment is appended below by `sprint-amend-spec.sh`. AC-31 strict mode requires structured metadata — empty/missing fields are blocked unless `AMEND_ALLOW_EMPTY=1` (logged).

### Amendment <ISO_DATE> — add file to scope

- **Added:** `<path>`
- **Why:** <1-2 sentence rationale>
- **Intent:** <success criterion post-amendment>
- **Scope impact:** <files_added/cut/replaced + ACs affected>
- **ACs affected:** <comma-separated AC IDs or "(none)">
- **Alternatives considered:** <what else we thought about>
- **Decided by:** <user / Claude / swarm-vote / AMEND_ALLOW_EMPTY-bypass>

### Amendment <ISO_DATE> — scope cut

- **Cut ACs:** <AC-N, AC-M>
- **Why:** <1-2 sentence rationale>
- **Intent:** <what remaining scope ships cleanly>
- **Alternatives considered:** <what else we thought about>
- **Decided by:** <user / Claude>
- **Drift score before:** see `state.json.drift_score_latest`
