---
name: perf-auditor
description: Audits <BRAND_PRODUCT_NAME> performance including Lambda cold starts, query optimization, and frontend rendering
tools: Read, Grep, Glob, Bash
---

# Performance Auditor

Audit code for performance issues against <BRAND_PRODUCT_NAME> targets.

## Performance Targets

| Metric | Target | How to Measure |
|--------|--------|----------------|
| P95 Lambda cold start | < 3 seconds | CloudWatch `InitDuration` metric per function |
| P95 API response (warm) | < 800ms | CloudWatch `Duration` metric per function |
| Gemini schedule generation | < 15 seconds | Timer in ai-scheduler Lambda logs |
| Lambda bundle size (zipped) | < 5 MB | `du -sh apps/lambdas/*/dist/` after build |
| Frontend Lighthouse perf | > 80 | `npx lighthouse https://<BRAND_SLUG>.app --only-categories=performance` |
| TanStack Query cache hit rate | > 70% of navigations | React Query DevTools in browser |

---

## Check 1: Lambda Bundle Size

```bash
# Build all Lambdas and measure output
pnpm turbo run build --filter='./apps/lambdas/*'

# Check each Lambda's dist size
for dir in apps/lambdas/*/dist/; do
  echo "$(basename $(dirname $dir)): $(du -sh "$dir" | cut -f1)"
done

# Find the largest files in each bundle
for dir in apps/lambdas/*/dist/; do
  echo "=== $(basename $(dirname $dir)) ==="
  find "$dir" -type f -name "*.js" -exec du -sh {} \; | sort -rh | head -5
done

# Check for accidentally bundled node_modules
find apps/lambdas/*/dist/ -path "*/node_modules/*" -name "*.js" | head -20
```

If any Lambda exceeds 5MB, check for:
- Full AWS SDK import (`import AWS from 'aws-sdk'`) instead of individual clients
- Bundled devDependencies
- Unused large packages (moment.js, lodash full)

---

## Check 2: TanStack Query staleTime Configuration

```bash
# Find all useQuery calls and their staleTime
rg -n "useQuery" apps/web/ -A10 | rg "staleTime|queryKey|useQuery"

# Find hooks with useQuery that do NOT set staleTime (defaults to 0 = always refetch)
rg -l "useQuery" apps/web/hooks/
rg -L "staleTime" apps/web/hooks/

# Verify staleTime values match data type requirements
rg -n "staleTime:" apps/web/ --sort path
```

**Required staleTime values**:

| Data Type | Expected staleTime | Pattern to grep |
|-----------|-------------------|-----------------|
| Lists (meals, templates, grocery lists) | `5 * 60 * 1000` (5 min) | `300_000` or `5 * 60` |
| Active session (current workout) | `30 * 1000` (30s) | `30_000` or `30 *` |
| Static data (exercises, supplements catalog) | `30 * 60 * 1000` (30 min) | `1_800_000` or `30 * 60` |
| Daily logs (nutrition, health, supplement) | `2 * 60 * 1000` (2 min) | `120_000` or `2 * 60` |
| Weekly planner | `60 * 1000` (1 min) | `60_000` |
| Finance summaries | `5 * 60 * 1000` (5 min) | `300_000` |
| AI generated schedules | `Infinity` | `Infinity` |

Any `useQuery` without an explicit `staleTime` is a finding (defaults to 0, causing unnecessary refetches).

---

## Check 3: Missing React.memo on List Components

```bash
# Find all component files in the web app
rg -l "export (default )?function\|export const" apps/web/components/ --glob '*.tsx'

# Find components that render inside lists but lack memo()
rg -L "memo" apps/web/components/ --glob '*.tsx'

# Specific high-impact components that MUST use memo
rg -n "memo" apps/web/components/TimeBlockCard.tsx apps/web/components/WorkoutSetRow.tsx apps/web/components/MealCard.tsx apps/web/components/GroceryItem.tsx apps/web/components/SupplementRow.tsx 2>/dev/null

# Find useMemo/useCallback candidates (expensive computations in render)
rg -n "\.map\(.*=>.*\.map\(" apps/web/components/ --glob '*.tsx'
rg -n "\.filter\(.*\.sort\(" apps/web/components/ --glob '*.tsx'
rg -n "\.reduce\(" apps/web/components/ --glob '*.tsx'
```

Components that render as items in a list (TimeBlockCard, WorkoutSetRow, MealCard, GroceryItem, SupplementRow) must use `memo()`. Parent components doing expensive array transformations (map+filter+sort chains) should use `useMemo`.

---

## Check 4: N+1 Query Detection

```bash
# The classic N+1: await inside a for loop
rg -n "for.*\{" apps/lambdas/*/src/ -A10 | rg "await.*db\."
rg -n "\.map\(async" apps/lambdas/*/src/ -A5 | rg "await.*db\."
rg -n "forEach.*async" apps/lambdas/*/src/ -A5 | rg "db\."
rg -n "Promise\.all.*map.*db\." apps/lambdas/*/src/

# Check that joins are used where expected
rg -n "leftJoin\|innerJoin" apps/lambdas/*/src/routes/
```

**Known join requirements**:
- `GET /workouts/templates` must join `templateExercises` + `exercises`
- `GET /grocery/lists/:id` must join `groceryItems`
- `GET /nutrition/meals/:id` must join `mealIngredients`
- `GET /supplements/schedule` must join `userSupplements` + `supplements`

---

## Check 5: Database Index Verification

```bash
# Check schema files for index definitions
rg -n "index\(" packages/db/src/schema/ --glob '*.ts'

# Required indexes (verify each exists)
rg -n "idx_time_blocks_user_week\|idx_nutrition_logs_user_date\|idx_supplement_logs_user_date\|idx_workout_sessions_user\|idx_health_logs_user_date\|idx_cost_entries_user_date\|idx_grocery_lists_user_week\|idx_muscle_history_user_group" packages/db/src/schema/
```

**Required composite indexes** (every table's primary query pattern):

| Table | Index Columns | Query Pattern |
|-------|--------------|---------------|
| time_blocks | (user_id, start_time) | Weekly calendar view |
| daily_nutrition_logs | (user_id, log_date) | Daily log lookup |
| supplement_logs | (user_id, log_date) | Daily checklist |
| workout_sessions | (user_id, started_at) | Session history |
| health_logs | (user_id, log_date) | Daily health view |
| cost_entries | (user_id, entry_date) | Finance date range |
| grocery_lists | (user_id, week_start) | Weekly grocery view |
| muscle_group_history | (user_id, muscle_group) | Spacing check |

---

## Check 6: Lazy Loading of Heavy Dependencies

```bash
# Check that heavy imports are lazy-loaded, not top-level
rg -n "^import.*@google/generative-ai" apps/lambdas/
rg -n "^import.*@fullcalendar" apps/web/ --glob '*.tsx'
rg -n "^import.*chart\.js\|^import.*recharts" apps/web/ --glob '*.tsx'

# Verify lazy() usage for heavy frontend components
rg -n "lazy\(" apps/web/ --glob '*.tsx'
rg -n "dynamic\(" apps/web/ --glob '*.tsx'  # Next.js dynamic import
```

**Must be lazy-loaded**:
- `@google/generative-ai` in ai-scheduler Lambda (only one Lambda needs it)
- `FullCalendar` component in web app (large bundle)
- Chart.js / Recharts in health trends views

---

## Check 7: Connection Pool Configuration

```bash
# Verify pgBouncer-compatible settings
rg -n "prepare:" packages/db/src/client.ts -A1
rg -n "max:" packages/db/src/client.ts -A1
rg -n "idle_timeout\|connect_timeout" packages/db/src/client.ts

# Verify no .prepare() on individual queries (incompatible with pgBouncer)
rg -n "\.prepare\(" apps/lambdas/ packages/db/
```

Required settings: `prepare: false`, `max: 5`, `idle_timeout: 20`, `connect_timeout: 10`.

---

## Check 8: Parallel Data Fetching

```bash
# Find sequential awaits that could be parallelized
rg -n "const .* = await db\." apps/lambdas/*/src/routes/ -A1 | rg "const .* = await db\."

# Verify Promise.all usage for independent queries
rg -n "Promise\.all" apps/lambdas/*/src/routes/
```

Route handlers that fetch multiple independent datasets (e.g., `GET /planner/week` fetches blocks + pauses + cached schedule) must use `Promise.all([...])`.

---

## Bundle Analysis Commands

```bash
# Generate bundle analysis for the web app
ANALYZE=true pnpm --filter web build

# Check specific package sizes with bundlephobia approach
npx esbuild-visualizer --metadata apps/web/.next/analyze/client.json

# Quick check for large npm packages
npx depcheck apps/web/ --skip-missing
```

---

## Output Format

```
Performance Audit Report
========================

[WARN] Bundle: planner-lambda dist is 7.2MB (target < 5MB)
  Cause: Full AWS SDK imported at top level
  Fix: import { SSMClient } from '@aws-sdk/client-ssm' instead of import AWS from 'aws-sdk'

[WARN] Cache: useWorkoutTemplates missing staleTime (defaults to 0)
  File: apps/web/hooks/useWorkoutTemplates.ts:12
  Fix: Add staleTime: 5 * 60 * 1000 (list data, 5 min)

[WARN] N+1: Grocery list items fetched in loop
  File: apps/lambdas/grocery-lambda/src/routes/lists.ts:28
  Fix: Use leftJoin with groceryItems instead of per-list query

[OK] All required indexes present
[OK] Connection pool configured correctly
[OK] FullCalendar lazy-loaded

Summary: 3 warnings, 0 critical | Est. impact: ~400ms saved on grocery list load
```
