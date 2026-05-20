# §H — Integration Points

**Goal:** which <BRAND_PRODUCT_NAME> modules touched + external APIs + cross-module events + scheduled jobs.

**Always asked.** Even backend-only refactors touch SOMETHING.

## Discovery goals

1. <BRAND_PRODUCT_NAME> modules touched (planner, nutrition, workouts, supplements, grocery, health, finances, ai-scheduler, auth, uploads, onboarding)
2. External APIs (Gemini, Supabase Auth, HealthKit, etc.)
3. Cross-module events — what side effects propagate
4. Background workers / cron — anything scheduled

## Typical question shape

- H1 — **Modules touched**: "Based on §C-§E file paths, this sprint touches: <auto-inferred list>. Confirm or add any I missed?" Multi-select with full <BRAND_PRODUCT_NAME> module list as options.
- H2 — **External APIs**: "Any external API calls? (Auto-detected from §D D5: <list>). Add others if missed."
- H3 — **Cross-module events**: "When this feature does X, does anything in another module need to react? Examples: 'completing workout updates `muscleGroupHistory` → planner re-evaluates next workout suggestion'. List all propagation paths."
- H4 — **Background workers**: "Anything cron'd or scheduled? E.g., 'Sunday batch generates next week's meal plan'. If yes, which Lambda owns the cron and what's the schedule?"

## Conditional follow-ups

- If H1 includes auth → escalate §J security depth
- If H2 includes Gemini → require retry/timeout/circuit-breaker in spec
- If H3 surfaces events → flag for SPARC design phase (sequence diagram needed)
- If H4 adds new cron → require EventBridge rule in §C migration / infra section

## Output flags

- `modules_touched_count: <N>`
- `external_apis: [<list>]`
- `cross_module_events: [<list>]`
- `new_cron_jobs: [<list>]`

## Recall targets

- `ai-integration` (if Gemini)
- `<BRAND_SLUG>-supabase-url-distinction` (always)
- Module-specific patterns for any module in H1

## Style guidance

- Auto-infer from §C/§D file paths — user mostly confirms
- Cross-module events are often forgotten — push for explicit list
- Cron jobs require explicit Lambda owner — no orphan schedules
