# §F — UX Flow & Interactions

**Goal:** happy path + error paths + empty states + loading states + transitions.

**Skip if:** `sections_answers.A.backend_only == true` OR `A.no_ui == true`.

## Discovery goals

1. Happy path — step-by-step user journey from entry to success
2. Error paths — what happens on network/validation/permission failure
3. Empty states — first-time user with no data
4. Loading states — skeleton, spinner, optimistic update per surface
5. Transitions / animations — Framer Motion needs

## Typical question shape

- F1 — **Happy path**: "Walk me through the user's journey, step by step. Start: where do they enter? End: what success looks like. Numbered list."
- F2 — **Error paths**: "Based on F1 and §D (error cases), here are 4 likely failure points: <generated from F1 + D4>. For each: toast / inline error / redirect / full-screen error?"
- F3 — **Empty state**: "First-time user with no data — what do they see? CTA, illustration, onboarding hint, or hidden until populated?"
- F4 — **Loading states**: "For each interaction in F1 that fetches data: skeleton (LifeOS default), spinner, or optimistic update? Mutations typically optimistic per LifeOS convention."
- F5 — **Transitions**: "Any specific animations needed? (Framer Motion defaults to subtle fade — most LifeOS pages don't need custom animations.) Call out any explicit needs."

## Conditional follow-ups

- If F1 has >5 steps → push: "This is a long flow. Could it be 3 steps via X? Or do all 5 carry weight?"
- If F2 lacks permission-fail handling → required: "What happens if user lacks permission? (LifeOS default: redirect to /login)"
- If F3 says "empty just shows nothing" → push: "Empty UIs feel broken. What's the first-action CTA?"
- If F4 mismatches with §D auth → flag: "You said optimistic update, but D3 says auth-required — handle 401 in optimistic rollback?"

## Output flags

- `flow_step_count: <N>` → drives I1 Gherkin scenario count
- `mutations: [<list>]` → drives F4 detail
- `error_paths: [<list>]` → drives I error scenarios

## Recall targets

- `frontend-hook-pattern` (optimistic updates pattern)
- `Ordex Planner design-parity` (if planner-adjacent)
- `lifeos-causal-rls-skip-leak` (if F1 fetches user-scoped data)

## Style guidance

- F1 must be a numbered list of specific user actions, not abstract goals
- F2 MUST cover network + validation + permission at minimum
- F3 is often forgotten — push for explicit answer
- F4 defaults: skeleton for queries, optimistic for mutations
- F5 is usually short — Framer Motion subtle fade covers most cases
