---
name: rls-verifier
description: Verifies RLS policies exist and are correct on all LifeOS database tables
tools: Read, Grep, Glob
---

# RLS Policy Verifier

Verify every database table has complete and correct Row Level Security policies.

---

## Step 1: Identify All Tables with user_id

```bash
# Find all table definitions in schema files
rg -n "pgTable\(" packages/db/src/schema/ --glob '*.ts' -A20 | rg "user_id\|userId"

# List all table names
rg -n "export const .* = pgTable" packages/db/src/schema/
```

---

## Step 2: Find Tables Missing RLS Policies

Run this SQL against Supabase to find tables that have RLS enabled but are missing policies, or tables that lack RLS entirely:

```sql
-- Tables with RLS enabled but missing one or more policy types
WITH user_tables AS (
  SELECT c.relname AS table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND a.attname = 'user_id'
    AND NOT a.attisdropped
),
policy_coverage AS (
  SELECT
    t.table_name,
    COUNT(CASE WHEN p.cmd = 'r' THEN 1 END) AS select_policies,
    COUNT(CASE WHEN p.cmd = 'a' THEN 1 END) AS insert_policies,
    COUNT(CASE WHEN p.cmd = 'w' THEN 1 END) AS update_policies,
    COUNT(CASE WHEN p.cmd = 'd' THEN 1 END) AS delete_policies
  FROM user_tables t
  LEFT JOIN pg_policies p ON p.tablename = t.table_name AND p.schemaname = 'public'
  GROUP BY t.table_name
)
SELECT
  table_name,
  select_policies,
  insert_policies,
  update_policies,
  delete_policies,
  CASE
    WHEN select_policies = 0 THEN 'MISSING SELECT'
    WHEN insert_policies = 0 THEN 'MISSING INSERT'
    WHEN update_policies = 0 THEN 'MISSING UPDATE'
    WHEN delete_policies = 0 THEN 'MISSING DELETE'
    ELSE 'OK'
  END AS status
FROM policy_coverage
ORDER BY status DESC, table_name;
```

```sql
-- Tables that do NOT have RLS enabled at all (dangerous!)
SELECT c.relname AS table_name, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.relrowsecurity = false
  AND c.relname NOT LIKE 'pg_%'
  AND c.relname NOT LIKE '_prisma_%'
ORDER BY c.relname;
```

**Expected policy count per table**: 4 (SELECT, INSERT, UPDATE, DELETE). Any table with fewer than 4 is a gap.

---

## Step 3: Verify auth.uid() Subquery Syntax

The subquery form `(select auth.uid())` is a critical Supabase performance optimization. Bare `auth.uid()` causes the function to be re-evaluated per row; the subquery form evaluates once.

```sql
-- Find policies using bare auth.uid() instead of (select auth.uid())
SELECT
  schemaname,
  tablename,
  policyname,
  qual,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND (
    (qual LIKE '%auth.uid()%' AND qual NOT LIKE '%(select auth.uid())%')
    OR (with_check LIKE '%auth.uid()%' AND with_check NOT LIKE '%(select auth.uid())%')
  );
```

Also verify in migration files:

```bash
# Check migration SQL for bare auth.uid() (must be wrapped in subquery)
rg -n "auth\.uid\(\)" packages/db/drizzle/ --glob '*.sql' | rg -v "select auth\.uid\(\)"
```

Any result from either query is a performance bug that must be fixed.

---

## Step 4: System Data Tables (Special SELECT Policies)

These tables contain both system-provided rows (`user_id IS NULL`) and user-created rows. They need a special SELECT policy:

| Table | System Data | User Data |
|-------|------------|-----------|
| exercises | Pre-loaded exercise library | Custom user exercises |
| supplements | Supplement catalog | (none - separate user_supplements table) |
| meals | System meal database | Custom user meals |

**Required SELECT policy for system data tables**:

```sql
-- Example for exercises table
CREATE POLICY exercises_select ON public.exercises
  FOR SELECT USING (
    user_id IS NULL                        -- system rows visible to all
    OR (select auth.uid()) = user_id       -- user's own rows
  );

-- INSERT/UPDATE/DELETE policies still restrict to user's own rows only
CREATE POLICY exercises_insert ON public.exercises
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY exercises_update ON public.exercises
  FOR UPDATE USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY exercises_delete ON public.exercises
  FOR DELETE USING ((select auth.uid()) = user_id);
```

Verify this pattern exists:

```bash
rg -n "user_id IS NULL" packages/db/drizzle/ --glob '*.sql'
```

---

## Step 5: Cross-User Isolation Test

Run these tests against a staging Supabase instance with two test users to verify RLS is working:

```sql
-- Setup: create two test users (use Supabase Auth API or dashboard)
-- User A: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
-- User B: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

-- Step 1: As User A, insert a time block
SET request.jwt.claims = '{"sub": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';
INSERT INTO time_blocks (user_id, title, module_type, start_time, end_time)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'User A Block', 'WORKOUT', now(), now() + interval '1 hour')
RETURNING id;

-- Step 2: As User B, try to read User A's block (should return 0 rows)
SET request.jwt.claims = '{"sub": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}';
SELECT * FROM time_blocks WHERE title = 'User A Block';
-- Expected: 0 rows

-- Step 3: As User B, try to update User A's block (should affect 0 rows)
UPDATE time_blocks SET title = 'Hacked' WHERE title = 'User A Block';
-- Expected: UPDATE 0

-- Step 4: As User B, try to delete User A's block (should affect 0 rows)
DELETE FROM time_blocks WHERE title = 'User A Block';
-- Expected: DELETE 0

-- Step 5: Verify User A's block is untouched
SET request.jwt.claims = '{"sub": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';
SELECT * FROM time_blocks WHERE title = 'User A Block';
-- Expected: 1 row, intact
```

Run this test pattern against every table with `user_id`. Critical tables to test:
- `time_blocks` (planner)
- `workout_sessions`, `workout_sets` (workouts)
- `daily_nutrition_logs` (nutrition)
- `supplement_logs`, `user_supplements` (supplements)
- `grocery_lists`, `grocery_items` (grocery)
- `health_logs` (health)
- `cost_entries`, `budget_settings` (finances)
- `user_profiles`, `goal_settings` (auth)

---

## Step 6: Verify All Expected Tables

Complete list of LifeOS tables requiring RLS with `user_id`:

| Table | SELECT | INSERT | UPDATE | DELETE |
|-------|--------|--------|--------|--------|
| user_profiles | x | x | x | x |
| goal_settings | x | x | x | x |
| time_blocks | x | x | x | x |
| module_pauses | x | x | x | x |
| generated_schedules | x | x | x | x |
| workout_templates | x | x | x | x |
| workout_sessions | x | x | x | x |
| workout_sets | x | x | x | x |
| muscle_group_history | x | x | x | x |
| daily_nutrition_logs | x | x | x | x |
| nutrition_targets | x | x | x | x |
| user_supplements | x | x | x | x |
| supplement_logs | x | x | x | x |
| supplement_inventory | x | x | x | x |
| grocery_lists | x | x | x | x |
| grocery_items | x | x | x | x |
| health_logs | x | x | x | x |
| budget_settings | x | x | x | x |
| cost_entries | x | x | x | x |
| exercises | SPECIAL | x | x | x |
| supplements | SPECIAL | - | - | - |
| meals | SPECIAL | x | x | x |

---

## Output Format

```
RLS Verification Report
========================
Tables scanned: 22
Policies found: 86 / 88 expected

[CRITICAL] workout_sets: MISSING DELETE policy
[CRITICAL] cost_entries: MISSING UPDATE policy
[WARN] exercises: SELECT policy missing user_id IS NULL clause for system rows
[WARN] muscle_group_history: Using bare auth.uid() instead of (select auth.uid())

Cross-user isolation: PASSED (all 19 user tables tested)
```
