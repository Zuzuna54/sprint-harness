---
name: module-integrator
description: Tests cross-module integration points in <BRAND_PRODUCT_NAME> to ensure data flows correctly between modules
tools: Read, Grep, Glob, Bash
---

# Module Integration Checker

Verify cross-module integration points work correctly. <BRAND_PRODUCT_NAME> has 10 critical integration paths where data flows between modules.

---

## Integration Point 1: Planner <-> All Modules

The planner/calendar shows time blocks for ALL module types.

**Verify**:
```bash
# TimeBlock type enum must include all module types
grep -rn "time_block_type\|timeBlockTypeEnum\|ModuleType" packages/db/src/schema/ --include="*.ts"
# Must include: WORKOUT, MEAL, SUPPLEMENT, CHORE, WORK, HEALTH, HOBBY, PERSONAL_DEV

# Calendar component renders blocks from all types
grep -rn "WORKOUT\|MEAL\|SUPPLEMENT\|CHORE\|WORK\|HEALTH" apps/web/components/planner/ --include="*.tsx"

# Planner Lambda returns blocks filtered by week, not by type
grep -rn "startTime\|start_time" apps/lambdas/planner-lambda/src/routes/ --include="*.ts" | grep -v "type"
```

**SQL verification**:
```sql
-- Verify time_blocks table shows all module types for a user
SELECT module_type, COUNT(*) as block_count
FROM time_blocks
WHERE user_id = :userId
  AND start_time >= :weekStart
  AND start_time < :weekStart + interval '7 days'
  AND deleted_at IS NULL
GROUP BY module_type
ORDER BY module_type;

-- Expected module_type values:
-- WORKOUT, MEAL, SUPPLEMENT, HEALTH_CHECK, CUSTOM, AI_SUGGESTED
```

**Data flow**: Frontend calls `GET /planner/week?weekStart=` -> planner-lambda returns `TimeBlock[]` -> FullCalendar renders all types with color coding.

---

## Integration Point 2: Nutrition -> Grocery (Ingredient Aggregation)

Grocery list generation aggregates ingredients from selected meals.

**Verify**:
```bash
# Grocery lambda imports or calls nutrition data
grep -rn "meals\|meal_ingredients\|ingredients" apps/lambdas/grocery-lambda/src/ --include="*.ts"

# Grocery list generation endpoint exists
grep -rn "generate" apps/lambdas/grocery-lambda/src/ --include="*.ts"

# aggregateGroceryIngredients function in utils
grep -rn "aggregateGroceryIngredients\|aggregate" packages/utils/src/ --include="*.ts"
```

**SQL trace** (full data flow):
```sql
-- Step 1: User selects meals for a grocery list
SELECT gl.id as list_id, gl.name
FROM grocery_lists gl
WHERE gl.user_id = :userId AND gl.id = :listId;

-- Step 2: Fetch ingredients from selected meals (the source data)
SELECT mi.ingredient_name, mi.quantity, mi.unit, m.name as meal_name
FROM meal_ingredients mi
JOIN meals m ON m.id = mi.meal_id
WHERE mi.meal_id = ANY(:selectedMealIds);

-- Step 3: Verify aggregated grocery items (the output)
-- Same ingredient from multiple meals should be summed
SELECT gi.name, gi.quantity, gi.unit, gi.section, gi.status
FROM grocery_items gi
WHERE gi.list_id = :listId AND gi.deleted_at IS NULL
ORDER BY gi.section, gi.name;

-- Step 4: Verify aggregation correctness
-- Example: 2 meals each with 200g chicken breast -> 1 item with 400g
-- Different units must stay separate (200g butter + 100ml butter = 2 items)
SELECT gi.name, gi.unit, SUM(gi.quantity) as total_quantity, COUNT(*) as item_count
FROM grocery_items gi
WHERE gi.list_id = :listId AND gi.deleted_at IS NULL
GROUP BY gi.name, gi.unit
HAVING COUNT(*) > 1;
-- Expected: 0 rows (duplicates should already be merged)
```

---

## Integration Point 3: Grocery -> Finances (Cost Tracking)

When a grocery item is marked with a cost, a cost_entry is created in the finances module.

**Verify**:
```bash
# Grocery item has actualCost field
grep -rn "actualCost\|actual_cost\|cost" packages/db/src/schema/grocery.ts

# When grocery item cost is set, a cost_entry is created
grep -rn "cost_entries\|costEntries\|finances" apps/lambdas/grocery-lambda/src/ --include="*.ts"

# Finance summary reads from cost_entries which includes GROCERY category
grep -rn "GROCERY" packages/db/src/schema/finances.ts

# linkedEntityType for grocery items
grep -rn "linked_entity_type.*grocery\|linkedEntityType.*grocery" apps/lambdas/ packages/
```

**SQL trace**:
```sql
-- Trace: grocery item cost -> cost_entries
SELECT gi.id, gi.name, gi.cost, gi.status,
       ce.amount, ce.category, ce.description, ce.linked_entity_id
FROM grocery_items gi
LEFT JOIN cost_entries ce ON ce.linked_entity_id = gi.id::text
  AND ce.linked_entity_type = 'grocery_item'
WHERE gi.list_id = :listId AND gi.cost IS NOT NULL;

-- Verify no orphaned costs (every grocery item with cost has a matching cost_entry)
SELECT gi.id, gi.name, gi.cost
FROM grocery_items gi
LEFT JOIN cost_entries ce ON ce.linked_entity_id = gi.id::text
  AND ce.linked_entity_type = 'grocery_item'
WHERE gi.cost IS NOT NULL AND ce.id IS NULL;
-- Expected: 0 rows
```

**Data flow**: `PUT /grocery/items/:id` (add cost) -> grocery-lambda creates `cost_entry` with category=GROCERY -> `GET /finances/summary` aggregates.

---

## Integration Point 4: Supplements -> Finances (Cost Tracking)

Supplement purchases tracked in finance module.

**Verify**:
```bash
# Cost category includes SUPPLEMENT
grep -rn "SUPPLEMENT" packages/db/src/schema/finances.ts

# Supplement inventory restocking creates cost entry
grep -rn "cost\|finance\|costEntries" apps/lambdas/supplements-lambda/src/ --include="*.ts"

# linkedEntityType for supplements
grep -rn "linked_entity_type.*supplement\|linkedEntityType.*supplement" apps/lambdas/ packages/
```

**SQL trace**:
```sql
SELECT si.id, si.supplement_id, si.quantity_remaining,
       ce.amount, ce.category, ce.linked_entity_type
FROM supplement_inventory si
LEFT JOIN cost_entries ce ON ce.linked_entity_id = si.id::text
  AND ce.linked_entity_type = 'supplement'
WHERE si.user_id = :userId;
```

---

## Integration Point 5: Health -> Workouts (AI Adjustment)

Poor sleep quality triggers lighter workout suggestions.

**Verify**:
```bash
# AI scheduler reads health data
grep -rn "healthLogs\|health_logs\|sleep\|energy" apps/lambdas/ai-scheduler-lambda/src/ --include="*.ts"

# Schedule prompt includes sleep/energy context
grep -rn "sleep\|energy\|recentSleep" apps/lambdas/ai-scheduler-lambda/src/ --include="*.ts"

# Low sleep quality triggers warning in prompt
grep -rn "avgQuality.*<\|Poor sleep\|lighter" apps/lambdas/ai-scheduler-lambda/src/ --include="*.ts"

# Health hints endpoint checks sleep quality
grep -rn "sleep_quality\|sleepQuality" apps/web/app/api/ai/generate-hints/ apps/lambdas/health-lambda/src/
```

**SQL verification**:
```sql
-- Check: health log with low sleep -> hint generated
SELECT hl.log_date, hl.sleep_quality, hl.energy_level,
       hh.hint_type, hh.message, hh.dismissed
FROM health_logs hl
LEFT JOIN health_hints hh ON hh.log_date = hl.log_date AND hh.user_id = hl.user_id
WHERE hl.user_id = :userId AND hl.sleep_quality <= 2
ORDER BY hl.log_date DESC;
```

**Data flow**: `health_logs` -> AI scheduler reads recent sleep avg -> if quality < 3, prompt includes "avoid high-intensity workouts" -> generated schedule uses lighter templates.

---

## Integration Point 6: Workouts -> Muscle Group History

Completing a workout updates muscle group history for the 48h spacing rule.

**Verify**:
```bash
# Completing a session updates muscle_group_history
grep -rn "muscleGroupHistory\|muscle_group_history" apps/lambdas/workouts-lambda/src/ --include="*.ts"

# Session completion handler writes history
grep -rn "complete\|completedAt" apps/lambdas/workouts-lambda/src/routes/ --include="*.ts" -A 10 | grep -i "muscle"

# Spacing check reads from history
grep -rn "checkMuscleGroupSpacing\|check-spacing" apps/lambdas/workouts-lambda/src/ --include="*.ts"
```

**Data flow**: `PUT /workouts/sessions/:id` (complete) -> writes muscle groups to `muscle_group_history` -> `POST /workouts/check-spacing` reads history -> returns violations if < 48h.

---

## Integration Point 7: AI Scheduler -> All Modules (Context Gathering)

Schedule generation considers workouts, meals, supplements, and health data.

**Verify**:
```bash
# AI scheduler imports/reads from multiple module schemas
grep -rn "import.*schema\|from.*schema" apps/lambdas/ai-scheduler-lambda/src/ --include="*.ts"

# Schedule context includes data from all modules
grep -rn "templates\|supplements\|muscleHistory\|meals\|healthLogs\|goalSettings\|pauses" apps/lambdas/ai-scheduler-lambda/src/ --include="*.ts"

# Data fetching queries (should be parallel with Promise.all)
grep -rn "Promise\.all" apps/lambdas/ai-scheduler-lambda/src/ --include="*.ts" -A 10

# Generated schedule creates blocks with correct linkedEntityType
grep -rn "linkedEntityType\|linked_entity_type" apps/lambdas/ai-scheduler-lambda/src/ --include="*.ts"
```

**Required context for AI schedule generation**:
- Workout templates + muscle group history (for spacing)
- Nutrition targets (for meal timing)
- Supplement schedule (for timing rules)
- Health logs (for recovery status)
- Module pauses (to exclude paused modules)
- Goal settings (from onboarding)

**Data flow**: AI scheduler fetches all context via `Promise.all([...])` -> builds Gemini prompt -> generates schedule -> stored in `generated_schedules` -> user accepts via `POST /planner/schedule/accept` -> creates `time_blocks` with linkedEntityId/Type.

---

## Integration Point 8: Onboarding -> AI Schedule

Completing onboarding saves goal_settings, then triggers first AI schedule generation.

**Verify**:
```bash
# Onboarding completion triggers schedule generation
grep -rn "onboarding\|ONBOARDING\|completeOnboarding" apps/lambdas/ apps/web/ --include="*.ts" --include="*.tsx" -r

# Trigger type includes ONBOARDING
grep -rn "ONBOARDING" packages/db/src/schema/planner.ts packages/types/src/
```

---

## Integration Point 9: Module Pauses -> Planner + AI

Paused modules excluded from calendar display and AI schedule generation.

**Verify**:
```bash
# Module pauses table and schema
grep -rn "modulePauses\|module_pauses" packages/db/src/schema/ --include="*.ts"

# Planner filters by isPaused
grep -rn "isPaused\|is_paused\|paused" apps/lambdas/planner-lambda/src/ --include="*.ts"

# AI scheduler excludes paused modules
grep -rn "paused\|active\|isActive\|modulePauses" apps/lambdas/ai-scheduler-lambda/src/ --include="*.ts"

# Calendar grays out paused module blocks
grep -rn "paused\|dimmed\|opacity\|grayed" apps/web/components/planner/ --include="*.tsx"
```

**SQL verification**:
```sql
-- Verify paused modules are excluded from schedule
SELECT mp.module_type, mp.paused_at
FROM module_pauses mp
WHERE mp.user_id = :userId;

-- Time blocks for paused modules still exist but should be visually dimmed
SELECT tb.id, tb.module_type, tb.title,
       CASE WHEN mp.id IS NOT NULL THEN 'PAUSED' ELSE 'ACTIVE' END as status
FROM time_blocks tb
LEFT JOIN module_pauses mp ON mp.user_id = tb.user_id AND mp.module_type = tb.module_type
WHERE tb.user_id = :userId
  AND tb.start_time >= :weekStart
  AND tb.deleted_at IS NULL;
```

---

## Integration Point 10: Time Blocks -> Linked Entities

Time blocks reference specific workout sessions, meals, etc. via `linkedEntityId` and `linkedEntityType`.

### Valid linkedEntityType Values

| linkedEntityType | References Table | Created By |
|-----------------|-----------------|------------|
| `workout_session` | workout_sessions.id | Scheduling a workout |
| `meal` | meals.id | Logging a meal time |
| `supplement_dose` | supplement_logs.id | Supplement timing |
| `health_check` | health_logs.id | Health check reminder |
| `custom` | NULL | Manual user block |
| `ai_suggested` | NULL | AI-generated block |

**Verify**:
```bash
# linkedEntityId and linkedEntityType in time_blocks schema
grep -rn "linkedEntityId\|linkedEntityType\|linked_entity" packages/db/src/schema/planner.ts packages/types/src/planner.ts

# Frontend resolves linked entities to show detail when clicked
grep -rn "linkedEntity\|linked_entity" apps/web/components/planner/ --include="*.tsx"
```

**SQL referential integrity check**:
```sql
-- Verify all linked entities actually exist (no dangling references)
SELECT tb.id, tb.linked_entity_type, tb.linked_entity_id, tb.title
FROM time_blocks tb
WHERE tb.linked_entity_id IS NOT NULL
  AND tb.user_id = :userId
  AND tb.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM workout_sessions ws WHERE ws.id = tb.linked_entity_id::uuid AND tb.linked_entity_type = 'workout_session'
    UNION ALL
    SELECT 1 FROM meals m WHERE m.id = tb.linked_entity_id::uuid AND tb.linked_entity_type = 'meal'
    UNION ALL
    SELECT 1 FROM supplement_logs sl WHERE sl.id = tb.linked_entity_id::uuid AND tb.linked_entity_type = 'supplement_dose'
    UNION ALL
    SELECT 1 FROM health_logs hl WHERE hl.id = tb.linked_entity_id::uuid AND tb.linked_entity_type = 'health_check'
  )
  AND tb.linked_entity_type NOT IN ('custom', 'ai_suggested');
-- Expected: 0 rows (no dangling references)
```

---

## Integration Test Scenarios

| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| 1 | Meal -> Grocery -> Finance | Log 3 meals -> Generate grocery list -> Mark items with costs | cost_entries created, finance summary updated |
| 2 | Bad sleep -> Workout hint | Log health with sleep_quality=1 -> Check hints endpoint | Hint suggests lighter workout |
| 3 | Onboarding -> AI Schedule | Complete goal settings -> Trigger schedule | time_blocks created for all active modules |
| 4 | Pause module -> Calendar | Pause WORKOUT module -> Check planner/week | Workout blocks visually dimmed, AI excludes workouts |
| 5 | Workout -> Spacing check | Complete chest workout -> Schedule another within 24h | Spacing violation returned |

### Integration Test Code Patterns

```typescript
describe('Nutrition -> Grocery integration', () => {
  it('generates grocery list from selected meals with aggregated ingredients', async () => {
    // 1. Create/select meals with known ingredients
    // 2. Call POST /grocery/lists/generate with meal IDs
    // 3. Verify grocery items match aggregated ingredients
    // 4. Verify quantities are summed correctly
    // 5. Verify store sections are assigned
  })
})

describe('Workout -> Muscle History integration', () => {
  it('completing workout updates history and blocks scheduling within 48h', async () => {
    // 1. Complete a Push Day session
    // 2. Verify muscle_group_history updated for chest, shoulders, triceps
    // 3. Call POST /workouts/check-spacing for Push Day
    // 4. Verify violation returned (< 48h)
    // 5. Wait (or mock time) 49h
    // 6. Verify no violation returned
  })
})
```

---

## Report Format

```
Module Integration Report
==========================

[PASS] Planner <-> All Modules: TimeBlock types complete, calendar renders all
[PASS] Nutrition -> Grocery: aggregation function exists, generate endpoint works
[WARN] Grocery -> Finances: cost_entry creation not implemented yet
[PASS] Health -> Workouts: AI scheduler reads sleep data, adjusts on low quality
[PASS] Workouts -> Muscle History: session completion writes history, spacing check reads it
[PASS] AI Scheduler -> All: reads from all module tables, generates complete schedule
[PASS] Onboarding -> AI: ONBOARDING trigger type exists and fires
[WARN] Module Pauses -> AI: pause filtering not yet in scheduler prompt
[PASS] Time Blocks -> Linked Entities: linkedEntityId/Type in schema and frontend

Score: 8/10 integration points verified (2 warnings)
```
