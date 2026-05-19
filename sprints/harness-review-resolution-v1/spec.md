# Sprint harness-review-resolution-v1: Current state: audit-resolution phase (v0

> Assembled from wizard sections by `sprint-wizard-assemble.mjs` on 2026-05-19T19:09:56.127Z.

## Status

- **Phase:** spec-wizard
- **Day:** 0 of 14
- **Started:** 2026-05-19T19:06:30Z
- **Gates passed:** [object Object], [object Object], [object Object], [object Object], [object Object], [object Object], [object Object], [object Object], [object Object], [object Object]
- **Drift score (latest):** N/A
- **Wizard sections captured:** A,H,I,J

---

## §A — Problem & Vision

### Problem statement

Current state: audit-resolution phase (v0.7.2) triages ONLY daemon-worker audit findings. Knip (verify-knip) and Sonar (verify-sonar) produce structured findings too but are recorded as advisory-only — no triage workflow, no Fix/Defer/Accept, no follow-up tracking. Generalize the audit-resolution infrastructure to handle all 3 finding-producers under a unified review-resolution phase before knip/sonar accumulate into legacy debt.

### Who suffers

- Persona: future operators (Claude + gio) running sprints. They get audit + knip + sonar findings during verifying. Without unified triage, operators ignore knip/sonar advisory until they grow into thousands like the .claude/helpers/\*.js audit findings did. Goal: prevent the same accumulation in dead-code + code-quality lanes.

### Why now

Trigger: harness-audit-resolution-and-scope-v1 closed 2026-05-19. Operator (gio) asked: where do knip + sonar fit? The audit-resolution flow works great for audit findings — we need the same discipline for knip + sonar BEFORE we accrue debt. Generalize NOW while the audit-resolution patterns are fresh + the 8 ship-conditions are proven.

### Strategic fit

Strategic. The 10-min/day promise depends on actionable signal across ALL finding lanes, not just security. Knip dead-code drags down navigation; sonar quality drags down readability. Without unified triage, operators desensitize.

### Success vision

Two weeks from now: (1) review-resolution phase supersedes audit-resolution (back-compat alias). (2) state.review_findings[] with producer-tagged entries. (3) sprint-review-resolve.sh handles 3 producers uniformly. (4) Exit predicate: resolved + deferred + accepted == total across all producers. (5) Knip + sonar become producing (not advisory). (6) Docs updated. (7) Dogfood walk through this very phase.

### Refinement

---

## §B — Business Logic & Domain Rules

> ⊘ §B was SKIPPED — reason: harness-infra: generalize audit-resolution to review-resolution; no new domain logic

---

## §C — Data & Schema

> ⊘ §C was SKIPPED — reason: no_schema_change: state.review_findings additive via atomic_update_state

---

## §D — API Surface

> ⊘ §D was SKIPPED — reason: no HTTP API surface

---

## §E — UI Components & Pages

> ⊘ §E was SKIPPED — reason: no_ui per A flags

---

## §F — UX Flow & Interactions

> ⊘ §F was SKIPPED — reason: no_ui per A flags

---

## §G — Visual Design & Brand

> ⊘ §G was SKIPPED — reason: no_ui per A flags

---

## §H — Integration Points

### LifeOS modules touched

- Modules touched: scripts/lib/phase-manifest.json (add review-resolution phase as alias/superset to audit-resolution); scripts/lib/phase-predicates.sh (new predicate kind review_resolution_complete OR extend audit_resolution_complete); NEW scripts/sprint-review-resolve.sh + sprint-review-rerun.sh; back-compat alias for audit-resolve/rerun scripts. scripts/sprint-deadcode-delete.mjs adds --json producer mode. scripts/sprint-sonar-parse.mjs adds --json producer mode. scripts/sprint-verify.sh records knip+sonar producers into state.review_findings[]. NEW docs/sprints/\_templates/review-resolutions.md. 4 docs (USAGE/QUICKSTART/DEVELOPER/SCRIPTS).

### External APIs

- External deps: zero new. Reuses existing knip (already a dep via sprint-deadcode-delete.mjs), sonar (already integrated via sprint-sonar-parse.mjs), node built-in jq processing, ruflo daemon audit worker.

### Cross-module events

- Event flow: verifying entry → 3 producers fire (audit worker existing + knip new producer mode + sonar new producer mode) → each writes producer-tagged findings to state.review_findings[] → advance to review-resolution → sprint-review-resolve.sh walks aggregated list across all producers → operator Fix/Defer/Accept regardless of producer → exit predicate validates resolved+deferred+accepted=total across union.

### Background workers / cron

_(none)_

### Refinement

---

## §I — Acceptance Criteria

### UI/E2E (Gherkin)

_(not provided)_

### Backend (INVEST)

_(not provided)_

### Performance bars

- P95 lambda response: < 800ms (LifeOS default)
- Payload: < 50KB
- DB queries per request: ≤ 2

### Manual QA checklist

_(none)_

### Refinement

---

## §J — Risks, Security, Rollback

### Security risks

- Risks: (1) Backward-compat for prior audit_findings views — alias via jq filter. (2) Knip false-positives (dynamic imports, codegen). Mitigation: knip.json exclusions respected. (3) Sonar may not have recent scan — vacuous PASS. (4) Phase rename — keep both audit-resolution and review-resolution valid; predicate works on either.

### Privacy implications

Security: knip/sonar findings only contain file paths (no PII). Triage rationales still PII-redacted via existing C5 path. Producer outputs land in worker-output/ committed audit trail.

### Rollback strategy

Rollback: per-AC commits. AC-1 manifest revert is single-file. AC-4/AC-5 producer changes revert per script. AC-7 doc edits regenerable.

### Open questions

- Out of scope: ESLint findings producer (already blocking via verify-lint). TypeScript producer (blocking via verify-typecheck). Task-sub-agent gates (api-contract / debug-rls / module-status / aidefence) — separate appetite if needed.

### Refinement

---

## Success criteria (overall)

- [ ] All ACs closed
- [ ] P95 < 800ms (LifeOS default)
- [ ] 0 RLS leakage in cross-user test
- [ ] Typecheck + lint + tests clean
- [ ] Mobile responsive verified at 375px

---

## Files touched (claims scope)

_(populated from wizard answers)_

---

## Module DoD (LifeOS standard)

- [ ] Lambda routes + Zod schemas
- [ ] RLS policies (4 per new table)
- [ ] Tests (unit + integration + E2E if user-facing)
- [ ] /api-contract-validation passes
- [ ] /debug-rls passes
- [ ] Typecheck + lint clean
- [ ] Soft-delete enforced
- [ ] Auth on every route
- [ ] Mobile responsive (375px)
- [ ] CLAUDE.md updated if convention emerged

---

## SPARC design _(filled day 1-2, after design lock)_

### Specification

_(formalized from §A-§J)_

### Pseudocode

_(algorithms + data flow)_

### Architecture

_(component diagram, sequence diagram)_

---

## Recalled patterns

- ✓ lifeos-audit-finding-explicit-triage (§auto, score 0.82) — applied to auto-backfill at assemble
- ✓ pattern_1778964834312_ee577055220ab5f8 (§auto, score 0.69) — applied to auto-backfill at assemble
- ✓ lifeos-signed-get-url-private-bucket (§auto, score 0.64) — applied to auto-backfill at assemble
- ✓ lifeos-scope-bound-at-gate-eval (§auto, score 0.63) — applied to auto-backfill at assemble
- ✓ lifeos-procedure-phantom-sweep (§auto, score 0.61) — applied to auto-backfill at assemble
- ✓ lifeos-sprint-harness-extraction (§auto, score 0.6) — applied to auto-backfill at assemble
- ✓ lifeos-sprint-pipeline-realistic-scheduling-delivered (§auto, score 0.6) — applied to auto-backfill at assemble
- ✓ pattern_1778965551611_69c3842f60a5b120 (§auto, score 0.6) — applied to auto-backfill at assemble
- ✓ swarm-lessons (§auto, score 0.57) — applied to auto-backfill at assemble
- ✓ pattern-doctor-surface-verify (§auto, score 0.57) — applied to auto-backfill at assemble

---

## Amendments

_(diff-tracked here as the sprint progresses)_
