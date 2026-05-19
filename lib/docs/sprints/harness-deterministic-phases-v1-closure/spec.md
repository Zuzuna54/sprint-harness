# Sprint harness-deterministic-phases-v1-closure: The parent sprint harness-deterministic-phases-v1 shipped 14 ACs with 5 audited

> Assembled from wizard sections by `sprint-wizard-assemble.mjs` on 2026-05-19T14:21:06.962Z.

## Status

- **Phase:** spec-wizard
- **Day:** 0 of 14
- **Started:** 2026-05-19T14:17:49Z
- **Gates passed:** (none)
- **Drift score (latest):** N/A
- **Wizard sections captured:** A,B,D,H,I,J

---

## §A — Problem & Vision

### Problem statement

The parent sprint harness-deterministic-phases-v1 shipped 14 ACs with 5 audited as Broken-with-followup. The Tier 1-4 fix-up pass closed most issues but left 53 leftover items spanning 4 critical ship-blockers, 7 high-priority verification gaps, 9 architect+security follow-ups, 24 cross-repo mirror tasks, and 5 doc cleanups. The parent sprint is stuck in phase=building because never legitimately walked through verifying/pre-deploy/deploying/done. Sprint-harness package at ~/Desktop/sprint-harness is still at v0.6.0 with no v0.7.0 mirror. This sprint exists to close every leftover item, walk the parent through to done legitimately, mirror to sprint-harness with v0.7.0 release artifacts, and prove the harness can dogfood itself end-to-end without corner-cutting.

### Who suffers

- Operator (gio) — has trusted 14/14 Production claim, now needs an honest 100% closure to ship v0.7.0 confidently. Future operators using the harness on real product sprints — currently exposed to 4 critical bugs (AC-4 typo-silently-recorded, AC-5 unverified ppid check, AC-5 regex bypass paths, AC-10 worker_rigor null) + 43 deferred sub-step gates. Future Claude sessions reading orchestrator SKILL.md + USAGE.md — currently see partly-stale prose because Wave E doc cleanup was deferred.

### Why now

Right after operator caught the corner-cutting on review docs + audited 53 leftover items. Context fresh: every gap mapped to a concrete file + action in the approved plan. Delaying = re-paying the discovery cost. The v0.7.0 ship gate is mechanical now (validate-phase-manifest + replay-validator) — closure work has fast feedback loop. Plus parent sprint stuck at phase=building blocks any clean v0.8 work.

### Strategic fit

Strategic: the harness is the foundation under every future sprint. A v0.7.0 with known-broken AC-4 + AC-5 paths means EVERY downstream sprint inherits the gaps. Tactical too: parent sprint must close cleanly before sprint-harness can mirror + tag v0.7.0.

### Success vision

After this sprint: parent sprint at phase=done with closed_at timestamp; replay validator passes for it; sprint-harness at v0.7.0 with CHANGELOG + git tag; all 4 critical ship-blockers fixed; 43 deferred gates documented (not bypassed-with-rationale every sprint); 4 promised doc rewrites complete (DEVELOPER.md, bypass-cheatsheet.md, sprint-orchestrator/SKILL.md done in T3 + this sprint completes the audit pass).

### Refinement

---

## §B — Business Logic & Domain Rules

### Entities

- Entities: Closure-Item (id L1-L53, wave A-F, status pending|done|deferred, file_paths[], verification). Predicate-Engine (extended with new kinds in L7+L12). Hook-Block-Pattern (regex extensions L2+L15). Bypass-Record (extended with PII-redacted why L14, repo-relative evidence L13). Mirror-File (lifeos source path + sprint-harness dest path, brand-strip flag for workflow yamls).

### State transitions

Invariants: (1) every closure item resolves to pending|done|deferred, never undefined. (2) any new hook-block-pattern must have an inject-violation proof file under proof/. (3) sprint-harness package.json version monotonically increases (0.6.0 → 0.7.0 only after Wave D commits). (4) Replay validator passes for parent + closure sprints after L4 + L11. (5) No state.json writes outside atomic_update_state (enforced by AC-5+L2+L15 hook). (6) gate_history monotonic by at timestamp.

### Invariants

- Calculations: closure_progress = items_done / 53. Bypass-density = bypasses_per_closed_sprint = state.gate_bypasses.length / 1. Pre-v0.7 skip predicate = !gate_history.some(h => h.by === sprint-advance-phase.sh) && state.worker_rigor === undefined. Doc-vs-manifest drift = USAGE.md kebab-case gate names \ phase-manifest.json gates.

### Calculations / aggregations

- Edge cases: L1 ppid check returns shell wrapper not advance-phase → fallback to pgrep walk. L4 phase-walk hits unsatisfiable predicate not in plan → bypass-with-rationale + record follow-up. L10 onboarding-flow-v2 unrecoverable JSON corruption → quarantine state.json to .corrupt.json + create empty replacement marked deferred. L17 gate-names file CI gate fails before T4 dual-listing → temp suppress gate; fix in same PR. L25-L43 sync-mirror.sh refuses to overwrite differing dest → manual diff + selective overwrite.

### Edge cases

_(none)_

### Refinement

---

## §C — Data & Schema

> ⊘ §C was SKIPPED — reason: A.flags.no_schema_change=true

---

## §D — API Surface

### Endpoints

New scripts: scripts/lib/gate-names.json (L17 constants source). New CLI flag: sprint-replay-validator.mjs --report-file <path> (L19). Modified API: bypass.sh::check_bypass now pipes WHY through sprint-pii-redact.sh (L14). sub-step.sh::record_sub_step now canonicalizes evidence paths (L13). atomic_update_state filter shape extended with --arg expected_phase for TOCTOU safety (L12).

### Request/response Zod schemas

Hook-pattern extensions: JQ_PHASE_WRITE in sprint-hook.cjs extends to cover jq -f /dev/stdin + python/awk/perl + > redirects (L2). New FORBIDDEN: rm/mv targeting state.json (L15). Each new pattern documented as Sn in security-review.md threat model.

### Auth requirements

_(LifeOS default: requireUser() on every route)_

### Error cases

_(none)_

### External APIs

_(none)_

### Refinement

---

## §E — UI Components & Pages

> ⊘ §E was SKIPPED — reason: A.flags.backend_only or no_ui=true

---

## §F — UX Flow & Interactions

> ⊘ §F was SKIPPED — reason: A.flags.backend_only or no_ui=true

---

## §G — Visual Design & Brand

> ⊘ §G was SKIPPED — reason: A.flags.no_ui=true

---

## §H — Integration Points

### LifeOS modules touched

_(none)_

### External APIs

- Cross-repo: ~/Desktop/sprint-harness/ (24 files mirrored via sync-mirror.sh in Wave D), package.json + CHANGELOG.md + git tag v0.7.0. Push to origin pending user gio approval per org policy.

### Cross-module events

- External integrations: ruflo daemon (memory store for retro patterns), GitHub (PR-body workflow + replay validator CI step), husky hooks (drift+dup+review chain unchanged). No new external APIs.

### Background workers / cron

_(none)_

### Refinement

---

## §I — Acceptance Criteria

### UI/E2E (Gherkin)

```json
{
  "id": "AC-WaveA",
  "title": "Wave A ship-blockers (L1-L4)",
  "complex": true,
  "given_when_then": "GIVEN parent sprint at phase=building with AC-4+AC-5 bugs WHEN Wave A executes THEN L1 hook real-flow proof captured, L2 jq variant regex catches 4 attack patterns, L3 9-script audit complete with any-fixes committed, L4 parent sprint phase-walk reaches done with manifest predicates honest",
  "invest": "INVEST: ship-blockers only; smallest unit is one bug fix; each L-item independently verifiable",
  "dod": "4/4 L-items closed; proof files per L-item committed; parent sprint state.phase = done"
}
```

### Backend (INVEST)

```json
{
  "id": "AC-WaveB",
  "title": "Wave B verification (L5-L11)",
  "complex": false,
  "given_when_then": "GIVEN code paths claimed by parent sprint but never smoke-tested WHEN Wave B executes THEN L5 strict mode proof, L6 --from invariant proof, L7 4 untested predicate kinds covered, L8 retro substeps verified, L9 7 legacy bypass shims confirmed, L10 onboarding-flow-v2 JSON valid, L11 mid-checkin pre-v07 skip confirmed",
  "invest": "INVEST: smoke-tests only, no new behavior",
  "dod": "7/7 L-items closed with proof files; replay validator passes against all sprints"
}
```

### Performance bars

```json
{
  "id": "AC-WaveC",
  "title": "Wave C polish from architect+security reviews (L12-L20)",
  "complex": true,
  "given_when_then": "GIVEN architect + security reviews flagged 9 v0.7.1 polish items WHEN Wave C executes THEN L12 TOCTOU-safe atomic write, L13 evidence path canonical, L14 PII redact in bypass why, L15 rm/mv hook block, L16 gate-name warn at record_sub_step, L17 gate-names.json constants file, L18 schema _comment, L19 replay --report-file, L20 doc-vs-manifest false-positive audit",
  "invest": "INVEST: each addresses a specific security/architect finding (S7/S9/S11/S13/S14/etc)",
  "dod": "9/9 L-items closed; security-review.md updated to note residual risks reduced"
}
```

### Manual QA checklist

- {"id":"AC-WaveD","title":"Wave D sprint-harness mirror + v0.7.0 release artifacts (L25-L48)","complex":true,"given_when_then":"GIVEN sprint-harness at v0.6.0 with no v0.7.0 mirror WHEN Wave D executes THEN 19 files mirrored via sync-mirror.sh, package.json bumped 0.6.0 → 0.7.0, CHANGELOG.md v0.7.0 entry written, git tag v0.7.0 created. Push to origin reserved for user gio approval","invest":"INVEST: each L25-L43 is one file copy with brand-strip if needed","dod":"24/24 L-items closed; sprint-harness git status clean except for v0.7.0 commit + tag waiting for push approval"}

### Refinement

---

## §J — Risks, Security, Rollback

### Security risks

- Security surfaces: L2 + L15 add new hook block patterns. Each requires inject-violation proof. L14 PII redact must not over-redact and corrupt legitimate rationales. L12 TOCTOU race could break advance-phase under high concurrency. L17 gate-names file adds a new sync point; mismatched constants block CI. Net: surfaces added with explicit security mitigations documented in security-review.md.

### Privacy implications

Privacy: SPRINT_BYPASS_WHY committed to git. L14 mitigates with sprint-pii-redact.sh pre-record. No user PII in scope (harness-itself sprint). No new data flows.

### Rollback strategy

Rollback: every change is per-AC commit. Per-AC git revert restores prior behavior. Sprint-harness v0.7.0 tag can be moved if pre-release; once published to npm, follow-up patch. No DB / migration — pure file edits.

### Open questions

- Open questions: L17 gate-names schema $ref vs dual-validation — decide at build time based on JSON Schema tooling. L20 false-positive scope — pause if Wave E reveals more legacy strings than expected, file follow-up. Pre-deploy review for harness-itself sprint — invoke real reviewer + security-architect agents or bypass with rationale (architect+security reviews captured Day ½ already cover it)?

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

- ✓ lifeos-sprint-pipeline-realistic-scheduling-delivered (§auto, score 0.72) — applied to auto-backfill at assemble
- ✓ lifeos-harness-portability-sprints (§auto, score 0.7) — applied to auto-backfill at assemble
- ✓ lifeos-sprint-harness-extraction (§auto, score 0.7) — applied to auto-backfill at assemble
- ✓ lifeos-sprint-branch-2026-05-17 (§auto, score 0.69) — applied to auto-backfill at assemble
- ✓ lifeos-causal-post-commit-jscpd-leak (§auto, score 0.67) — applied to auto-backfill at assemble
- ✓ lifeos-token-burn-investigation-2026-05-19 (§auto, score 0.65) — applied to auto-backfill at assemble
- ✓ lifeos-parallel-sprint-triad (§auto, score 0.63) — applied to auto-backfill at assemble
- ✓ lifeos-procedure-phantom-sweep (§auto, score 0.62) — applied to auto-backfill at assemble
- ✓ sprint-harness-v0.4-shipped (§auto, score 0.6) — applied to auto-backfill at assemble
- ✓ lifeos-inject-violation-surfaces-glob-holes (§auto, score 0.57) — applied to auto-backfill at assemble

---

## Amendments

_(diff-tracked here as the sprint progresses)_
