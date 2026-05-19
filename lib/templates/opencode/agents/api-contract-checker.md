---
name: api-contract-checker
description: Verifies API route contracts match Zod schemas, TypeScript types, test coverage, and frontend hooks
tools: Read, Grep, Glob
---

# API Contract Checker

Verify all Lambda routes have matching Zod schemas, Supertest coverage, correct response shapes, and connected frontend hooks.

---

## Check 1: Route Discovery

Discover all implemented routes across all Lambdas:

```bash
# Method 1: Grep handler routers
for dir in apps/lambdas/*/; do
  echo "=== $(basename $dir) ==="
  grep -n "method === \|path === \|path\.match\|httpMethod.*GET\|httpMethod.*POST\|httpMethod.*PUT\|httpMethod.*DELETE" "$dir/src/handler.ts" 2>/dev/null
done

# Method 2: List route files
for dir in apps/lambdas/*/src/routes/; do
  echo "=== $(dirname $(dirname $dir)) ==="
  ls "$dir" 2>/dev/null
done

# Method 3: Find exported route functions
grep -rn "export async function\|export function" apps/lambdas/*/src/routes/ --include="*.ts"

# Method 4: Count routes per Lambda
for dir in apps/lambdas/*/; do
  count=$(grep -c "method === \|path === \|path\.match" "$dir/src/handler.ts" 2>/dev/null || echo 0)
  echo "$(basename $dir): $count routes"
done
```

**Expected route counts** (from system spec section 9):

| Lambda | Count | Key Endpoints |
|--------|-------|---------------|
| auth-lambda | 4 | me, profile, goals (GET+POST) |
| planner-lambda | 9 | week, blocks CRUD, pause, status, schedule cached+accept |
| workouts-lambda | 12 | templates, sessions, sets, muscle-history, check-spacing, previous, exercises |
| nutrition-lambda | 10 | meals, log, targets, summary |
| supplements-lambda | 10 | catalog, user, log, inventory, schedule |
| grocery-lambda | 7 | lists, generate, items |
| health-lambda | 5 | log, logs, hints, dismiss |
| finances-lambda | 5 | budget, summary, costs |
| ai-scheduler-lambda | 3 | generate, cached, regenerate |

**Total: 65 routes across 9 Lambdas.**

---

## Check 2: Schema Matching

For every route that accepts a request body (POST/PUT), verify a Zod schema exists:

```bash
# All schemas in types package
grep -rn "export const.*Schema" packages/types/src/ --include="*.ts" | sort

# Route handlers using validateBody (which requires a schema)
grep -rn "validateBody" apps/lambdas/*/src/routes/ --include="*.ts"

# Route handlers missing validateBody on write operations
for f in apps/lambdas/*/src/routes/*.ts; do
  has_write=$(grep -l "POST\|PUT\|create\|update\|insert" "$f" 2>/dev/null)
  if [ -n "$has_write" ] && ! grep -q "validateBody" "$f"; then
    echo "MISSING SCHEMA: $f"
  fi
done
```

Also verify query parameter validation:
```bash
# Routes with query params should validate them
grep -rn "queryStringParameters\|searchParams" apps/lambdas/*/src/routes/ --include="*.ts" | while read line; do
  file=$(echo "$line" | cut -d: -f1)
  if ! grep -q "parse\|safeParse\|Schema" "$file"; then
    echo "UNVALIDATED QUERY PARAMS: $file"
  fi
done

# Check that every schema is re-exported from index.ts
grep -rn "export.*from" packages/types/src/index.ts
```

---

## Check 3: Response Shape Consistency

```bash
# All ok() calls -- verify they return data matching output types
grep -rn "return ok(" apps/lambdas/*/src/routes/ --include="*.ts"

# All error() calls -- verify they follow standard format
grep -rn "return error(" apps/lambdas/*/src/routes/ --include="*.ts"

# Check for non-standard responses (bypassing ok/error helpers)
grep -rn "return {" apps/lambdas/*/src/routes/ --include="*.ts" | grep "statusCode"
# Should only find in handler.ts OPTIONS response, not in route files

# Find responses NOT using the ok() wrapper (inconsistent)
grep -rn "statusCode: 200" apps/lambdas/*/src/routes/ --include="*.ts" | grep -v "ok("
```

Standard shapes:
- Success: `{ success: true, data: T }`
- Error: `{ success: false, error: string | object }`
- Delete: `{ success: true, data: { deleted: true } }`

### Pagination Metadata Verification

```bash
# Find paginated endpoints (those using .limit and .offset)
grep -rn "\.limit(\|\.offset(" apps/lambdas/*/src/routes/ --include="*.ts"

# Verify they return total count alongside results
grep -rn "total\|count\|pagination" apps/lambdas/*/src/routes/ --include="*.ts" | grep -v "test"

# Check that count query exists alongside paginated select
grep -rn "COUNT\|count()" apps/lambdas/*/src/routes/ --include="*.ts"
```

**Endpoints that must paginate**:
- `GET /workouts/sessions` (session history)
- `GET /nutrition/meals` (meal database browse)
- `GET /finances/costs` (cost entry list)

Expected pagination response shape:
```typescript
{
  success: true,
  data: T[],
  pagination: {
    total: number,
    page: number,
    pageSize: number,
    hasMore: boolean
  }
}
```

---

## Check 4: Test Coverage

```bash
# Test files per Lambda
for dir in apps/lambdas/*/; do
  name=$(basename $dir)
  test_count=$(grep -c "it(" "$dir/__tests__/"*.test.ts 2>/dev/null || echo 0)
  route_count=$(grep -c "method === \|path === " "$dir/src/handler.ts" 2>/dev/null || echo 0)
  echo "$name: $route_count routes, $test_count test cases"

  # Check for 4 required test types
  has_200=$(grep -c "200" "$dir/__tests__/"*.test.ts 2>/dev/null || echo 0)
  has_401=$(grep -c "401" "$dir/__tests__/"*.test.ts 2>/dev/null || echo 0)
  has_400=$(grep -c "400" "$dir/__tests__/"*.test.ts 2>/dev/null || echo 0)
  has_404=$(grep -c "404" "$dir/__tests__/"*.test.ts 2>/dev/null || echo 0)
  echo "  Coverage: 200=$has_200 401=$has_401 400=$has_400 404=$has_404"
done

# Find Lambda route files that have no corresponding test file
for dir in apps/lambdas/*/; do
  route_count=$(grep -c "path === " "$dir/src/handler.ts" 2>/dev/null || echo 0)
  test_count=$(ls "$dir/__tests__/"*.test.ts 2>/dev/null | wc -l)
  if [ "$test_count" -eq 0 ] && [ "$route_count" -gt 0 ]; then
    echo "NO TESTS: $(basename $dir) ($route_count routes)"
  fi
done
```

**Minimum per route**: 4 test cases (200 happy path, 401 auth, 400 validation, 404 wrong user).

---

## Check 5: Frontend Hook -> Backend Route Mapping

```bash
# All TanStack Query hooks
grep -rn "useQuery\|useMutation" apps/web/hooks/ --include="*.ts" -A 3 | grep -E "queryFn|mutationFn|api\."

# API endpoints called from frontend
grep -rn "api\.get\|api\.post\|api\.put\|api\.delete\|fetch(" apps/web/hooks/ --include="*.ts"
grep -rn "api\.get\|api\.post\|api\.put\|api\.delete\|fetch(" apps/web/lib/ --include="*.ts"

# Query key factory completeness
grep -rn "queryKeys" apps/web/lib/query-keys.ts

# Cross-reference: all URLs called by frontend
grep -oP "'/v1/[^']*'" apps/web/hooks/*.ts | sort -u

# Find mutation invalidation targets (must invalidate parent query)
grep -rn "invalidateQueries" apps/web/hooks/ --include="*.ts" -A 2
```

For each frontend API call, verify:
1. The endpoint URL matches a real Lambda route
2. The request payload matches the Zod input schema
3. The response is typed with the correct output type
4. Mutations include optimistic update with `onMutate`/`onError`/`onSettled`

---

## Check 6: CLAUDE.md Route Table Accuracy

```bash
# Extract documented routes from each CLAUDE.md
for md in apps/lambdas/*/CLAUDE.md; do
  echo "=== $md ==="
  grep -E "^\| (GET|POST|PUT|DELETE)" "$md" 2>/dev/null | wc -l
done

# Compare with actual routes in handler
for dir in apps/lambdas/*/; do
  name=$(basename $dir)
  doc_routes=$(grep -cE "^\| (GET|POST|PUT|DELETE)" "$dir/CLAUDE.md" 2>/dev/null || echo 0)
  impl_routes=$(grep -c "method === \|path === " "$dir/src/handler.ts" 2>/dev/null || echo 0)
  if [ "$doc_routes" != "$impl_routes" ]; then
    echo "MISMATCH: $name has $impl_routes implemented routes but $doc_routes documented"
  fi
done
```

Cross-reference rules:
- Every route in handler.ts must appear in CLAUDE.md
- Every route in CLAUDE.md must be implemented in handler.ts
- No phantom routes (documented but not implemented)
- No undocumented routes (implemented but not documented)

---

## Methodology: Cross-Referencing Routes <-> Schemas <-> Tests <-> Hooks

For each of the 65 routes, build a row in this matrix:

| Route | Zod Schema | Supertest | Frontend Hook | CLAUDE.md |
|-------|-----------|-----------|---------------|-----------|
| `GET /auth/me` | N/A (no body) | auth.test.ts:L12 | useProfile | Documented |
| `POST /planner/blocks` | createBlockSchema | planner.test.ts:L45 | useCreateBlock | Documented |
| ... | ... | ... | ... | ... |

**To find mismatches programmatically**:

```bash
#!/bin/bash
echo "Cross-Reference Matrix"
echo "======================"

# For each Lambda, extract routes and check all 4 dimensions
for dir in apps/lambdas/*/; do
  name=$(basename $dir | sed 's/-lambda//')
  handler="$dir/src/handler.ts"
  [ ! -f "$handler" ] && continue

  echo ""
  echo "=== $name ==="

  # Extract each route path
  grep -oP "path === '[^']+'" "$handler" | while read match; do
    path=$(echo "$match" | grep -oP "'[^']+'")
    method=$(grep -B1 "$match" "$handler" | grep -oP "GET|POST|PUT|DELETE" | head -1)

    schema="N/A"
    if [ "$method" = "POST" ] || [ "$method" = "PUT" ]; then
      schema=$(grep -l "validateBody" "$dir/src/routes/"*.ts 2>/dev/null | head -1)
      [ -z "$schema" ] && schema="MISSING"
    fi

    test_hit=$(grep -rl "$path" "$dir/__tests__/"*.test.ts 2>/dev/null | head -1)
    [ -z "$test_hit" ] && test_hit="MISSING"

    hook_hit=$(grep -rl "$path" apps/web/hooks/ 2>/dev/null | head -1)
    [ -z "$hook_hit" ] && hook_hit="MISSING"

    echo "  $method $path | schema=$schema | test=$test_hit | hook=$hook_hit"
  done
done
```

---

## Example: Found Mismatch Report

```
MISMATCH FOUND:
  Lambda: workouts-lambda
  Route: GET /workouts/sessions/:id/previous
  Status:
    handler.ts: IMPLEMENTED (line 87)
    Zod schema: MISSING -- no previousSessionQuerySchema in packages/types/src/workouts.ts
    Supertest: MISSING -- no test case in __tests__/workouts.test.ts
    Frontend hook: PRESENT -- usePreviousSession in apps/web/hooks/useWorkouts.ts:45
    CLAUDE.md: DOCUMENTED

  Action required:
    1. Create previousSessionQuerySchema in packages/types/src/workouts.ts
    2. Add query param validation in route handler
    3. Add Supertest cases for 200, 401, 404
```

---

## Report Format

```
API Contract Validation Report
================================

planner-lambda:
  Routes: 9 defined, 9 implemented
  Schemas: 9/9 present
  Tests: 36 cases (9 routes x 4 minimum)
  Frontend hooks: 9/9 connected
  CLAUDE.md: 9/9 documented
  Optimistic updates: 6/6 mutations have onMutate
  Status: COMPLETE

workouts-lambda:
  Routes: 12 defined, 10 implemented
  [GAP] Missing: GET /workouts/sessions/:id/previous
  [GAP] Missing: POST /workouts/check-spacing
  Schemas: 10/12 present
  [GAP] Missing: checkSpacingInputSchema
  Tests: 32 cases (8 routes x 4)
  [GAP] Routes muscle-history, check-spacing, previous, exercises untested
  Frontend hooks: 10/12
  Status: 2 GAPS

Summary:
  Total routes: 65 spec, 61 implemented (4 gaps)
  Schema coverage: 59/65 (6 missing)
  Test coverage: 228/260 minimum cases (32 missing)
  Frontend coverage: 58/65 hooks (7 missing)
  Action items: 4 routes to implement, 6 schemas to add, 32 tests to write
```
