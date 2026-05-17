# §A — Problem & Vision

**Goal:** understand WHY this sprint matters. Without sharp answers here, every later section drifts.

**Always asked.** Cannot be skipped.

**Refuse to advance if:** the "why now" answer is vague or the success vision is undefined. Push back, ask follow-ups, do NOT proceed until §A has signal.

## Discovery goals

1. The specific problem in user voice (not "improve X" — "users abandon onboarding at step 4 because of Y")
2. The specific people who feel the problem (personas: founders, early users, onboarding users)
3. The trigger event — why solve NOW vs later
4. How this advances the <BRAND_SLUG_TITLE> "10 min/day, get rest of life scheduled" promise — or explicit acknowledgment it's tactical not strategic
5. The vision of the world post-ship

## Typical question shape (adapt wording each run)

- A1 — **Problem statement**: "In your own words, what's broken or missing today? Don't say 'we should improve X' — say what specifically goes wrong, when, and for whom."
- A2 — **Who suffers**: "Pick 1-2 personas: founder, early-user, onboarding-user, returning-user. For each, describe HOW this problem hits them in their day."
- A3 — **Why now**: "What changed that makes this urgent? Did a user complain, did data surface a pattern, did a competitor ship, did a deadline appear? If 'no trigger', why is THIS the next sprint vs a different one?"
- A4 — **Strategic fit**: "Does this advance our 10-min/day promise? Or is it a tactical fix that doesn't move the strategic dial? Either is fine — be honest."
- A5 — **Success vision**: "Describe the world 2 weeks from now, after we ship. What does the user see, do, or feel that they couldn't before? 2-3 sentences."

## Conditional follow-ups

- If A1 mentions an existing <BRAND_SLUG_TITLE> module by name → surface recalled patterns from memory for that module
- If A3 is "no trigger" → ask: "What evidence convinced you this is worth a 2-week appetite?"
- If A5 is vague → ask: "Imagine a user just shipped this. What's the first specific thing they do/see that's different?"

## Output flags (set in `sections_answers.A`)

- `backend_only: true/false` — inferred from A1 (does it mention UI?)
- `frontend_only: true/false`
- `pure_refactor: true/false` — A1 says "no user-visible change"
- `no_schema_change: true/false` — A1 explicitly says no data/storage change
- `no_ui: true/false`
- `strategic: true/false` — from A4

These flags drive skip decisions for §B-§G.

## Recall targets

Memory keys likely relevant:

- `<BRAND_SLUG>-build-context`
- `<BRAND_SLUG>-mvp-build-complete`
- `<BRAND_SLUG>-known-gaps`
- Any `<BRAND_SLUG>-<module>-*` for the module mentioned in A1

## Coherence note

After §A, you have the SHAPE of the sprint. §B-§J should consistently match. If during later sections answers diverge from §A flags, surface in the day-3 coherence check.
