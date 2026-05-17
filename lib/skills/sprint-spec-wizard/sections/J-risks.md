# §J — Risks, Security, Rollback

**Goal:** surface unknowns + security implications + rollback strategy + open questions.

**Always asked.** Final section before assembly.

## Discovery goals

1. Security risks (PII, injection, auth gaps, RLS holes)
2. Privacy implications (what user data flows where, retention)
3. Rollback strategy (Vercel preview / feature flag / blue-green / soft-delete-only)
4. Open questions (what we don't know yet — surface unknowns up front)

## Typical question shape

- J1 — **Security risks**: "Based on §C-§D-§H, I see these security surfaces: <auto-detected list>. For each, what's the risk and mitigation? (Examples: 'RLS gap on new table → 4-policy template applied'; 'No injection risk — Zod validates'). Also: any auth flow changes?"
- J2 — **Privacy**: "Data touched: <from C5/H1>. Retention policy? (<BRAND_SLUG_TITLE> default: indefinite, user-controlled deletion via soft-delete). Encryption-at-rest: already enabled per <BRAND_NAME> setup — confirm."
- J3 — **Rollback**: "How do we revert if this breaks prod? <BRAND_SLUG_TITLE> defaults: Vercel preview deploy → smoke test → promote; DB rollback via soft-delete + additive-only migrations. Need feature flag for staged rollout, or default plan sufficient?"
- J4 — **Open questions**: "What do we still NOT know? List unknowns. For each: (a) decide now, (b) accept ambiguity + revisit at design lock, (c) needs a spike before sprint can proceed."

## Conditional follow-ups

- If §C had `pii_touched == true` → J1 depth +2 questions (specific PII fields + handling)
- If §H included external APIs → J1 must cover failure modes (retry policy, fallback behavior)
- If J3 chooses feature flag → require flag name + rollout percentage strategy
- If J4 has >2 "needs spike" items → propose adding a 1-2 day spike before main build

## Output flags

- `security_risks_count: <N>`
- `requires_spike: true/false`
- `requires_feature_flag: true/false`
- `pii_handling_documented: true/false`

## Recall targets

- `<BRAND_SLUG>-causal-rls-skip-leak`
- `<BRAND_SLUG>-causal-s3-bucket-acl-deprecated`
- `security-pattern`
- `<BRAND_SLUG>-encryption-at-rest-setup`

## Style guidance

- J1 is auto-generated from prior sections + memory recall — user mostly confirms
- J2 PII default is "indefinite with soft-delete" — override requires explicit reason
- J3 default plan covers 90% of cases — feature flags only for true staged rollouts
- J4 is the LAST place to surface unknowns — push hard: "Anything you're hand-waving? Now's the time."

## After §J completes

This is the final discovery section. After J completes:

1. Run §G-cyclic coherence check (final, covers §G, §H, §I, §J)
2. Run `scripts/sprint-wizard-assemble.mjs <slug>` to render `spec.md`
3. Present assembled spec to user for read-through
4. User signs off → return control to `sprint-orchestrator` Phase 1 review chain
