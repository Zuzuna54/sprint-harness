# Retro — harness-truthful-docs-and-wiring-v1

**Slug:** harness-truthful-docs-and-wiring-v1
**Closed:** 2026-05-19
**Duration:** single autonomous session (~6h elapsed; nominal 14-day walked end-to-end via compressed timeline).
**Scope:** 5 ACs closing the audit findings from `harness-deterministic-phases-v1-closure` sprint's audit.

## What worked

Per-wave commits with REAL proof files held up against context fatigue. W1 (race fix) shipped with a 20-writer stress test; W2 (workers) shipped with live-fire evidence of `predict` firing on day-5-checkin entry; W3 (docs) shipped with grep-verifiable terminology anchors + doc_drift=0; W4 (43 gates) shipped with `deferred_gates[] = []` mechanically verified; W5 (dogfood) just walked the canonical phase chain with REAL worker fires (audit + testgaps + optimize all produced output files matching the harness-parallel-safety-v2 baseline footprint).

The architect's "PASS WITH CONDITIONS" framework worked — every C1-C7 condition became a mechanically-verifiable check, not a hand-wave. The closure-sprint corner-cutting pattern did NOT recur because each wave had concrete proof artifacts before advancing.

The phase-workers.json declarative manifest decoupled "what workers fire on phase entry" from "what scripts orchestrate the sprint." This is the right architecture for v0.8+ — phase entry IS the canonical fire point.

## What didn't

The replay validator broke on older sprints when `deferred_gates[]` went empty — historical sprints (parent + closure) had gates listed as `[DEFERRED]` that are now required. Filed as v0.7.2 follow-up: `phase_manifest_version_seen` field per sprint for backward-compat. NOT a blocker for this sprint's close, but visible regression for ops who run replay.

The W2 wrap-workers edit was reverted twice mid-session by auto-commit hooks intercepting scripts/ changes — landed only on third application. Filed as v0.7.2: post-commit hook should respect Edit-tool atomicity and not race against in-progress agent writes.

`sprint-status.sh` resolves to the wrong sprint sometimes (session-file points at onboarding-flow-v2). Repeated friction every time I had to override with `SPRINT_SLUG_OVERRIDE`. Filed as v0.7.2: session-file should respect active-sprint precedence over recently-touched.

The audit found 10 vulnerabilities (riskScore=72) — exactly the load-bearing gap we documented this session. All 10 are pre-existing in `.claude/helpers/*.js` (not touched by this sprint). The honest bypass + filing as `harness-audit-resolution-v1` works as a triage pattern, but ONLY because we documented the audit-resolution gap inline. Future operators reading the docs will know to triage; without the documentation update, they'd be in the closure-sprint failure mode.

## What surprised us

The audit produced EXACTLY 10 findings — the same order of magnitude as `audit-driven-fidelity-v1/worker-output/audit.json` (9 findings, riskScore=72). The pattern is reproducible: any sprint that runs verify against the LifeOS infrastructure finds ~10 pre-existing security issues. This justifies the `harness-audit-resolution-v1` follow-up sprint's full appetite — there's a real backlog of legacy security debt that needs the 4-day-fix-window pattern to land properly.

The W2 phase-workers wiring fired correctly the FIRST time it ran end-to-end — `predict` on day-5-checkin, `map` on building re-entry, `audit/testgaps/optimize` on verifying. No spurious failures, no graceful-degrade fallbacks. That validates the C2 + C4 ship-gate decisions made at spec-lock without modification.

The closure-sprint corner-cutting pattern almost recurred during W2 — the file-revert race nearly resulted in scripts/sprint-advance-phase.sh shipping without the worker-fire block. The per-wave proof-file commit pattern caught it: writing W2-wrap-workers.md required reading the file to confirm the edit landed, which surfaced the missing W2 markers + triggered re-application.

## Patterns extracted

### Pattern 1: `lifeos-shared-lockfile-via-source`

**Symptom:** Two callers writing to the same state.json use DIFFERENT lockfile paths because each implements its own atomic-update inline. Corruption emerges under contention.
**Fix:** Centralize the atomic-state primitive in ONE library (`scripts/lib/atomic-state.sh`). Every caller `source` it and delegates to `atomic_update_state <slug> <jq-filter>`. Removes the entire class of "two implementations drift" bugs.
**Where applied:** W1 race fix — `.husky/post-commit` now sources atomic-state.sh; both pair-mode write + reuse-audit write use the same `$LOCK_DIR/state-<slug>.lock`.
**Generalizes to:** any concurrent-mutator pattern where different files do the same operation. One library, one lockfile, one contract.

### Pattern 2: `lifeos-declarative-phase-workers`

**Symptom:** Operators forget to call orchestration scripts (sprint-verify, sprint-wave-start, sprint-end) — workers never fire. The harness LOOKS like it ran (state.json shows phase=done) but worker-output/ is empty.
**Fix:** Wire workers INTO the canonical phase mutator (`sprint-advance-phase.sh`) via a declarative `phase-workers.json` manifest. The advance-phase reads `{phase → workers-to-fire-on-entry}` and triggers each worker before atomic phase write. State.worker_runs[] records every invocation with status + phase tag.
**Where applied:** W2 — `phase-workers.json` declares `building→map`, `day-5-checkin→predict`, `verifying→audit+testgaps+optimize`, `done→document+consolidate`. Workers fire via the phase transition that's ALREADY mandatory.
**Generalizes to:** any "operator forgot to call X" failure mode where X has a natural trigger. Move X to the trigger.

### Pattern 3: `lifeos-audit-finding-triage-honest-bypass`

**Symptom:** Audit produces real findings late in sprint. Operators bypass to ship. Findings get silently lost in `gate_bypasses[]` with vague rationales.
**Fix:** Mandatory `audit-resolutions.md` triage document per sprint that runs audit. Each finding becomes either: (a) FIXED in-sprint with code change, (b) DEFERRED with a specific follow-up sprint slug + AC ID, (c) ACCEPTED with explicit rationale + risk owner. Bypass rationale must reference the resolution doc.
**Where applied:** W5 dogfood — audit found 10 vulns; `audit-resolutions.md` triaged each to `harness-audit-resolution-v1` HAR-1..10 ACs; verify-worker-audit bypass rationale references the doc explicitly.
**Generalizes to:** all blocking-verify scenarios. Bypass becomes accountable: every bypass either fixes the thing or names where the thing gets fixed.

## CLAUDE.md updates proposed

- Root `CLAUDE.md`: phase-workers.json + worker fire from advance-phase already documented in DEVELOPER.md. No update needed at root.
- `docs/sprints/USAGE.md`: already updated in W3.
- New section needed in `DEVELOPER.md`: link from "## Audit-driven fix days" to the live example `harness-truthful-docs-and-wiring-v1/audit-resolutions.md` as the canonical triage template. Filed as v0.7.2 polish (1-line addition).

## Open follow-ups

- **`harness-audit-resolution-v1`** (MUST land before v0.8.0): build audit-resolution-phase infrastructure + fix HAR-1..10. ~12 ACs single appetite.
- **`harness-continuous-verification-v1`** (v0.8+): mid-build verify pulses (audit-light, testgaps-light between waves). Out of scope for v0.7.x because ruflo daemon doesn't ship light worker variants.
- **`harness-scope-bounded-workers-v1`** (DEFERRED — must land before v0.8): verify-phase workers (audit, testgaps, optimize) currently run against the ENTIRE repository, producing 10+ pre-existing findings on every sprint regardless of what the sprint touched. They should be scope-bounded to the spec's `## Files touched` list — exactly mirroring how `gate_testgaps_blocks` already scope-bounds (sprint-harness AC-3 pattern). Concrete scope: (a) `worker-trigger.sh::trigger_worker` accepts `--scope=files-touched` flag, (b) `phase-workers.json` declares per-worker default scope, (c) audit prompt template includes "ONLY review files in $FILES_TOUCHED" constraint, (d) `gate_audit_blocks` rechecks findings against scope before recording fail. Without this, the audit-resolution sprint (HAR-1..10) repeatedly surfaces the same pre-existing findings on every future sprint — operator fatigue + signal-to-noise problem.
- **v0.7.2 polish**:
  - Replay validator backward-compat (`phase_manifest_version_seen` per sprint).
  - sprint-status.sh active-sprint resolution priority.
  - post-commit hook atomicity vs concurrent Edit-tool writes.
  - Strict mode (worker_rigor=strict) end-to-end smoke.
  - Wizard re-run smoke (verify new sprint with fresh wizard fires all 14 wizard gates automatically without backfill).
  - Link from DEVELOPER.md "Audit-driven fix days" section to this sprint's audit-resolutions.md as canonical template.
- **v0.8.0 (legacy bypass removal)**: rewrite USAGE.md legacy `SPRINT_*_BYPASS` examples + remove legacy shim code. Requires harness-audit-resolution-v1 landed first.
- **Push to origin (gio approval)**: 244+ commits ahead on `sprint/pipeline-v2-visibility`. Awaiting explicit confirmation per org policy.

<!-- auto-appended by sprint-end.sh document worker -->

### document worker proposals (2026-05-19T17:20:19Z)

````json
{
  "timestamp": "2026-05-19T17:20:17.519Z",
  "mode": "headless",
  "workerType": "document",
  "model": "haiku",
  "durationMs": 98924,
  "executionId": "document_1779211118595_sk0rpp",
  "success": true,
  "findings": {
    "sections": [
      {
        "title": "Documentation Generation Plan (Text Summary)",
        "content": "\n",
        "level": 2
      },
      {
        "title": "Phase 1: High-Leverage Utility Functions (@lifeos/utils)",
        "content": "\n**dates.ts** → JSDoc for getWeekStart(), formatDate(), and any re-exports from date-fns\n- Add: Usage examples showing timezone handling, week boundary behavior\n- Inline: Comment any non-obvious logic around DST or month boundaries\n\n**macros.ts** → Document TDEE calculation, macro cycling, P/C/F split logic\n- Add: JSDoc with examples showing input ranges, why cycling matters for bulking/cutting\n- Inline: Explain why certain divisors are used, edge cases for minimal calorie days\n\n**cost.ts** → Document budget calculations, projection logic, category rollups\n- Add: Parameter descriptions, return type specs, example inputs/outputs\n- Inline: Why certain costs are attributed to weeks vs. months\n\n**scheduling.ts** → Document block placement, conflict detection, timezone conversions\n- Add: Examples of typical schedules, edge cases (daylight saving, cross-timezone)\n- Inline: Logic for muscle group spacing (48-hour buffer), why certain patterns fail\n\n**Other utilities** (logger.ts, errors.ts, performance.ts, readiness.ts, nutritionFeedback.ts, rrule.ts): Follow same pattern—JSDoc + examples + non-obvious logic comments\n\n---\n\n",
        "level": 3
      },
      {
        "title": "Phase 2: Lambda API Route Documentation",
        "content": "\n**Each Lambda module** (ai-scheduler, workouts, nutrition, planner, grocery, health, supplements, auth, finances):\n- List all routes (method + path) in module README\n- Add JSDoc to each route handler function explaining: what it does, who calls it (web/mobile/cron), what it validates (Zod schema), what errors it throws\n- Document input/output shape with examples\n\n**Example route documentation**:\n```\nPOST /v1/workouts → createWorkout(event)\nValidates: WorkoutCreateSchema (Zod)\nReturns: { success: true, data: Workout }\nThrows: 400 (validation), 401 (auth), 409 (spacing conflict)\n```\n\n---\n\n",
        "level": 3
      },
      {
        "title": "Phase 3: Complex Logic Documentation",
        "content": "\n**Pipeline V2 (runPipeline.ts)**: Document 7-stage execution (foundation → week_shape → workouts/meals/supplements → aggregate → verify), parallel fanout, error recovery\n- Inline: Why stages run sequentially, what happens on timeout, how results propagate\n\n**Rate Limiting**: Document daily caps per scope (full: 5, partial: 4, sickDay: 10)\n- Inline: Why certain triggers increment counters, how reset works\n\n**Muscle Spacing**: Document 48-hour buffer logic, why it matters (CNS recovery)\n- Inline: Edge cases (week boundaries, timezone midnight), why specific muscle groups can coexist\n\n**Macro Cycling**: Document bulk/cut/recomp phases, weekly adjustments\n- Inline: Why certain formulas prevent metabolic adaptation\n\n---\n\n",
        "level": 3
      },
      {
        "title": "Phase 4: Module READMEs",
        "content": "\nCreate for each package and Lambda module:\n- **Purpose**: One sentence explaining what it does\n- **Key Exports**: List of exported functions/types\n- **Usage Examples**: Typical call patterns\n- **Integration Points**: How it connects to other modules\n- **Error Handling**: Common error codes and what to do\n\n---\n\n",
        "level": 3
      },
      {
        "title": "Execution Order (by impact):",
        "content": "1. @lifeos/utils/macros.ts, cost.ts, scheduling.ts (used by 20+ routes)\n2. ai-scheduler Lambda routes (core scheduling trigger)\n3. Pipeline V2 orchestration (system brain)\n4. Remaining utilities (dates, logger, errors)\n5. Other Lambda modules (workouts, nutrition, planner, etc.)\n\nThis approach prioritizes functions with highest call-site density—improving their documentation multiplies impact across the codebase.\n</summary>",
        "level": 3
      }
    ],
    "codeBlocks": [
      {
        "language": "text",
        "code": "POST /v1/workouts → createWorkout(event)\nValidates: WorkoutCreateSchema (Zod)\nReturns: { success: true, data: Workout }\nThrows: 400 (validation), 401 (auth), 409 (spacing conflict)"
      }
    ]
  },
  "rawOutputPreview": "<analysis>\nThe LifeOS codebase requires systematic documentation across three layers: (1) Lambda API handlers (10 modules with ~120 routes), (2) Utility packages in @lifeos/utils (dates, macros, scheduling, cost, logging, errors), and (3) Complex orchestration logic (Pipeline V2, rate limiting, muscle spacing, grocery aggregation).\n\nFrom the examined context:\n\n**Handler Pattern** (from .claude/rules/lambda.md): All Lambda handlers follow a standard structure with router-based dispatch. The ai-scheduler-lambda/handler.ts exemplifies this—it's already well-documented with dual entry points (EventBridge cron + API Gateway). The pattern is: OPTIONS preflight → route matching → handler invocation → error handling with structured logging.\n\n**Key Undocumented Areas**:\n- pipelineRoutes.ts: The main API surface for Pipeline V2 (POST /generate-pipeline, GET /pipelines/:id, POST /stages/:stage/retry) lacks inline documentation despite being the critical flow orchestrator.\n- @lifeos/utils modules: dates.ts, cost.ts, scheduling.ts, macros.ts have minimal JSDoc. These are heavily used across 10 Lambda modules and web components—they're high-leverage targets.\n- Complex logic: Pipeline V2 runPipeline.ts (7-stage sequential + parallel fanout), rate limiting (daily caps per scope), muscle group spacing (48-hour buffer logic), macro calculations (TDEE, cycling, P/C/F splits), grocery aggregation (deduplication + quantity rollup), cost projections.\n\n**Documentation Leverage**: Focusing on @lifeos/utils first yields maximum impact—each exported function serves 3-5 Lambda routes + 10+ web components. Pipeline orchestration comes second because it's the system's heartbeat.\n\n**Constraints from existing patterns**:\n- JSDoc format: @param {type} name, @returns {type}, @throws {type} error\n- Comments explain WHY not WHAT (per CLAUDE.md preferences)\n- Inline comments only for non-obvious logic (hidden constraints, workarounds, subtle invariants)\n- Examples show typed usage, not pseudo-code\n- E",
  "rawOutputLength": 5562
}```
````
