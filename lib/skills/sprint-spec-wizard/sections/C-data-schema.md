# §C — Data & Schema

**Goal:** nail down tables, columns, relationships, RLS policies, migration strategy.

**Skip if:** `sections_answers.A.no_schema_change == true` OR `B.pure_logic_layer == true`.

## Discovery goals

1. New tables and columns needed
2. Relationships (FK, joins, cascade strategy)
3. RLS policies — who can SELECT/INSERT/UPDATE/DELETE
4. Migration strategy — additive vs destructive (destructive requires ADR)
5. PII / encryption handling (if applicable)

## Typical question shape

- C1 — **New schema**: "Based on §B entities (`new_entities`), I'd propose these tables: <pre-filled DDL drafts>. Accept, modify, or different shape?" Each new entity gets a draft `CREATE TABLE` with LifeOS defaults (UUID PK, `user_id` FK, `created_at`/`updated_at`, `deleted_at`).
- C2 — **Relationships**: "How do these tables relate? FK from where to where? Cascade strategy? (LifeOS rule: NEVER cascade DELETE — soft-delete via `deleted_at` only)"
- C3 — **RLS**: "Standard LifeOS RLS template = 4 policies per table (SELECT/INSERT/UPDATE/DELETE) scoped to `auth.uid() = user_id AND deleted_at IS NULL`. Apply as default to all new tables? Any exceptions (shared tables, system-owned, etc.)?"
- C4 — **Migration**: "Additive (new tables, new nullable columns) or destructive (column drops, type changes)? Destructive requires ADR — confirm?"
- C5 — **PII** (conditional): "Does this touch health data, financial data, auth tokens? If yes, encryption-at-rest is already enabled — confirm retention policy and any redaction needs."

## Conditional follow-ups

- If C1 has any new table → C3 is mandatory (no exceptions to RLS)
- If C2 mentions cascading deletes → BLOCK: surface LifeOS rule (soft-delete only); require user to confirm soft-delete approach
- If C4 is destructive → instruct user to create ADR in `docs/adr/` before spec lock
- If C5 includes health data → surface encryption-at-rest memory; confirm setup

## Output flags

- `new_tables_count: <N>` → affects RLS policy count for verify phase
- `requires_adr: true/false`
- `pii_touched: true/false` → drives §J security depth

## Recall targets

- `lifeos-rls-4-policy-template` (auto-applied)
- `lifeos-soft-delete-pattern` (auto-applied)
- `lifeos-supabase-url-distinction` (surfaced if migration mentioned)
- `lifeos-encryption-at-rest-setup` (surfaced if PII)

## Style guidance

- Pre-fill DDL drafts — user should mostly accept/modify rather than write from scratch
- Each new table MUST have all 4 RLS policies — no exceptions allowed without explicit user rationale
- If user proposes hard DELETE → push back firmly: "LifeOS rule is soft-delete only. Use `UPDATE deleted_at = NOW()` instead."
