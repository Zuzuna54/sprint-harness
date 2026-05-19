# Sub-step coverage map

> Catalog of every named sub-step gate declared in `scripts/lib/phase-manifest.json`, and where it is (or will be) recorded.

**Status as of v0.7.0 (harness-deterministic-phases-v1 AC-8 + AC-11 + AC-12 + T4):**

- **25 gates instrumented** with `record_sub_step` calls in shipping scripts.
- **43 gates marked `deferred_gates[]`** in the manifest — predicate engine treats missing-and-no-bypass for these as `[DEFERRED]` (counts separately, doesn't fail predicate check). NO operator bypass needed; gates remain documented in the manifest for the eventual instrumentation in `harness-verify-instrumentation-v1`.
- **Operators on v0.7.0 do NOT need to bypass deferred gates.** Phase advance proceeds when all _enforced_ gates pass (or have explicit bypass). Deferred gates show up as `[DEFERRED]` in the predicate output for transparency.

## Instrumented (15)

| Gate name                                            | Recording script               | When fires                                                                  |
| ---------------------------------------------------- | ------------------------------ | --------------------------------------------------------------------------- |
| `spec-lock-baseline-written`                         | `sprint-amend-spec.sh` --lock  | After drift baseline + files_touched written                                |
| `build-launched`                                     | `sprint-build-launch.sh`       | At swarm launch                                                             |
| `day-5-question-cut`                                 | `sprint-checkin.sh --validate` | When `### Cut` heading has ≥30 chars                                        |
| `day-5-question-push`                                | `sprint-checkin.sh --validate` | When `### Push` heading has ≥30 chars                                       |
| `day-5-question-pivot`                               | `sprint-checkin.sh --validate` | When `### Pivot` heading has ≥30 chars                                      |
| `day-5-hill-chart-refreshed`                         | `sprint-checkin.sh` (template) | On initial generation                                                       |
| `cleanup-deadcode-delete`                            | `sprint-cleanup-launch.sh`     | After deadcode pass                                                         |
| `cleanup-lint-fix`                                   | `sprint-cleanup-launch.sh`     | After lint --fix pass                                                       |
| `cleanup-claude-md-clean`                            | `sprint-cleanup-launch.sh`     | After CLAUDE.md auto-clean                                                  |
| `design-sparc-spec-pseudocode`                       | `sprint-design-lock.sh`        | At design-lock                                                              |
| `design-sparc-architect`                             | `sprint-design-lock.sh`        | At design-lock                                                              |
| `design-locked`                                      | `sprint-design-lock.sh`        | At design-lock                                                              |
| `pre-deploy-reviewer-agent`                          | `sprint-predeploy-gate.sh`     | When --reviewer file present                                                |
| `pre-deploy-security-architect`                      | `sprint-predeploy-gate.sh`     | When --security file present                                                |
| `retro-{worked,didnt,surprised,claude-md,followups}` | `sprint-end.sh`                | When the corresponding `## <heading>` has ≥50 chars (or ≥10 for short ones) |
| `retro-pattern-{1,2,3}`                              | `sprint-end.sh`                | When 3+ `### Pattern N: <name>` subheadings present                         |
| `daa-feedback-batched`                               | `sprint-end.sh`                | Always (assumed; flip to conditional if DAA disabled)                       |
| `trajectory-closed`                                  | `sprint-end.sh`                | Always                                                                      |
| `velocity-computed`                                  | `sprint-end.sh`                | Always (after metrics.json write)                                           |

## Pending (53) — deferred to follow-up `harness-verify-instrumentation-v1`

### Wizard (14 gates)

`wizard-section-A` through `wizard-section-J`, `wizard-coherence-after-C`, `wizard-coherence-after-F`, `wizard-coherence-after-I`, `wizard-assemble`. Recording belongs in `scripts/sprint-spec-wizard.mjs` at each section's `answer` command + at coherence-check + at assemble.

### Spec-lock 4-way review (4 gates)

`spec-lock-solution-sketches`, `spec-lock-architect-review`, `spec-lock-security-review`, `spec-lock-hive-mind-consensus`. Recording belongs in the workflow that spawns those agents (`docs/workflows/lifeos-sprint-build.yaml` Phase 1 chain), or in a new `sprint-spec-lock-review.sh` that wraps the 4 agent calls.

### Verify chain (18 gates)

`verify-typecheck`, `verify-lint`, `verify-tests`, `verify-api-contract`, `verify-debug-rls`, `verify-module-status`, `verify-perf-profile`, `verify-aidefence-scan`, `verify-sonar`, `verify-knip`, `verify-cycle-check`, `verify-audit-deps`, `verify-bundle-budget`, `verify-coverage-delta`, `verify-migration-check`, `verify-worker-audit`, `verify-worker-testgaps`, `verify-worker-optimize`. Recording belongs in `scripts/sprint-verify.sh` at each step's success. Strict-only: `verify-worker-map-refreshed`, `verify-worker-consolidate-refreshed`.

### Deploy (5 gates)

`deploy-pulumi-preview-captured`, `deploy-human-gate-approved`, `deploy-pulumi-up`, `deploy-smoke`, `deploy-vercel`. Recording belongs in `docs/workflows/lifeos-deploy.yaml` at each workflow step, OR a new `sprint-deploy.sh` wrapper that calls the workflow.

### Misc (12 gates)

Mostly subsumed by the above categories. See `phase-manifest.json` for the canonical list.

## How to add a new sub-step gate

1. Add the gate name to the relevant phase's `required_sub_step_gates[]` in `scripts/lib/phase-manifest.json`. Run `node scripts/lib/validate-phase-manifest.mjs` to confirm structure.
2. Source `scripts/lib/sub-step.sh` in the script that produces the artifact. Call `record_sub_step "$SLUG" "<gate-name>" pass [evidence-path]` at the moment the artifact is produced.
3. Run a smoke against the dogfood sprint: trigger the script, confirm `state.gates_passed[]` contains the new gate.
4. Update this file's "Instrumented" table.

## How to bypass a gate (operator escape hatch)

If a gate is impossible to satisfy in the current run:

```bash
SPRINT_BYPASS_GATE=verify-sonar \
SPRINT_BYPASS_WHY='Sonar container unavailable; rerun scheduled within 24h' \
  bash scripts/sprint-advance-phase.sh <next-phase>
```

Logged to `state.gate_bypasses[]` with caller attribution. See `bypass-cheatsheet.md`.
