# Sprint harness-audit-resolution-and-scope-v1: Two load-bearing harness gaps surfaced by harness-truthful-docs-and-wiring-v1 do

> Assembled from wizard sections by `sprint-wizard-assemble.mjs` on 2026-05-19T17:45:50.189Z.

## Status

- **Phase:** spec-wizard
- **Day:** 0 of 14
- **Started:** 2026-05-19T17:43:24Z
- **Gates passed:** [object Object], [object Object], [object Object], [object Object], [object Object], [object Object], [object Object], [object Object], [object Object], [object Object]
- **Drift score (latest):** N/A
- **Wizard sections captured:** A,H,I,J

---

## §A — Problem & Vision

### Problem statement

Two load-bearing harness gaps surfaced by harness-truthful-docs-and-wiring-v1 dogfood: (1) verify-worker-audit runs against the entire repo producing 10+ pre-existing findings per sprint regardless of touched files — 100% noise this session; without scope-bounding the audit-resolution loop never converges; (2) no audit-resolution phase exists between verifying and pre-deploy, so when audit produces findings the canonical pattern becomes bypass-with-rationale-and-ship. Combined sprint fixes both + fixes the 10 actual HAR-1..10 vulnerabilities in .claude/helpers/{github-safe,memory,session,statusline}.js triaged from the prior sprint.

### Who suffers

- Single persona: future LLMs (Claude Code sessions, sub-agents) AND human operators driving sprints that touch security-sensitive code. They MUST get real audit signal (in-scope only) AND have appetite to actually fix findings before sprint-end. Without this sprint, every future sprint hits the same 100% noise audit + the same bypass-to-ship pattern that drove the closure sprint corner-cutting we just audited.

### Why now

Trigger: harness-truthful-docs-and-wiring-v1 just closed (2026-05-19) and its dogfood produced exactly the failure mode we documented as a load-bearing gap. The fix MUST land before v0.8.0 because legacy SPRINT\_\*\_BYPASS removal in v0.8 would land WITHOUT the audit-resolution-phase infrastructure to catch issues surfaced by the cleanup. Two follow-up sprints filed (harness-audit-resolution-v1 + harness-scope-bounded-workers-v1) — combining them per user direction because scope-bounding must land before audit-resolution-walk runs (else the resolution walk surfaces the same 100% noise).

### Strategic fit

Strategic. The 10-min/day promise depends on the harness producing trustworthy verify signal. A 100% noise audit (or a sprint that ships with known vulns because operators ran out of fix time) breaks operator trust irrevocably. This sprint converts the audit→bypass-ship pattern into audit→fix-or-defer-with-named-AC, and converts repo-wide noise to in-scope signal.

### Success vision

Two weeks from now: (1) every sprint that runs verify gets in-scope-only audit findings (out-of-scope advisory only). (2) new audit-resolution phase exists between verifying + pre-deploy with 4-day operator capacity to walk findings interactively via sprint-audit-resolve.sh. (3) the 10 HAR vulns in .claude/helpers/\*.js are FIXED (HAR-1..10 each with test file proving fix). (4) docs reflect both new mechanisms (USAGE.md 14-day flow row for audit-resolution + worker scope subsection; SCRIPTS.md complete inventory including 4 previously-undocumented + 2 new audit scripts). (5) replay validator handles backward-compat via phase_manifest_version_seen. (6) sprint-status.sh resolves to correct slug. (7) post-commit hook respects Edit-tool atomicity.

### Refinement

---

## §B — Business Logic & Domain Rules

> ⊘ §B was SKIPPED — reason: harness-infrastructure sprint: no new business logic; wiring + 10 HAR security fixes + new phase definition

---

## §C — Data & Schema

> ⊘ §C was SKIPPED — reason: no*schema_change per §A flags; only state.json shape additions (audit_findings*\*) via existing atomic_update_state, no DB migration

---

## §D — API Surface

> ⊘ §D was SKIPPED — reason: no HTTP API surface; sprint touches scripts/.claude/helpers/.husky/docs/manifests only

---

## §E — UI Components & Pages

> ⊘ §E was SKIPPED — reason: no_ui per §A flags

---

## §F — UX Flow & Interactions

> ⊘ §F was SKIPPED — reason: no_ui per §A flags

---

## §G — Visual Design & Brand

> ⊘ §G was SKIPPED — reason: no_ui per §A flags

---

## §H — Integration Points

### LifeOS modules touched

- Modules touched: (Wave 1 scope) scripts/lib/worker-gates.sh, scripts/sprint-verify.sh, scripts/lib/phase-workers.json. (Wave 2 audit-resolution) scripts/lib/phase-manifest.json, NEW scripts/sprint-audit-resolve.sh, NEW scripts/sprint-audit-rerun.sh, NEW docs/sprints/\_templates/audit-resolutions.md. (Wave 3 HAR fixes) .claude/helpers/github-safe.js + memory.js + session.js + statusline.js + NEW .claude/helpers/**tests**/\*.test.cjs. (Wave 4 docs+polish) docs/sprints/{USAGE,QUICKSTART,DEVELOPER,SCRIPTS}.md, scripts/sprint-replay-validator.mjs, scripts/sprint-status.sh, .husky/post-commit.

### External APIs

- External dependencies: Node built-in crypto (aes-256-gcm + scryptSync) for HAR-2/HAR-4 encryption — ZERO new npm deps per user locked decision. ruflo daemon audit worker (existing). jq + bash 3.2+ (existing). NO new external deps introduced.

### Cross-module events

- Event flows: (1) sprint-advance-phase.sh verifying→audit-resolution → reads worker-output/audit.json → state.audit_findings_total set. (2) sprint-audit-resolve.sh loops findings → operator Fix/Defer/Accept → record_sub_step + atomic_update_state mutations. (3) Fix path → sprint-audit-rerun.sh fires audit worker (now scope-bound) → diffs against baseline → exit 0 if finding gone OR exit 1 if regression. (4) audit-resolution→pre-deploy exit predicate validates resolved+deferred+accepted=total + every deferred has slug+ac_id.

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

- Top risks: (1) AC-5 audit-resolution phase is XL — risk of placeholder predicate logic. Mitigation: real exit-predicate jq logic + smoke against fixture before claiming PASS. (2) AC-10/AC-12 encryption (HAR-2/HAR-4) — risk of breaking existing memory.json / session.json data. Mitigation: detect legacy-plaintext format on load + transparent migrate-on-first-write. (3) AC-6 sprint-audit-resolve.sh interactive UX — risk of operator quit mid-walk. Mitigation: every decision atomically written; resume picks up where left off. (4) AC-19 G3 post-commit hook lockfile — risk of deadlock if orphaned. Mitigation: 30s stale-lock reclaim (mirror atomic-state.sh pattern).

### Privacy implications

Security surfaces: (1) HAR-2/HAR-4 encryption — key file at ~/.claude-flow/.encryption-key MUST be 0600 perms; key generated via crypto.randomBytes(32); never logged/committed. (2) sprint-audit-resolve.sh records operator rationale to state.audit_findings_deferred[].rationale + .audit_findings_accepted[].acceptance_rationale — these land in git history; PII redactor MUST run on these inputs per existing C5 ship-gate pattern. (3) audit-resolution-fired sub-step records audit.json path as evidence — path-only per C5 (no content); existing record_sub_step already path-only-safe. (4) scope-bounded gate exposes which files this sprint touched in audit log — no new exposure (spec.md ## Files touched is already committed).

### Rollback strategy

Rollback: per-wave commits. If Wave 1 scope-bound breaks operator workflow, revert worker-gates.sh + phase-workers.json scope field (3 commits to revert). If Wave 2 phase fails to validate, revert phase-manifest.json + remove new scripts (4 commits). If Wave 3 HAR fix breaks existing tests, revert per-AC commit (each HAR is isolated). Wave 4 polish (G1/G2/G3) revert individually.

### Open questions

- Out of scope: (a) harness-continuous-verification-v1 (mid-build verify pulses — requires ruflo light-worker variants, not shipping). (b) Strict mode (worker*rigor=strict) end-to-end smoke — v0.7.2 polish, separate appetite. (c) wizard re-run smoke — v0.7.2 polish. (d) Legacy SPRINT*\*\_BYPASS removal — v0.8.0 (this sprint deprecates harder via new bypass paths but does not remove legacy shims). (e) Mid-build worker pulses (audit-light/testgaps-light between waves).

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

- ✓ lifeos-scope-bounded-verify-workers (§auto, score 0.79) — applied to auto-backfill at assemble
- ✓ lifeos-audit-driven-fix-days-gap (§auto, score 0.78) — applied to auto-backfill at assemble
- ✓ lifeos-audit-finding-triage-honest-bypass (§auto, score 0.75) — applied to auto-backfill at assemble
- ✓ lifeos-sprint-harness-extraction (§auto, score 0.73) — applied to auto-backfill at assemble
- ✓ lifeos-per-wave-proof-file-pattern (§auto, score 0.7) — applied to auto-backfill at assemble
- ✓ lifeos-declarative-phase-workers (§auto, score 0.68) — applied to auto-backfill at assemble
- ✓ lifeos-state-lock-pattern (§auto, score 0.62) — applied to auto-backfill at assemble
- ✓ lifeos-hook-reasserter-defense (§auto, score 0.61) — applied to auto-backfill at assemble
- ✓ lifeos-causal-post-commit-jscpd-leak (§auto, score 0.61) — applied to auto-backfill at assemble
- ✓ task-mp9ti53n→outcome-task-mp9ti53n (§auto, score 0.6) — applied to auto-backfill at assemble

---

## Amendments

_(diff-tracked here as the sprint progresses)_
