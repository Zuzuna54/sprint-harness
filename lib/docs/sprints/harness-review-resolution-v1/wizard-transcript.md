# Wizard Transcript: harness-review-resolution-v1

Started: 2026-05-19T19:06:30Z

This file logs every question and answer during the adaptive spec wizard. Preserved for retro and DAA reviewer feedback.

---

### Wizard mode set to: autopilot · 2026-05-19T19:07:55.225Z

### §A · A1 · 2026-05-19T19:08:12.052Z [autopilot]

Current state: audit-resolution phase (v0.7.2) triages ONLY daemon-worker audit findings. Knip (verify-knip) and Sonar (verify-sonar) produce structured findings too but are recorded as advisory-only — no triage workflow, no Fix/Defer/Accept, no follow-up tracking. Generalize the audit-resolution infrastructure to handle all 3 finding-producers under a unified review-resolution phase before knip/sonar accumulate into legacy debt.

### §A · A2 · 2026-05-19T19:08:12.080Z [autopilot]

Persona: future operators (Claude + gio) running sprints. They get audit + knip + sonar findings during verifying. Without unified triage, operators ignore knip/sonar advisory until they grow into thousands like the .claude/helpers/\*.js audit findings did. Goal: prevent the same accumulation in dead-code + code-quality lanes.

### §A · A3 · 2026-05-19T19:08:12.107Z [autopilot]

Trigger: harness-audit-resolution-and-scope-v1 closed 2026-05-19. Operator (gio) asked: where do knip + sonar fit? The audit-resolution flow works great for audit findings — we need the same discipline for knip + sonar BEFORE we accrue debt. Generalize NOW while the audit-resolution patterns are fresh + the 8 ship-conditions are proven.

### §A · A4 · 2026-05-19T19:08:12.135Z [autopilot]

Strategic. The 10-min/day promise depends on actionable signal across ALL finding lanes, not just security. Knip dead-code drags down navigation; sonar quality drags down readability. Without unified triage, operators desensitize.

### §A · A5 · 2026-05-19T19:08:12.163Z [autopilot]

Two weeks from now: (1) review-resolution phase supersedes audit-resolution (back-compat alias). (2) state.review_findings[] with producer-tagged entries. (3) sprint-review-resolve.sh handles 3 producers uniformly. (4) Exit predicate: resolved + deferred + accepted == total across all producers. (5) Knip + sonar become producing (not advisory). (6) Docs updated. (7) Dogfood walk through this very phase.

### §A · flags · 2026-05-19T19:08:12.193Z [autopilot]

{"backend_only":true,"frontend_only":false,"pure_refactor":false,"no_schema_change":true,"no_ui":true,"strategic":true}

### §A COMPLETE · 2026-05-19T19:08:12.220Z

### §B SKIPPED · harness-infra: generalize audit-resolution to review-resolution; no new domain logic

### §C SKIPPED · no_schema_change: state.review_findings additive via atomic_update_state

### §D SKIPPED · no HTTP API surface

### §E SKIPPED · no_ui per A flags

### §F SKIPPED · no_ui per A flags

### §G SKIPPED · no_ui per A flags

### §H · H1 · 2026-05-19T19:08:33.781Z [autopilot]

Modules touched: scripts/lib/phase-manifest.json (add review-resolution phase as alias/superset to audit-resolution); scripts/lib/phase-predicates.sh (new predicate kind review_resolution_complete OR extend audit_resolution_complete); NEW scripts/sprint-review-resolve.sh + sprint-review-rerun.sh; back-compat alias for audit-resolve/rerun scripts. scripts/sprint-deadcode-delete.mjs adds --json producer mode. scripts/sprint-sonar-parse.mjs adds --json producer mode. scripts/sprint-verify.sh records knip+sonar producers into state.review_findings[]. NEW docs/sprints/\_templates/review-resolutions.md. 4 docs (USAGE/QUICKSTART/DEVELOPER/SCRIPTS).

### §H · H2 · 2026-05-19T19:08:33.809Z [autopilot]

External deps: zero new. Reuses existing knip (already a dep via sprint-deadcode-delete.mjs), sonar (already integrated via sprint-sonar-parse.mjs), node built-in jq processing, ruflo daemon audit worker.

### §H · H3 · 2026-05-19T19:08:33.837Z [autopilot]

Event flow: verifying entry → 3 producers fire (audit worker existing + knip new producer mode + sonar new producer mode) → each writes producer-tagged findings to state.review_findings[] → advance to review-resolution → sprint-review-resolve.sh walks aggregated list across all producers → operator Fix/Defer/Accept regardless of producer → exit predicate validates resolved+deferred+accepted=total across union.

### §H COMPLETE · 2026-05-19T19:08:33.866Z

### §I · AC-1 · 2026-05-19T19:09:20.237Z [autopilot]

{"title":"Generalize: audit-resolution → review-resolution","description":"Add review-resolution to manifest as superset. audit-resolution stays as legacy alias. New review_findings[{producer, har_id, severity, file, line, description, status}] aggregating audit + knip + sonar. Existing audit_findings views aliased.","files_touched":["scripts/lib/phase-manifest.json","scripts/lib/phase-predicates.sh"],"verification":"validate-phase-manifest passes; back-compat with prior sprints.","complex":true}

### §I · AC-2 · 2026-05-19T19:09:37.719Z [autopilot]

{"title":"sprint-review-resolve.sh + audit-resolve alias","description":"NEW multi-producer interactive walker. Reads review_findings. --status breakdown per producer. --finding HAR-N action across producers.","files_touched":["scripts/sprint-review-resolve.sh"],"verification":"--status against fixture sprint shows audit + knip + sonar counts.","complex":true}

### §I · AC-3 · 2026-05-19T19:09:37.747Z [autopilot]

{"title":"sprint-review-rerun.sh — re-fire all producers","description":"Generalize sprint-audit-rerun.sh. Re-fires audit + knip + sonar env-stripped. Per-producer baseline diff. FIXED/REGRESSION/UNCHANGED per producer. Twice-consecutive regression threshold preserved.","files_touched":["scripts/sprint-review-rerun.sh"],"verification":"Smoke after no-op + synthetic regression in knip producer.","complex":true}

### §I · AC-4 · 2026-05-19T19:09:37.777Z [autopilot]

{"title":"Knip --json producer mode","description":"sprint-deadcode-delete.mjs --check --json emits structured findings. sprint-verify.sh appends to review_findings[]. Output also lands at worker-output/knip.json.","files_touched":["scripts/sprint-deadcode-delete.mjs","scripts/sprint-verify.sh"],"verification":"--check --json schema-valid output; verify records into review_findings.","complex":true}

### §I · AC-5 · 2026-05-19T19:09:37.806Z [autopilot]

{"title":"Sonar --json producer mode","description":"sprint-sonar-parse.mjs --json emits structured findings. Severity map blocker/critical=high, major=medium, minor=low. Vacuous PASS when no recent scan.","files_touched":["scripts/sprint-sonar-parse.mjs","scripts/sprint-verify.sh"],"verification":"--json against cached fixture schema-valid; empty fixture vacuous PASS.","complex":true}

### §I · AC-6 · 2026-05-19T19:09:37.834Z [autopilot]

{"title":"\_templates/review-resolutions.md","description":"Generalize template. Per-producer section. Per-finding HAR-N with producer tag.","files_touched":["docs/sprints/_templates/review-resolutions.md"],"verification":"Template seeded on review-resolution phase entry.","complex":false}

### §I · AC-7 · 2026-05-19T19:09:37.864Z [autopilot]

{"title":"Docs + dogfood","description":"USAGE/QUICKSTART/DEVELOPER/SCRIPTS updated for v0.7.3. Producer-pipeline diagram. Dogfood: walk this sprint through review-resolution.","files_touched":["docs/sprints/USAGE.md","docs/sprints/QUICKSTART.md","docs/sprints/DEVELOPER.md","docs/sprints/SCRIPTS.md"],"verification":"doc_drift=0; final jq phase=done.","complex":false}

### §I COMPLETE · 2026-05-19T19:09:37.893Z

### §J · J1 · 2026-05-19T19:09:49.709Z [autopilot]

Risks: (1) Backward-compat for prior audit_findings views — alias via jq filter. (2) Knip false-positives (dynamic imports, codegen). Mitigation: knip.json exclusions respected. (3) Sonar may not have recent scan — vacuous PASS. (4) Phase rename — keep both audit-resolution and review-resolution valid; predicate works on either.

### §J · J2 · 2026-05-19T19:09:49.739Z [autopilot]

Security: knip/sonar findings only contain file paths (no PII). Triage rationales still PII-redacted via existing C5 path. Producer outputs land in worker-output/ committed audit trail.

### §J · J3 · 2026-05-19T19:09:49.769Z [autopilot]

Rollback: per-AC commits. AC-1 manifest revert is single-file. AC-4/AC-5 producer changes revert per script. AC-7 doc edits regenerable.

### §J · J4 · 2026-05-19T19:09:49.799Z [autopilot]

Out of scope: ESLint findings producer (already blocking via verify-lint). TypeScript producer (blocking via verify-typecheck). Task-sub-agent gates (api-contract / debug-rls / module-status / aidefence) — separate appetite if needed.

### §J · J5 · 2026-05-19T19:09:49.828Z [autopilot]

lax

### §J COMPLETE · 2026-05-19T19:09:49.856Z
