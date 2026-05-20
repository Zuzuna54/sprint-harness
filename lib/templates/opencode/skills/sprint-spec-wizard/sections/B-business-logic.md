# §B — Business Logic & Domain Rules

**Goal:** pin down entities, states, invariants, calculations, edge cases. The rules that govern the feature.

**Skip if:** `sections_answers.A.pure_refactor == true`.

## Discovery goals

1. Business objects (entities) involved
2. State each entity can be in + transitions between states
3. Domain invariants that must always hold
4. Calculations or aggregations (formulas, daily totals, streaks)
5. Edge cases (unusual scenarios that must be handled)

## Typical question shape

- B1 — **Entities**: "What business objects/concepts are involved? List them. (Examples from <BRAND_PRODUCT_NAME>: `MealPrepSession`, `SupplementLog`, `TimeBlock`, `WorkoutSet`, `HealthLog`)"
- B2 — **States per entity** (loop over each entity in B1):
  - "For `<entity>`, what state can it be in? List the states."
  - "What event/action transitions it from each state to another?"
- B3 — **Invariants**: "What MUST always hold true, regardless of what user does? (Examples: 'muscle group can't be trained twice in 48h', 'daily protein target ≥ 50% of TDEE × 0.16', 'soft-delete only — never hard delete')."
- B4 — **Calculations**: "Any aggregations or formulas? (Daily totals, streaks, %s, projections, deltas)"
- B5 — **Edge cases**: "Here are 3-5 likely edge cases based on §A and B1-4: <generated list>. For each: handle, ignore, or out-of-scope?"

## Conditional follow-ups

- For each entity in B1, if it's a brand-new entity (not in `packages/db/schemas/`) → flag for §C "new table required"
- If B3 mentions soft-delete → recall `<BRAND_SLUG>-soft-delete-pattern` memory
- If B4 mentions Drizzle queries with aggregations → propose helper in `packages/utils/`
- If B5 reveals an edge case that affects an existing module → surface to coherence check

## Output flags

- `new_entities: [<list>]` → drives C1
- `existing_entities_modified: [<list>]` → drives C2 follow-ups
- `pure_logic_layer: true/false` → no DB change needed

## Recall targets

- `<BRAND_SLUG>-soft-delete-pattern`
- `<BRAND_SLUG>-rls-4-policy-template`
- Module-specific patterns from §A
- Any `pattern_*` JSON in the memory store with `metadata.scope == <module>`

## Style guidance

- For B1, if user lists vague nouns ("things", "items"), push: "What's the canonical name for these in code?"
- For B2, loop is mandatory — don't skip any entity. Each entity gets a state diagram in spec.md.
- For B3, push back on vague invariants. "User can't do X" must specify how the system prevents X.
- For B5, you MUST propose edge cases — Claude is responsible for surfacing what user forgets.
