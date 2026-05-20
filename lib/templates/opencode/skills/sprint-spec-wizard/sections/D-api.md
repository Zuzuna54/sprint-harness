# §D — API Surface

**Goal:** endpoints + Zod request/response + auth + error cases.

**Skip if:** `sections_answers.A.frontend_only == true` AND no Lambda routes touched.

## Discovery goals

1. New or modified endpoints (method + path + purpose)
2. Request/response Zod schemas
3. Auth requirements (who can call, what scopes)
4. Error cases (400/401/403/404/409/422/500 with conditions)
5. External APIs (if applicable) with retry/timeout/circuit-breaker strategy

## Typical question shape

- D1 — **Endpoints**: "Based on §B-§C, I scanned existing `apps/lambdas/<module>/src/manifest.ts` and propose these new/modified endpoints: <pre-filled list>. Accept, modify, or different surface? (Format: METHOD /path → purpose)"
- D2 — **Zod schemas**: For each endpoint in D1, "Sketch the request and response Zod schemas. I drafted these from §B entities: <prefilled>. Edit?"
- D3 — **Auth**: "<BRAND_PRODUCT_NAME> default is `requireUser()` on every route via auth-middleware. Confirm for each endpoint, or any public/scoped exceptions?"
- D4 — **Errors**: "Here are the error cases I'd handle: <prefilled standard set 400/401/404/422/500 + domain-specific>. Add or remove?"
- D5 (conditional) — **External APIs**: "Does this call Gemini, Supabase Auth, HealthKit, or external? If yes: timeout, retry strategy, circuit-breaker needed?"

## Conditional follow-ups

- If D1 endpoint touches PII → flag for §J security
- If D2 schema is complex (nested >2 deep) → recommend splitting into sub-schemas
- If D5 mentions Gemini → recall `ai-integration` pattern from memory
- If D1 adds a `DELETE` route → BLOCK; require soft-delete equivalent

## Output flags

- `lambda_routes_added: [<list>]`
- `lambda_routes_modified: [<list>]`
- `external_apis: [<list>]` → drives §H integration points

## Recall targets

- `<BRAND_SLUG>-lambda-handler-5-step` (auto-applied to all D2 schemas)
- `<BRAND_SLUG>-causal-rls-skip-leak` (surface if any route returns user-scoped data)
- `ai-integration` (if D5 mentions Gemini)
- `database-pattern` (if Drizzle queries are non-trivial)

## Style guidance

- Pre-fill the manifest.ts diff — user should mostly accept rather than dictate routes
- Zod schemas use <BRAND_PRODUCT_NAME> naming convention (`<Action>Request`, `<Action>Response`)
- Force `requireUser()` as default; explicit opt-out required for public routes
- Error handling MUST follow <BRAND_PRODUCT_NAME> error class hierarchy (UnauthorizedError, NotFoundError, etc.)
