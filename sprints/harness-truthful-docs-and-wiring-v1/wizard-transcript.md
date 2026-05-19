# Wizard Transcript: harness-truthful-docs-and-wiring-v1

Started: 2026-05-19T15:22:01Z

This file logs every question and answer during the adaptive spec wizard. Preserved for retro and DAA reviewer feedback.

---

### Wizard mode set to: autopilot · 2026-05-19T15:22:37.663Z

### §A · A1 · 2026-05-19T15:23:04.589Z [autopilot]

Three audits of the harness surfaced: (1) USAGE/QUICKSTART/DEVELOPER docs contradict each other on bypass syntax (QUICKSTART teaches deprecated SPRINT_DRIFT_BYPASS=1), worker output paths, the spec-lock 4-way review producer (Claude vs Task agents), and never define hive-mind consensus voting model; (2) state.json corrupts under concurrent pre-commit drift-check + post-commit reuse-audit because the two callers use different lockfile paths (.husky/post-commit:32 uses docs/sprints/<slug>/state.json.lock; atomic-state.sh:71 uses ~/.cache/lifeos/locks/state-<slug>.lock) — no mutual exclusion, inline jq corrupts the file with orphan } and bypass entries land in reuse_audits[] instead of gate_bypasses[]; (3) the 43 deferred_gates[] in phase-manifest.json are genuinely uninstrumented (14 wizard + 4 spec-lock + 21 verify + 5 deploy — call-sites do not invoke record_sub_step); (4) the closure sprint reached done without firing any daemon workers because direct sprint-advance-phase.sh invocations bypassed the orchestration scripts that would have triggered them — worker-output/ has 1 file (consolidate.json, 123B) vs the harness-parallel-safety-v2 baseline of 6 files / 47KB / 22 invocations.

### §A · A2 · 2026-05-19T15:23:04.620Z [autopilot]

Single persona: future LLMs (Claude Code sessions, agents, sub-agents) reading the sprint-harness docs and trying to execute a sprint correctly. Secondary: human operators (gio) trying to debug why a sprint produced sparse worker outputs or a corrupted state.json. The audit explicitly framed it: docs are not LLM-readable because the same concept is described 3 different ways across the 3 files.

### §A · A3 · 2026-05-19T15:23:04.647Z [autopilot]

Trigger: closure sprint (harness-deterministic-phases-v1-closure) just reached done state, but post-implementation audit revealed (a) it never fired its daemon workers — only consolidate.json (123B) produced vs harness-parallel-safety-v2 baseline of 6 worker files / 47KB; (b) every commit during the closure session corrupted state.json via the lockfile race; (c) the manifest claims 43 of 68 gates deferred — they are NOT working, the user thought they were. We cannot ship v0.7.0 to the world with these gaps. Now-vs-later: the docs+wiring layer must land BEFORE the next feature sprint or the next sprint will reproduce the same corner-cutting.

### §A · A4 · 2026-05-19T15:23:04.679Z [autopilot]

Strategic, not tactical. The 10-min/day promise depends on the sprint harness being trustworthy — operators must believe the gates that pass are real gates. This sprint converts the harness from theatre (passes because nobody made it earn its passes) to production-grade enforcement. Without this, all subsequent feature work compounds on a foundation that lies about what it has verified.

### §A · A5 · 2026-05-19T15:23:04.708Z [autopilot]

Two weeks from now: (1) An LLM can read QUICKSTART.md in 5 minutes and correctly drive a sprint without cross-referencing other docs to disambiguate. (2) phase-manifest.json deferred_gates[] is empty — all 68 gates instrumented end-to-end. (3) state.json never corrupts under concurrent commit hooks — proven by 20-writer stress test passing. (4) sprint-advance-phase.sh is the sole entry point and fires the right workers automatically based on the phase being entered. (5) A dogfood sprint of THIS sprint produces worker-output/ matching the harness-parallel-safety-v2 baseline footprint (≥6 worker files).

### §A · flags · 2026-05-19T15:23:04.737Z [autopilot]

{"backend_only":true,"frontend_only":false,"pure_refactor":false,"no_schema_change":true,"no_ui":true,"strategic":true}

### §A COMPLETE · 2026-05-19T15:23:04.766Z

### §B SKIPPED · harness infrastructure sprint: no new business logic; only wiring/docs/race-fix

### §C SKIPPED · no_schema_change:true per §A flags; only state.json existing field gate_bypasses[] touched

### §D SKIPPED · no HTTP API surface added/changed; sprint touches scripts/.claude/helpers/docs only

### §E SKIPPED · no_ui:true per §A flags

### §F SKIPPED · no_ui:true per §A flags

### §G SKIPPED · no_ui:true per §A flags

### §H · H1 · 2026-05-19T15:23:39.196Z [autopilot]

Modules touched: (1) .husky/post-commit + scripts/lib/atomic-state.sh — race fix (W1). (2) scripts/sprint-advance-phase.sh + new scripts/lib/phase-workers.json + scripts/lib/worker-trigger.sh — worker wiring (W2). (3) docs/sprints/{USAGE,QUICKSTART,DEVELOPER}.md + \_guides/{bypass-cheatsheet,sub-step-coverage}.md — docs reorg (W3). (4) scripts/sprint-spec-wizard.mjs + skill SKILL.md (wizard gates); scripts/sprint-amend-spec.sh + Task tool callsites (spec-lock gates); all 19 verify-\*.sh scripts (verify gates); new scripts/sprint-deploy.sh (deploy gates) — gate instrumentation (W4). (5) Dogfood walk-through of this sprint (W5).

### §H · H2 · 2026-05-19T15:23:39.222Z [autopilot]

External dependencies: ruflo daemon (worker invocation), jq (atomic-state writes), Task tool (sub-agent spawning), Node 20+ (scripts), Bash 3.2+ (macOS compat). No new external deps introduced — sprint reorganizes existing surfaces.

### §H · H3 · 2026-05-19T15:23:39.250Z [autopilot]

Event flows: phase-advance now triggers worker fires (was: separate orchestrator scripts). sub-step gates recorded at each call-site (was: declared in manifest, never invoked). State.json writes serialized through atomic-state.sh::atomic_update_state via shared lockfile (was: two callers with two different lockfile paths).

### §H COMPLETE · 2026-05-19T15:23:39.277Z

### §I · AC-1 · 2026-05-19T15:24:08.788Z [autopilot]

{"title":"State.json race fix","description":"`.husky/post-commit` reuse-audit block stops using inline jq + private $STATE_FILE.lock lockfile. Sources scripts/lib/atomic-state.sh, calls atomic_update_state with the .reuse_audits filter. 20-writer concurrent stress test produces zero JSON corruption (every state.json passes jq empty + has no orphan },).","files_touched":[".husky/post-commit","tests/state-race-stress.mjs"],"verification":"node tests/state-race-stress.mjs --writers 20 --iterations 50 # expect 0 corruptions","complex":false}

### §I · AC-2 · 2026-05-19T15:24:08.815Z [autopilot]

{"title":"Wrap workers into sprint-advance-phase","description":"sprint-advance-phase.sh becomes the single canonical entry point for both phase transitions AND worker invocation. New scripts/lib/phase-workers.json declarative map. Orchestration scripts (sprint-start, sprint-wave-start, sprint-verify, sprint-end) become thin delegates. State.worker_runs[] becomes first-class field with phase-manifest predicate.","files_touched":["scripts/sprint-advance-phase.sh","scripts/lib/phase-workers.json","scripts/lib/worker-trigger.sh","scripts/lib/phase-manifest.json","scripts/sprint-verify.sh","scripts/sprint-wave-start.sh","scripts/sprint-end.sh","scripts/sprint-start.sh"],"verification":"Fresh dogfood sprint with only advance-phase calls: ls docs/sprints/<slug>/worker-output/\*.json | wc -l >= 6","complex":true}

### §I · AC-3 · 2026-05-19T15:24:08.843Z [autopilot]

{"title":"Documentation reorg","description":"QUICKSTART <=300 lines + v0.7 callout box + deprecation of SPRINT_DRIFT_BYPASS=1 as primary. USAGE 5-section restructure (14-day flow, phase enforcement, worker architecture two-surface split, bypass cheatsheet folded, troubleshooting folded). DEVELOPER honest deferred-gates section + state.json race recipe + two-worker-surface diagram. Cross-doc invariants: each term defined once, every code path tagged with script:line, single bypass syntax everywhere.","files_touched":["docs/sprints/QUICKSTART.md","docs/sprints/USAGE.md","docs/sprints/DEVELOPER.md","docs/sprints/_guides/bypass-cheatsheet.md","docs/sprints/_guides/sub-step-coverage.md"],"verification":"node scripts/sprint-replay-validator.mjs --quiet # doc_drift=0; manual cross-read confirms LLM can extract 7-checklist from §A5 vision","complex":false}

### §I · AC-4 · 2026-05-19T15:24:08.871Z [autopilot]

{"title":"Wire all 43 deferred gates","description":"14 wizard gates instrumented at sprint-spec-wizard.mjs::recordAnswer. 4 spec-lock gates instrumented at Task sub-agent completion + file-presence guard >=1KB. 21 verify gates instrumented per script (sprint-typecheck/lint/test/api-contract/debug-rls/module-status/perf-profile/aidefence/sonar/knip/cycle-check/audit-deps/bundle-budget/coverage-delta/migration-check/worker-audit/worker-testgaps/worker-optimize + 2 strict-only). 5 deploy gates instrumented in new/extended sprint-deploy.sh (preview-captured/human-gate-approved/pulumi-up/smoke/vercel). phase-manifest deferred_gates[] becomes empty.","files_touched":["scripts/sprint-spec-wizard.mjs","scripts/sprint-wizard-assemble.mjs","scripts/sprint-amend-spec.sh","scripts/sprint-typecheck.sh","scripts/sprint-lint-check.sh","scripts/sprint-test.sh","scripts/sprint-api-contract-check.sh","scripts/sprint-debug-rls.sh","scripts/sprint-module-status.sh","scripts/sprint-perf-check.sh","scripts/sprint-aidefence-scan.sh","scripts/sprint-sonar-parse.sh","scripts/sprint-knip-check.sh","scripts/sprint-cycle-check.sh","scripts/sprint-audit-deps.sh","scripts/sprint-bundle-budget.sh","scripts/sprint-coverage-delta.sh","scripts/sprint-migration-check.sh","scripts/sprint-deploy.sh","scripts/lib/phase-manifest.json"],"verification":"jq \".deferred_gates | length\" scripts/lib/phase-manifest.json # expect 0. node scripts/sprint-replay-validator.mjs --quiet # all 68 gates enforced.","complex":true}

### §I · AC-5 · 2026-05-19T15:24:08.898Z [autopilot]

{"title":"End-to-end dogfood walk","description":"This sprint walks from spec-wizard to done following USAGE.md verbatim — every orchestration script invoked, every worker fires, every expected file produced. Final worker-output/ matches the harness-parallel-safety-v2 baseline footprint (>=6 worker files, no manual bypass for things that should fire on their own).","files_touched":["docs/sprints/harness-truthful-docs-and-wiring-v1/proof/W5-dogfood.md","docs/sprints/harness-truthful-docs-and-wiring-v1/worker-output/"],"verification":"ls docs/sprints/harness-truthful-docs-and-wiring-v1/worker-output/\*.json | wc -l >= 6; jq .phase docs/sprints/harness-truthful-docs-and-wiring-v1/state.json == \"done\"","complex":false}

### §I COMPLETE · 2026-05-19T15:24:08.924Z

### §J · J1 · 2026-05-19T15:24:29.000Z [autopilot]

Top risks: (1) AC-4 wire-all-43-gates is XL (~12-16h); risk of cutting corners on inject-violation-catch-restore proofs again — mitigation: consolidated proof file W4-43-gates-wired.md with smoke per gate-class, not per-gate (sampling Production-grade methodology). (2) AC-2 wrap-workers couples advance-phase to ruflo daemon availability — mitigation: graceful degrade (warn-and-continue when daemon down, recorded as bypass with rationale). (3) Doc reorg AC-3 risks breaking inbound links — mitigation: keep heading slugs stable, only re-arrange under-headings.

### §J · J2 · 2026-05-19T15:24:29.027Z [autopilot]

Security surfaces: (1) atomic-state.sh shared lock path = $HOME/.cache/lifeos/locks/ — already user-private. (2) record_sub_step calls in 19 verify-_ scripts must NOT log sensitive command output as evidence — pipe through sprint-pii-redact.sh first. (3) sprint-deploy.sh deploy-_ gates must not record AWS credentials or Pulumi state contents to state.json — record only artifact paths. (4) wizard gate evidence (answer JSON) may contain user-provided text — already redacted via existing wizard flow.

### §J · J3 · 2026-05-19T15:24:29.052Z [autopilot]

Rollback: per-wave commits, each with proof file. If W2 wrap-workers introduces ruflo-daemon coupling that breaks an operator, revert W2 commit; advance-phase falls back to phase-write-only. If W4 instrumentation breaks an existing sprint, revert per-script instrumentation patches one at a time (per-gate isolation). State.json race fix W1 has no rollback risk — it strictly reduces corruption surface.

### §J · J4 · 2026-05-19T15:24:29.081Z [autopilot]

Out of scope: (a) full kernel-level FS monitoring for state.json writes (regex+lockfile sufficient for in-process attackers). (b) Sprint-harness package republish to npm (separate gio-approval-gated push, post-sprint). (c) New phases beyond the 11 already declared. (d) Replacing ruflo daemon as the worker runtime.

### §J · J5 · 2026-05-19T15:24:29.109Z [autopilot]

lax

### §J COMPLETE · 2026-05-19T15:24:29.135Z
