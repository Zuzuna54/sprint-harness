# Sprint harness-truthful-docs-and-wiring-v1: Three audits of the harness surfaced: (1) USAGE/QUICKSTART/DEVELOPER docs contra

> Assembled from wizard sections by `sprint-wizard-assemble.mjs` on 2026-05-19T15:24:34.529Z.

## Status

- **Phase:** spec-wizard
- **Day:** 0 of 14
- **Started:** 2026-05-19T15:22:01Z
- **Gates passed:** (none)
- **Drift score (latest):** N/A
- **Wizard sections captured:** A,H,I,J

---

## §A — Problem & Vision

### Problem statement

Three audits of the harness surfaced: (1) USAGE/QUICKSTART/DEVELOPER docs contradict each other on bypass syntax (QUICKSTART teaches deprecated SPRINT_DRIFT_BYPASS=1), worker output paths, the spec-lock 4-way review producer (Claude vs Task agents), and never define hive-mind consensus voting model; (2) state.json corrupts under concurrent pre-commit drift-check + post-commit reuse-audit because the two callers use different lockfile paths (.husky/post-commit:32 uses docs/sprints/<slug>/state.json.lock; atomic-state.sh:71 uses ~/.cache/lifeos/locks/state-<slug>.lock) — no mutual exclusion, inline jq corrupts the file with orphan } and bypass entries land in reuse_audits[] instead of gate_bypasses[]; (3) the 43 deferred_gates[] in phase-manifest.json are genuinely uninstrumented (14 wizard + 4 spec-lock + 21 verify + 5 deploy — call-sites do not invoke record_sub_step); (4) the closure sprint reached done without firing any daemon workers because direct sprint-advance-phase.sh invocations bypassed the orchestration scripts that would have triggered them — worker-output/ has 1 file (consolidate.json, 123B) vs the harness-parallel-safety-v2 baseline of 6 files / 47KB / 22 invocations.

### Who suffers

- Single persona: future LLMs (Claude Code sessions, agents, sub-agents) reading the sprint-harness docs and trying to execute a sprint correctly. Secondary: human operators (gio) trying to debug why a sprint produced sparse worker outputs or a corrupted state.json. The audit explicitly framed it: docs are not LLM-readable because the same concept is described 3 different ways across the 3 files.

### Why now

Trigger: closure sprint (harness-deterministic-phases-v1-closure) just reached done state, but post-implementation audit revealed (a) it never fired its daemon workers — only consolidate.json (123B) produced vs harness-parallel-safety-v2 baseline of 6 worker files / 47KB; (b) every commit during the closure session corrupted state.json via the lockfile race; (c) the manifest claims 43 of 68 gates deferred — they are NOT working, the user thought they were. We cannot ship v0.7.0 to the world with these gaps. Now-vs-later: the docs+wiring layer must land BEFORE the next feature sprint or the next sprint will reproduce the same corner-cutting.

### Strategic fit

Strategic, not tactical. The 10-min/day promise depends on the sprint harness being trustworthy — operators must believe the gates that pass are real gates. This sprint converts the harness from theatre (passes because nobody made it earn its passes) to production-grade enforcement. Without this, all subsequent feature work compounds on a foundation that lies about what it has verified.

### Success vision

Two weeks from now: (1) An LLM can read QUICKSTART.md in 5 minutes and correctly drive a sprint without cross-referencing other docs to disambiguate. (2) phase-manifest.json deferred_gates[] is empty — all 68 gates instrumented end-to-end. (3) state.json never corrupts under concurrent commit hooks — proven by 20-writer stress test passing. (4) sprint-advance-phase.sh is the sole entry point and fires the right workers automatically based on the phase being entered. (5) A dogfood sprint of THIS sprint produces worker-output/ matching the harness-parallel-safety-v2 baseline footprint (≥6 worker files).

### Refinement

---

## §B — Business Logic & Domain Rules

> ⊘ §B was SKIPPED — reason: harness infrastructure sprint: no new business logic; only wiring/docs/race-fix

---

## §C — Data & Schema

> ⊘ §C was SKIPPED — reason: no_schema_change:true per §A flags; only state.json existing field gate_bypasses[] touched

---

## §D — API Surface

> ⊘ §D was SKIPPED — reason: no HTTP API surface added/changed; sprint touches scripts/.claude/helpers/docs only

---

## §E — UI Components & Pages

> ⊘ §E was SKIPPED — reason: no_ui:true per §A flags

---

## §F — UX Flow & Interactions

> ⊘ §F was SKIPPED — reason: no_ui:true per §A flags

---

## §G — Visual Design & Brand

> ⊘ §G was SKIPPED — reason: no_ui:true per §A flags

---

## §H — Integration Points

### LifeOS modules touched

- Modules touched: (1) .husky/post-commit + scripts/lib/atomic-state.sh — race fix (W1). (2) scripts/sprint-advance-phase.sh + new scripts/lib/phase-workers.json + scripts/lib/worker-trigger.sh — worker wiring (W2). (3) docs/sprints/{USAGE,QUICKSTART,DEVELOPER}.md + \_guides/{bypass-cheatsheet,sub-step-coverage}.md — docs reorg (W3). (4) scripts/sprint-spec-wizard.mjs + skill SKILL.md (wizard gates); scripts/sprint-amend-spec.sh + Task tool callsites (spec-lock gates); all 19 verify-\*.sh scripts (verify gates); new scripts/sprint-deploy.sh (deploy gates) — gate instrumentation (W4). (5) Dogfood walk-through of this sprint (W5).

### External APIs

- External dependencies: ruflo daemon (worker invocation), jq (atomic-state writes), Task tool (sub-agent spawning), Node 20+ (scripts), Bash 3.2+ (macOS compat). No new external deps introduced — sprint reorganizes existing surfaces.

### Cross-module events

- Event flows: phase-advance now triggers worker fires (was: separate orchestrator scripts). sub-step gates recorded at each call-site (was: declared in manifest, never invoked). State.json writes serialized through atomic-state.sh::atomic_update_state via shared lockfile (was: two callers with two different lockfile paths).

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

- Top risks: (1) AC-4 wire-all-43-gates is XL (~12-16h); risk of cutting corners on inject-violation-catch-restore proofs again — mitigation: consolidated proof file W4-43-gates-wired.md with smoke per gate-class, not per-gate (sampling Production-grade methodology). (2) AC-2 wrap-workers couples advance-phase to ruflo daemon availability — mitigation: graceful degrade (warn-and-continue when daemon down, recorded as bypass with rationale). (3) Doc reorg AC-3 risks breaking inbound links — mitigation: keep heading slugs stable, only re-arrange under-headings.

### Privacy implications

Security surfaces: (1) atomic-state.sh shared lock path = $HOME/.cache/lifeos/locks/ — already user-private. (2) record_sub_step calls in 19 verify-_ scripts must NOT log sensitive command output as evidence — pipe through sprint-pii-redact.sh first. (3) sprint-deploy.sh deploy-_ gates must not record AWS credentials or Pulumi state contents to state.json — record only artifact paths. (4) wizard gate evidence (answer JSON) may contain user-provided text — already redacted via existing wizard flow.

### Rollback strategy

Rollback: per-wave commits, each with proof file. If W2 wrap-workers introduces ruflo-daemon coupling that breaks an operator, revert W2 commit; advance-phase falls back to phase-write-only. If W4 instrumentation breaks an existing sprint, revert per-script instrumentation patches one at a time (per-gate isolation). State.json race fix W1 has no rollback risk — it strictly reduces corruption surface.

### Open questions

- Out of scope: (a) full kernel-level FS monitoring for state.json writes (regex+lockfile sufficient for in-process attackers). (b) Sprint-harness package republish to npm (separate gio-approval-gated push, post-sprint). (c) New phases beyond the 11 already declared. (d) Replacing ruflo daemon as the worker runtime.

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

- ✓ lifeos-sprint-harness-extraction (§auto, score 0.79) — applied to auto-backfill at assemble
- ✓ lifeos-causal-post-commit-jscpd-leak (§auto, score 0.74) — applied to auto-backfill at assemble
- ✓ lifeos-diagnose-subscription-quota-burn (§auto, score 0.72) — applied to auto-backfill at assemble
- ✓ lifeos-procedure-phantom-sweep (§auto, score 0.72) — applied to auto-backfill at assemble
- ✓ lifeos-state-lock-pattern (§auto, score 0.71) — applied to auto-backfill at assemble
- ✓ lifeos-hive-mind-consensus-noop (§auto, score 0.71) — applied to auto-backfill at assemble
- ✓ lifeos-token-burn-investigation-2026-05-19 (§auto, score 0.71) — applied to auto-backfill at assemble
- ✓ lifeos-parallel-sprint-triad (§auto, score 0.68) — applied to auto-backfill at assemble
- ✓ lifeos-causal-launchd-desktop-fda-block (§auto, score 0.64) — applied to auto-backfill at assemble
- ✓ lifeos-atomic-state-args-trap (§auto, score 0.63) — applied to auto-backfill at assemble

---

## Amendments

_(diff-tracked here as the sprint progresses)_
