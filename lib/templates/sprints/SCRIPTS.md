# Sprint Harness — Script Reference

> Canonical inventory of every script that participates in the LifeOS sprint
> harness. Generated 2026-05-19 from header docstrings.
>
> See [`USAGE.md`](./USAGE.md) for **how** to call these in a sprint flow.
> See [`DEVELOPER.md`](./DEVELOPER.md) for **how** to extend them.
> See [`QUICKSTART.md`](./QUICKSTART.md) for the 5-minute on-ramp.

This file answers one question: "what does each script do, and when does it fire?"
It does NOT explain the protocol — that lives in USAGE.md.

---

## Table of contents

1. [Phase mutation & state (the core)](#phase-mutation--state-the-core)
2. [Sprint lifecycle](#sprint-lifecycle)
3. [Wizard](#wizard)
4. [Build orchestration](#build-orchestration)
5. [Verify chain](#verify-chain)
6. [Cleanup chain](#cleanup-chain)
7. [Drift control](#drift-control)
8. [Workers (daemon worker pipeline)](#workers-daemon-worker-pipeline)
9. [Phase manifest & predicates](#phase-manifest--predicates)
10. [Reporting & dashboards](#reporting--dashboards)
11. [Memory & learning](#memory--learning)
12. [Husky hooks](#husky-hooks)
13. [Claude Code hooks](#claude-code-hooks)
14. [Security & PII](#security--pii)
15. [Self-tests & meta](#self-tests--meta)
16. [Multi-model orchestrator](#multi-model-orchestrator)
17. [Non-sprint utilities](#non-sprint-utilities)
18. [Out of scope (V3 / swarm-comms infrastructure)](#out-of-scope-v3--swarm-comms-infrastructure)

---

## Phase mutation & state (the core)

The single sanctioned writers of `state.json` and `state.phase`. Every other
sprint script delegates here. Tampering with this layer breaks the replay
validator and the entire protocol.

| Script                            | Purpose                                                                                                                                                                           | When it fires                                                                                    |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `scripts/sprint-advance-phase.sh` | THE canonical phase mutator. Reads phase-manifest predicates, fires phase-workers per `phase-workers.json`, atomic-writes `state.phase`. Only sanctioned writer of `state.phase`. | Every phase transition. Called by spec-lock/design-lock/build-launch/checkin/cleanup/verify/end. |
| `scripts/lib/atomic-state.sh`     | `atomic_update_state <slug> [jq-flags] <filter>` — flock + same-FS mktemp + atomic rename + validate + .bak. Eliminates cross-FS mv, SIGKILL, and concurrent-writer torn writes.  | Sourced by every state-mutating script (16+ callers).                                            |
| `scripts/lib/state-lock.sh`       | `with_state_lock <state-file> <fn>` — set-C noclobber lockfile, 5 retries, 30s stale reclaim. Legacy primitive; new code uses atomic-state.                                       | Pre-W1 callers; superseded by atomic-state.sh.                                                   |
| `scripts/lib/lock-dir.sh`         | Resolves `$LOCK_DIR` to `$XDG_RUNTIME_DIR/lifeos` (Linux) or `$HOME/.cache/lifeos/locks` (macOS), 0700 perms. AC-6 security fix vs `/tmp/$(id -u)-*`.                             | Sourced before any flock acquisition.                                                            |
| `scripts/lib/session-file.sh`     | `write_session_file / read_session_file / clear_session_file` — `~/.claude/sessions/<id>/sprint-slug` for parallel-sprint slug resolution. Graceful no-op outside Claude Code.    | Sourced by sprint-start (write), sprint-status (read), sprint-end (clear).                       |
| `scripts/lib/sub-step.sh`         | `record_sub_step <slug> <gate> <verdict> [evidence]` — idempotent dual-write to `gates_passed[]` (canonical) + `gates[]` (legacy). Verdict ∈ `{pass, fail, bypassed}`.            | Every gate completion across the harness.                                                        |
| `scripts/lib/bypass.sh`           | `check_bypass <gate>` (canonical `SPRINT_BYPASS_GATE` + `SPRINT_BYPASS_WHY ≥10 chars`) and `deprecate_legacy_bypass <env> <gate>` (auto-translate legacy `SPRINT_*_BYPASS=1`).    | Every gate that accepts a bypass.                                                                |
| `scripts/lib/timeout.sh`          | Portable timeout wrapper. Tries `gtimeout` → `timeout` → perl-alarm fallback. Returns 124 on timeout.                                                                             | Anywhere a hard cap is needed (workers, gates).                                                  |

---

## Sprint lifecycle

Operator-facing entry points for the 14-day flow.

| Script                                  | Purpose                                                                                                                                                                          | When it fires                                                                         |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `scripts/sprint-start.sh`               | Phase 0 entry. Creates `docs/sprints/<slug>/`, initializes `state.json`, writes session file. Default stays on current branch; `--with-branch` creates `sprint/<slug>`.          | `bash scripts/sprint-start.sh <slug>` (Day 0).                                        |
| `scripts/sprint-status.sh`              | Print current sprint state. Resolution: `--slug` → `$SPRINT_SLUG_OVERRIDE` → git branch `sprint/<slug>` → most-recent non-done. `--slug-only` / `--list` / `--json` modes.       | Any time. Used by every script that needs to know the active slug.                    |
| `scripts/sprint-end.sh`                 | Phase 8 closeout. Generates retro, extracts patterns to memory, syncs CLAUDE.md, closes Issue, sets `state.phase = done`. `--store-patterns` auto-saves retro patterns to ruflo. | `bash scripts/sprint-end.sh <slug>` (Day 14).                                         |
| `scripts/sprint-pause.sh`               | Pause active sprint. Disables drift-prone workers (refactor, document), snapshots state, records pause event for retro.                                                          | Operator command "pause the sprint".                                                  |
| `scripts/sprint-resume.sh`              | Restore phase from `state.prev_phase`, re-enable paused daemon workers, record resume event.                                                                                     | Operator command "resume the sprint".                                                 |
| `scripts/sprint-precheck.sh`            | Verify harness dependencies (daemon, memory.db, MCP, launchd cron, graphify, husky) are healthy. Writes `systems-health.json`. AC-33.                                            | Called by sprint-start (BLOCK if critical down) and sprint-end (WARN + log to retro). |
| `scripts/sprint-preflight-git-clean.sh` | Block sprint start/build if `apps/`, `packages/`, `scripts/`, `.husky/`, `.github/`, `tsconfig*`, `package.json`, `pnpm-lock.yaml` have unstaged modifications. Sprint docs OK.  | Called by sprint-start.sh and sprint-build-launch.sh.                                 |
| `scripts/sprint-amend-spec.sh`          | Amend the active sprint's spec.md. Modes: edit, `--lock`, `--cut <ACs>`, `--add-file <path>`, `--pivot`. Triggers rebaseline unless `--no-rebaseline`.                           | Spec-lock; mid-sprint amendments.                                                     |
| `scripts/sprint-rebaseline.sh`          | Re-embed `spec.md` to update the drift baseline. Archives old as `.baseline-embedding.day<N>.json`.                                                                              | After approved spec amendment.                                                        |

---

## Wizard

Adaptive spec wizard — 10 sections (A–J) with coherence checks and assembly.

| Script                                  | Purpose                                                                                                                                                                                                                                                                                                                                            | When it fires                                                                                      |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `scripts/sprint-spec-wizard.mjs`        | State manager for the adaptive spec wizard. Commands: `status`, `section <id>`, `answer`, `next`. Maintains `spec.partial.json`, persists transcript, delegates assembly.                                                                                                                                                                          | Driven by `sprint-spec-wizard` skill during Day 0 wizard.                                          |
| `scripts/sprint-wizard-assemble.mjs`    | Render final `spec.md` from `spec.partial.json` using `docs/sprints/_template/spec.md`. `--partial` shows current state; `--dry-run` prints without writing.                                                                                                                                                                                       | After all 10 sections complete; also for "show me the spec so far".                                |
| `scripts/sprint-wizard-context.mjs`     | Generate context bundle (prior answers, memory recall prompts, grep heuristics) for the next wizard question. JSON to stdout.                                                                                                                                                                                                                      | Before every section's first question.                                                             |
| `scripts/sprint-wizard-coherence.mjs`   | Coherence check across accumulated answers. Detects contradictions / unstated implications. Records outcome to `spec.partial.json`.                                                                                                                                                                                                                | After §C, §F, §I.                                                                                  |
| `scripts/sprint-wizard-grep-runner.mjs` | Actually executes the grep heuristics from `sprint-wizard-context.mjs` (gap #14 fix). Returns top-N matches as JSON. Uses ripgrep, falls back to `grep -r`.                                                                                                                                                                                        | During each section, after context bundle emitted.                                                 |
| `scripts/sprint-hive-mind-spec-lock.sh` | Two-queen hive-mind consensus on `spec.md` SHA. Strategic queen (scope coherence) + tactical queen (AC concreteness). Records to `state.consensus[]`. `SPRINT_HIVE_MIND_BYPASS=1` skips.                                                                                                                                                           | Spec-lock checkpoint (Day ½).                                                                      |
| `scripts/sprint-design-lock.sh`         | Phase transition `spec-locked → design-locked`. Asserts spec.md §A–J + design.md with 3 SPARC sections. Appends `design-lock` to `gates[]`. Commits state.                                                                                                                                                                                         | After SPARC design sign-off (Day 2).                                                               |
| `scripts/sprint-spec-lock-record.sh`    | Records the 4 spec-lock sub-step gates after Task sub-agents complete: `spec-lock-solution-sketches`, `spec-lock-architect-review`, `spec-lock-security-review`, `spec-lock-hive-mind-consensus`. Enforces a ≥1KB file-size threshold per artifact (closure-sprint placeholder prevention from `harness-truthful-docs-and-wiring-v1`). Idempotent. | Day ½, after the orchestrator spawns the 4 review artifacts; before `sprint-amend-spec.sh --lock`. |

---

## Build orchestration

Day 3–11 build phase entry points.

| Script                           | Purpose                                                                                                                            | When it fires                                                     |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `scripts/sprint-build-launch.sh` | Phase 3 kickoff. Transitions `design-locked → building`, triggers `lifeos-sprint-build` workflow (8-agent swarm + 3 side-cars).    | `bash scripts/sprint-build-launch.sh` (Day 3).                    |
| `scripts/sprint-wave-start.sh`   | Fire `predict` daemon worker at each build wave kickoff. Advisory; never blocks. Output → `worker-output/predict.json`.            | Inside `lifeos-sprint-build.yaml` per wave; manual `<wave-name>`. |
| `scripts/sprint-checkin.sh`      | Day-5 mid-cycle Shape Up hill chart update. Writes `check-in-day5.md`, sets `gates_passed += mid-checkin`.                         | `bash scripts/sprint-checkin.sh` (Day 5).                         |
| `scripts/run-workflow.sh`        | Minimal YAML workflow runner. Decomposes `steps:` arrays that upstream ruflo `workflow run` can't (issue #1916). `${slug}` interp. | Workflow execution where ruflo's built-in runner fails.           |

---

## Verify chain

Day 11–12 gate sequence: typecheck → lint → tests → audit/testgaps/optimize workers.

| Script                              | Purpose                                                                                                                                                                                                                                                                          | When it fires                                             |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| `scripts/sprint-verify.sh`          | Verify chain orchestrator. typecheck → lint → tests → api-contract → debug-rls → module-status → audit (BLOCK) + testgaps (BLOCK) + optimize (advisory). Records `state.verify_gates`.                                                                                           | `bash scripts/sprint-verify.sh` (Days 11–12).             |
| `scripts/sprint-lint-check.sh`      | Workspace ESLint gate. Bypasses broken `pnpm turbo run lint` (only apps/web has the script + interactive `next lint`). Invokes local ESLint with inline rules.                                                                                                                   | Verify chain step 2.                                      |
| `scripts/sprint-audit-deps.sh`      | `pnpm audit --json` vs sprint-start baseline. Fails on new high/critical CVEs in the sprint branch. `--baseline` writes new baseline.                                                                                                                                            | Verify chain; pre-deploy.                                 |
| `scripts/sprint-cycle-check.sh`     | Detect cyclic import dependencies via `madge` (pnpm dlx). Gates on NEW cycles only — existing ones are baselined. `--baseline` updates.                                                                                                                                          | Verify chain.                                             |
| `scripts/sprint-bundle-budget.mjs`  | Check Lambda bundle sizes against budget (default 5MB; spec §J override). Reads `apps/lambdas/*/dist/` + `.turbo/build-output`. Exit 0/1/2.                                                                                                                                      | Verify chain after `bundle-lambdas.sh`.                   |
| `scripts/sprint-perf-check.mjs`     | Compare measured perf against spec §I "Performance bars". Default: P95 <800ms, payload <50KB, ≤2 DB queries/request. Spec/AC overrides honored.                                                                                                                                  | Verify chain.                                             |
| `scripts/sprint-migration-check.sh` | Drizzle-kit dry-run schema diff. If diff exists, asserts a matching migration file is present in the sprint branch.                                                                                                                                                              | Verify chain.                                             |
| `scripts/sprint-coverage-delta.mjs` | Compare coverage between sprint branch and `main` (or explicit baseline). Fails if line coverage drops > 5% on any file OR new code coverage < 60%.                                                                                                                              | Verify chain.                                             |
| `scripts/sprint-sonar-parse.mjs`    | Fetch SonarQube issues per sprint-affected project, compare to baseline. Fails on NEW blocker/critical issues only. `--baseline` at spec-lock.                                                                                                                                   | Verify chain when Sonar configured.                       |
| `scripts/sprint-smoke-validate.sh`  | End-to-end smoke validation of sprint-system-100 capabilities. Asserts every new script exists, runs read-only/dry-run, cross-script integration works. AC-16.                                                                                                                   | Pre-closeout sanity check.                                |
| `scripts/sprint-verify-agents.sh`   | Operator-driven recorder for the 4 Task-agent verify gates (`verify-api-contract`, `verify-debug-rls`, `verify-module-status`, `verify-aidefence-scan`). `--strict` also records the 2 strict-tier gates (`verify-worker-map-refreshed`, `verify-worker-consolidate-refreshed`). | Days 11–12, after Task sub-agents complete their reviews. |

---

## Audit-resolution chain _(v0.7.2+)_

Day 12–13 phase between `verifying` and `pre-deploy`. Fires when audit produced findings; vacuous PASS when `audit_findings_total == 0`. See [`USAGE.md` §1](./USAGE.md#1--the-14-day-flow) and [`DEVELOPER.md` §"Audit-driven fix days"](./DEVELOPER.md#audit-driven-fix-days).

| Script                                         | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | When it fires                                                                                                               |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `scripts/sprint-audit-resolve.sh`              | _Legacy v0.7.2 audit-only walker_ — superseded by `sprint-review-resolve.sh` (v0.7.3+). Interactive walker for `state.audit_findings_*`. Modes: `--status` (print triage state, exit), `--finding HAR-N {fix\|defer\|accept}` (programmatic single-finding mutation with required args: `--to-sprint`+`--ac-id` for defer, `--owner`+`--rationale` for accept), default = interactive loop. Atomic per-decision persistence (C2); PII-redacts rationale via `sprint-pii-redact.sh` (C5).                                                                                                                                             | Phase entry to `audit-resolution`; operator command "walk audit findings".                                                  |
| `scripts/sprint-audit-rerun.sh`                | _Legacy v0.7.2 audit-only re-firer_ — superseded by `sprint-review-rerun.sh` (v0.7.3+). Re-fires the audit worker with env-stripped invocation (`env -i HOME PATH SHELL`, per C6 — operator AWS keys, PROD URLs, secrets cannot leak). Diffs new audit output against pre-fix baseline classified into FIXED / REGRESSION / UNCHANGED. Tracks `state.audit_rerun_regression_streak`: first regression returns 0 (warn), twice-consecutive returns 1 (block).                                                                                                                                                                         | After each Fix decision in `sprint-audit-resolve.sh`; manual `bash scripts/sprint-audit-rerun.sh`.                          |
| `scripts/sprint-review-resolve.sh` _(v0.7.3+)_ | **Unified multi-producer review-finding walker.** Reads `worker-output/{audit,knip,sonar}.json` on first invocation and aggregates entries into `state.review_findings[]` with global HAR-N namespace + producer-tagged entries. Modes: `--status` (per-producer breakdown), `--finding HAR-N {fix\|defer\|accept}` (programmatic; defer requires `--to-sprint`+`--ac-id`+`--rationale`, accept requires `--risk-owner`+`--rationale`), default = vacuous PASS short-circuit when no findings exist. C5: rationale piped through `sprint-pii-redact.sh`. C7: defer `--to-sprint` validated against `^[a-z0-9-]{3,64}$`.              | Phase entry to `review-resolution`; operator command "walk review findings".                                                |
| `scripts/sprint-review-rerun.sh` _(v0.7.3+)_   | **Multi-producer rerun + per-producer baseline diff.** For each producer (audit/knip/sonar): snapshots `worker-output/<producer>-baseline.json` on first run, then re-fires + diffs current vs baseline classified into FIXED / REGRESSION / UNCHANGED. Tracks per-producer streak in `state.review_rerun_regression_streak.<producer>` — twice-consecutive regression on any producer blocks (mirrors v0.7.2 audit single-counter). Audit fires via `trigger_worker audit` (env-stripped per C6); knip via `sprint-deadcode-delete.mjs --check --json`; sonar via `sprint-sonar-parse.mjs --json` (vacuous PASS when token absent). | After each Fix in `sprint-review-resolve.sh`; manual `bash scripts/sprint-review-rerun.sh [--producer audit\|knip\|sonar]`. |

---

## Cleanup chain

Day 11–12 cleanup + dead-code removal + CLAUDE.md sync.

| Script                                 | Purpose                                                                                                                                                             | When it fires                                          |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `scripts/sprint-cleanup-launch.sh`     | Trigger the cleanup workflow (`docs/workflows/lifeos-sprint-cleanup.yaml`). AC-24. `--commit-deadcode` enables auto-commit of `sprint-deadcode-delete.mjs` results. | After verify, before deploy (Day 11–12).               |
| `scripts/sprint-deadcode-delete.mjs`   | `knip --reporter json` → confirm dead → `git rm` + commit → run tests → `git revert` on fail. Refuses to delete files in current sprint's `files_touched[]`. AC-18. | Cleanup chain; default `--dry-run`, `--commit` to act. |
| `scripts/sprint-claude-md-check.sh`    | Scan CLAUDE.md for stale file paths, function names, slash commands. `--all` scans root + apps/web + apps/lambdas/\*.                                               | Cleanup chain; ad-hoc audits.                          |
| `scripts/sprint-claude-md-upgrade.mjs` | Propose CLAUDE.md additions from retro patterns. Output: `claude-md-proposed-diff.patch` (unified diff). AC-8.                                                      | Day 14 after retro.                                    |
| `scripts/sprint-test-hardening.mjs`    | Emit missing-tests report for routes in `files_touched`. Statuses: OK / MISSING_TEST / LOW_COVERAGE (<60%). Writes `test-hardening.csv` + `.json`. AC-19.           | Day 9.                                                 |
| `scripts/sprint-reuse-audit.sh`        | jscpd duplication check per file changed vs main. Surfaces >50% structural overlap candidates. Falls back to grep heuristics if jscpd missing.                      | Per commit (via post-commit hook); manual post-AC.     |

---

## Deploy chain

Day 13 deploy orchestration. Records artifact paths only (never contents) per condition C6. See [`USAGE.md` §1](./USAGE.md#day-13--deploy--deploying).

| Script                             | Purpose                                                                                                                                                                                                                                                                                                                                 | When it fires                                                                                    |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `scripts/sprint-deploy.sh`         | Day 13 deploy orchestrator. Walks the 5 deploy sub-step gates in order: `deploy-pulumi-preview-captured` → `deploy-human-gate-approved` → `deploy-pulumi-up` → `deploy-smoke` → `deploy-vercel`. Pauses for typed `proceed` at the human gate. C6: records artifact paths only in `state.json`, never Pulumi stack contents or secrets. | `bash scripts/sprint-deploy.sh` (Day 13); equivalent to `ruflo workflow execute lifeos-deploy`.  |
| `scripts/sprint-predeploy-gate.sh` | Pre-deploy human gate checkpoint. Asserts reviewer + security-architect Task sub-agents have written their reviews (`pre-deploy-review.md`, `security-review.md` updated post-verify) and advances phase `pre-deploy → deploying` on operator sign-off.                                                                                 | Day 13, after `sprint-audit-resolve.sh` completes (or vacuous PASS) and pre-deploy review lands. |

---

## Drift control

Per-commit drift detection + amendment loop.

| Script                           | Purpose                                                                                                                                          | When it fires                                         |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------- |
| `scripts/sprint-drift-check.sh`  | Husky pre-commit hook. Embed commit signal (message + diff summary), cosine vs baseline. ≥0.75 proceeds; <0.75 pauses with 3-option prompt.      | Every commit when active sprint exists with baseline. |
| `scripts/sprint-drift-score.mjs` | Cosine similarity between baseline embedding (384-d) and commit signal text. Tries `ruflo embeddings encode`; falls back to bag-of-words cosine. | Called by `sprint-drift-check.sh`.                    |

---

## Workers (daemon worker pipeline)

On-demand ruflo daemon worker integration. See [USAGE.md §3](./USAGE.md#3--worker-architecture) for the three-concept model.

| Script                           | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | When it fires                                                  |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `scripts/lib/worker-trigger.sh`  | `trigger_worker <name> <slug> [timeout]` and `trigger_workers_parallel`. Ensures daemon, calls `ruflo daemon trigger -w <worker>`, polls `.claude-flow/metrics/<w>.json` mtime, validates JSON, copies to `worker-output/<w>.json`, records `worker_invocations[]`. CI hard-fails if `claude` lacks OAuth. Accepts `<slug>` for scope-bound gate downstream consumption.                                                                                                | Invoked by `sprint-advance-phase.sh` per `phase-workers.json`. |
| `scripts/lib/worker-gates.sh`    | `gate_audit_blocks <output.json> <slug>` (Q2 zero-tolerance within scope; v0.7.2+ partitions findings into in-scope blocking vs out-of-scope advisory using `state.files_touched[]` — see [USAGE.md §3 Worker scope](./USAGE.md#worker-scope-v072)). `gate_testgaps_blocks <output> <slug>` (the canonical scope-bounded gate pattern; audit gate retrofitted to mirror this). `gate_optimize_scope_filter` + `gate_optimize_advisory <output> <slug>` — advisory-only. | Sourced by `sprint-verify.sh`.                                 |
| `scripts/sprint-workers-shim.sh` | Substitutes for ruflo's 5 missing daemon workers. Hourly via launchd/cron. Runs `sprint-memory-decay.mjs` (replaces ultralearn), `pnpm graphify:rebuild` (replaces deepdive). refactor / benchmark / replay-validate intentionally skipped during sprint (drift risk).                                                                                                                                                                                                  | launchd `com.lifeos.sprint-workers-shim.plist` hourly.         |
| `scripts/sync-mirror.sh`         | Sync `~/Desktop/sprint-harness/` to mirror lifeos AC commits (AC-13). Rebases/ff-merges harness to match lifeos, creates missing mirror commits for any `feat(...AC-N):` lacking a port.                                                                                                                                                                                                                                                                                | When `sprint-mirror-check.sh` reports desync.                  |
| `scripts/sprint-mirror-check.sh` | Pre-push mirror-parity check. Fails push if lifeos AC commits lack matching mirror commits in `~/Desktop/sprint-harness/` (within 24h). AC-13.                                                                                                                                                                                                                                                                                                                          | `.husky/pre-push`.                                             |

---

## Phase manifest & predicates

Declarative phase requirements + the engine that enforces them.

| File / script                             | Purpose                                                                                                                                                                                                                        | When it fires                                                                     |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| `scripts/lib/phase-manifest.json`         | Declarative source of truth: 11 phases × `advances_to[]` + `required_artifacts[]` + `required_state_fields[]` + `required_sub_step_gates[]`. 68 sub-step gates total.                                                          | Read by every phase transition.                                                   |
| `scripts/lib/phase-manifest.schema.json`  | JSON schema for the manifest. Used by `validate-phase-manifest.mjs`.                                                                                                                                                           | Manifest validation.                                                              |
| `scripts/lib/phase-workers.json`          | Per-phase daemon-worker map. Two tiers: `always[]` and `strict_only[]` (gated by `state.worker_rigor`). Each entry: `{worker, required, timeout_s, expects[]}`.                                                                | Read by `sprint-advance-phase.sh` after each successful phase write.              |
| `scripts/lib/gate-names.json`             | Allowed gate-name registry. Drift detector for doc-vs-manifest parity (replay validator AC-13 sub-clause d).                                                                                                                   | Replay validator; manifest validation.                                            |
| `scripts/lib/validate-phase-manifest.mjs` | Structural validator for `phase-manifest.json`. Exits 0 if valid, 1 with `[FAIL]` lines on stderr. Covers exactly the predicate kinds we ship — no ajv dep needed.                                                             | `sprint-advance-phase.sh` startup; `sprint-system-test.sh --replay-gate-history`. |
| `scripts/lib/phase-predicates.sh`         | `check_phase_requirements <slug> <phase>` predicate engine. Kinds: `file_exists`, `file_min_bytes`, `file_contains_heading`, `json_path_present`/`_equals`/`_in`, `state_field_min_length`, `state_field_all_values_in`, more. | Called by `sprint-advance-phase.sh` per transition.                               |

---

## Reporting & dashboards

Operator-facing visibility into sprint state.

| Script                                 | Purpose                                                                                                                                                                      | When it fires                                                   |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `scripts/sprint-dashboard.mjs`         | Generate local HTML dashboard with hill chart SVG, AC checklist, drift timeline, phase progression bar, files-touched diff, recent standup. `<meta refresh="60">`. `--open`. | Manual; on phase transitions.                                   |
| `scripts/sprint-hillchart.mjs`         | Refresh/print the Shape Up hill chart (uphill/top/downhill/at-bottom dots per AC). `--refresh` writes `hill-chart.md`.                                                       | Day 5 check-in; sprint-end.                                     |
| `scripts/sprint-standup.mjs`           | Append today's standup entry (yesterday/today/blockers) to `standup.md`. Fills gap from paused `document` worker.                                                            | Daily; manual or scheduled.                                     |
| `scripts/sprint-pr-body.mjs`           | Auto-fill PR body from `spec.md` + diff-vs-spec when PR opens on sprint branch. `--from-branch` infers slug.                                                                 | `.github/workflows/sprint-pr-body.yml` on PR open.              |
| `scripts/sprint-velocity.mjs`          | Compute velocity + drift + AC closure metrics (time-to-lock, closure rate, drift events/pauses, scope amendments). Writes `metrics.json`.                                    | Sprint-end.                                                     |
| `scripts/sprint-changelog.mjs`         | Generate per-sprint `CHANGELOG.md` from spec §I + state + git log + retro patterns. Also updates `docs/sprints/_index/capabilities.md`. AC-30.                               | Sprint-end.                                                     |
| `scripts/sprint-update-known-gaps.mjs` | Cross-reference resolved ACs against project known-gaps memory (e.g. `planner_current_state.md`). `--auto-strike` strikes resolved lines in place. AC-8 (Bug #22).           | Sprint-end.                                                     |
| `scripts/sprint-pair-check.mjs`        | Scan spec §I for ACs matching the complex-AC keyword list (auth/payment/RLS/migration/JWT/secret/delete/password/hash/encrypt). Drives pair-mode DRIVER engagement.          | Post-spec-lock; per-AC commits via post-commit hook.            |
| `scripts/sprint-harness-readiness.mjs` | Aggregate `proof/AC-N.md` files into a single readiness report for a sprint.                                                                                                 | After inject-violation proofs land for every AC.                |
| `scripts/sprint-token-tracker.mjs`     | Token burn observability across jscpd, hooks, daemon workers, sprint-hook resolution. Modes: `status` (live), `burn-report` (7-day), `estimate`.                             | Ad-hoc when burn looks suspicious.                              |
| `scripts/sprint-gh-mirror.mjs`         | GitHub Projects v2 MIRROR sync (state.json → GH, one-way). Subcommands: `check`, `init`, `sync`. Sub-issues via GraphQL. `SPRINT_GH_BYPASS=1` skips. AC-32.                  | Spec-lock (init), per-AC close (sync), sprint-end (close epic). |
| `scripts/sprint-gh-project-sync.sh`    | Legacy gh-CLI Project sync. `--check`/`--create`/`--update`/`--close`. Robust against gh version variance (gap #30).                                                         | Pre-AC-32 path; still works for legacy projects.                |

---

## Memory & learning

Pattern storage, decay, and reuse across sprints.

| Script                                   | Purpose                                                                                                                                                                               | When it fires                                                       |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `scripts/sprint-train.sh`                | Gated neural training trigger. Counts trajectories in `.swarm/memory.db`; if ≥20, proposes `ruflo neural train -p coordination -e 50` (doesn't auto-run). `--force` overrides.        | Manual; weekly review.                                              |
| `scripts/sprint-memory-decay.mjs`        | Age-decay confidence scores on `patterns` table. Uses `last_accessed_at`, `decay_rate`, `half_life_days`. Archives below FLOOR (0.2). No migration needed.                            | Nightly 02:00 via launchd (`com.lifeos.sprint-memory-decay.plist`). |
| `scripts/sprint-retro-save-patterns.mjs` | Parse `retro.md`, extract `**lifeos-<key>**: <description>` patterns. Default: list (safe). `--auto-save`: run `ruflo memory store` for each. AC-3 (sprint-system-hardening Bug #21). | Sprint-end.                                                         |
| `scripts/sprint-daa-feedback.sh`         | Batch PR review comments + retro feedback to the `lifeos-reviewer` DAA agent (creates on first run). Trains reviewer to match user's bar over 10-20 sprints.                          | `.husky/post-merge` on merges to `main`; sprint-end.                |
| `scripts/sprint-research-cache.mjs`      | Manage `docs/research/<topic>.md` cache. Commands: `list`, `save`, `get`, `slugify`. WebSearch/WebFetch results cached so future sprints recall instead of re-searching. AC-10/29.    | Wizard context bundling; ad-hoc cache writes.                       |
| `scripts/sprint-cross-pattern-audit.mjs` | For sprint N, report patterns reused from prior sprints, never-recalled patterns (prune candidates), fresh stores. Run at retro.                                                      | Sprint-end (called by `lifeos-retro.yaml`).                         |

---

## Husky hooks

Local git hooks committed to the repo. `husky install` (via `pnpm prepare`) wires them up.

| Hook                               | Purpose                                                                                                                                                                                              | When it fires                                |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `.husky/pre-commit`                | flock-serialized: drift-check → lint-staged → gitleaks (if installed) → affected typecheck → jscpd dup BLOCK at >50%. AC-6 (sprint-system-100). Falls back unlocked if `flock` missing.              | Every `git commit`.                          |
| `.husky/post-commit`               | Sprint-aware: reuse-audit (jscpd, lockfile-guarded — fixed 7GB RAM leak), pair-mode auto-trigger on complex-AC commits. Atomic state.json via shared lock. AC-5 + AC-7.                              | After every `git commit` when sprint active. |
| `.husky/pre-push`                  | flock-serialized: PR review-gate (`sprint-pre-merge-gate.sh`), mirror-parity (`sprint-mirror-check.sh`), explicit-any gate (`check-no-any.mjs`). AC-13 + AC-6.                                       | Every `git push`.                            |
| `.husky/post-merge`                | On merges into `main`/`master` during active sprint: background `sprint-daa-feedback.sh` so merge completes instantly. Queue lands in `state.pending_daa_adapts[]`. AC-11 (Gap F).                   | After every merge into main branch.          |
| `scripts/sprint-pre-merge-gate.sh` | Pre-push review gate. Checks PR body for `reviewer: ✓` + `security: ✓` marks. Missing → queues spawn-requests to `state.pending_review_spawns[]` for Claude to drain. Warn-first 7 days, then block. | Called by `.husky/pre-push`.                 |

---

## Claude Code hooks

Hooks registered in `.claude/settings.json` that fire on Claude tool use.

| Helper                                  | Purpose                                                                                                                                                                     | When it fires                                |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------- |
| `.claude/helpers/sprint-hook.cjs`       | PreToolUse enforcement: `Bash` → forbidden-action check (no `git push`, `pulumi up`, `rm -rf /`, `DROP TABLE`); `Write                                                      | Edit                                         | MultiEdit`→ out-of-scope file check vs`state.files_touched[]`. Drift control armed. | Every Claude tool call when active sprint exists. |
| `.claude/helpers/statusline-sprint.cjs` | Compact sprint statusline fragment: `[sprint:<slug> day N/14 phase:<p> gates:N✓ drift:0.NN]`. 10s `/tmp/<uid>-statusline-sprint.cache` to avoid per-tick file scans.        | Every statusline refresh (~1s when visible). |
| `.claude/helpers/hook-handler.cjs`      | Cross-platform hook dispatcher. Commands: `route`, `pre-bash`, `post-edit`, `session-restore`, `session-end`. Delegates to `router.cjs`/`intelligence.cjs`/`memory.cjs`.    | Generic hook entry — wired by settings.json. |
| `.claude/helpers/router.cjs`            | Agent router. Routes tasks to optimal agent (coder/tester/reviewer/researcher/architect/backend-dev/frontend-dev/devops) by keyword patterns.                               | `route` command via hook-handler.            |
| `.claude/helpers/intelligence.cjs`      | Intelligence Layer (ADR-050). Wires PageRank-ranked memory into hooks. Reads `auto-memory-store.json`, `graph-state.json`, `ranked-context.json`, `pending-insights.jsonl`. | PreToolUse context augmentation.             |
| `.claude/helpers/memory.cjs`            | Simple K-V memory at `.claude-flow/data/memory.json` for cross-session context. Pure CJS, no dep.                                                                           | Session bridge helpers.                      |
| `.claude/helpers/auto-memory-hook.mjs`  | SessionStart/SessionEnd bridge. `import` (import auto-memory files into backend), `sync` (sync insights back to MEMORY.md), `status`. ADR-048/049.                          | Claude session start/end.                    |
| `.claude/helpers/learning-service.mjs`  | Persistent learning service. ReasoningBank → AgentDB with HNSW indexing + ONNX embeddings. <1ms pattern search target.                                                      | Pattern store/recall paths.                  |
| `.claude/helpers/metrics-db.mjs`        | Cross-platform SQLite (sql.js) metrics store at `.claude-flow/metrics.db`. Single .db, multiple tables.                                                                     | Metrics writers.                             |

---

## Security & PII

PII redaction before external calls.

| Script                                     | Purpose                                                                                                                                                         | When it fires                     |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| `scripts/sprint-pii-redact.sh`             | Strip PII patterns: emails, UUIDs, JWTs, API keys (sk-, AIza, ghp\_, xoxb-), passwords/secrets/tokens, postgres URLs. stdin or arg. Match count to stderr.      | Manually; piped from hooks.       |
| `.claude/helpers/websearch-pii-redact.cjs` | PreToolUse:WebSearch hook. Reads `{tool_input:{query}}`, pipes through `sprint-pii-redact.sh`, returns `{decision:"allow", updatedInput:{query:"<redacted>"}}`. | Every Claude WebSearch tool call. |

---

## Self-tests & meta

The harness verifying itself.

| Script                                     | Purpose                                                                                                                                                                                                      | When it fires                                                      |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| `scripts/sprint-system-test.sh`            | Exercise every harness capability. Writes per-AC pass/fail to `full-system-test.md`. `--replay-gate-history` delegates to replay-validator.                                                                  | Pre-closeout regression check.                                     |
| `scripts/sprint-system-audit.sh`           | Semantic outcome verification. For each capability, INVOKES with real input + ASSERTS observable outcome — no trusting file presence. Built after AC-27's "writes wrong file" bug.                           | After harness changes; `--keep-artifacts` keeps the temp slug dir. |
| `scripts/sprint-replay-validator.mjs`      | Walk every `done` sprint's state.json: gate-history monotonicity, completeness (every required gate has a `gates_passed[]` or `gate_bypasses[]` record), well-formed bypasses, doc-vs-manifest drift. AC-13. | CI; `node scripts/sprint-replay-validator.mjs --quiet`.            |
| `scripts/sprint-inject-violation.sh`       | Apply violation fixture from `scripts/violation-fixtures/`, run gate, assert non-zero exit OR `$ASSERT_PATTERN` match, restore. Used by harness-full-coverage proofs.                                        | Per-AC proof generation.                                           |
| `scripts/sprint-parallel-safety-proofs.sh` | Inject-violation-catch-restore for all 13 ACs of `harness-parallel-safety-v2`. Handles RUNTIME injections (FS, env, locks) that don't fit the patch model.                                                   | One-shot per sprint after AC implementation.                       |
| `scripts/sprint-smoke-validate.sh`         | See [Verify chain](#verify-chain). Cross-listed because it doubles as a regression test.                                                                                                                     | —                                                                  |

---

## Multi-model orchestrator

Experimental router (Opus / MiniMax / Haiku) for cost-sensitive task dispatch. Not yet wired into the main 14-day flow.

| Script                                     | Purpose                                                                                         | When it fires                |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------- | ---------------------------- | ----- | ------ | ---- | -------- | -------------------- |
| `scripts/bin/orchestrator`                 | Multi-model autonomous sprint orchestrator CLI. `start                                          | status                       | pause | resume | stop | report`. | Experimental opt-in. |
| `scripts/orchestrator/phase-controller.sh` | Sprint phase management with multi-model routing. Opus=strategic, MiniMax=coding, Haiku=helper. | Inside `orchestrator` CLI.   |
| `scripts/orchestrator/model-router.sh`     | Decides task → model. Costs: Opus $15/1M, MiniMax $0.28/1M, Haiku $0.25/1M.                     | Sourced by phase-controller. |
| `scripts/models/opus-client.sh`            | Opus API client for strategic tasks. Requires `ANTHROPIC_API_KEY`.                              | Per strategic task.          |
| `scripts/models/minimax-client.sh`         | MiniMax M2.7 API client for coding tasks. Falls back to Opus if `MINIMAX_API_KEY` unset.        | Per coding task.             |

---

## Non-sprint utilities

Repo-wide utilities not specific to the sprint harness.

| Script                                        | Purpose                                                                                                                                                                                                            | When it fires                           |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------- | ------------------- |
| `scripts/check-no-any.mjs`                    | Repo-wide gate: forbid explicit `any` in TS source. Catches `: any`, `as any`, `<any>`, `any[]`. Excludes tests/fixtures/.d.ts/generated/dist.                                                                     | `.husky/pre-push`; `pnpm lint:strict`.  |
| `scripts/check-narrow-selects.mjs`            | Sprint nutrition-page-polish AC-8. Asserts every audited route's `db.select({...})` projection includes all expected column keys per inline manifest. Regex parser, ~30ms.                                         | CI lint gate for narrow-SELECT pattern. |
| `scripts/check-soft-delete-coverage.mjs`      | RLS A2 CI gate. For every Lambda `.from(<table>)` where the schema has `deletedAt`, requires `isNull(<table>.deletedAt)` within ±20 lines.                                                                         | CI.                                     |
| `scripts/pre-commit-duplication.mjs`          | Block commits with >50% code duplication on staged `.ts`/`.tsx` files via `pnpm dlx jscpd`. `SPRINT_DUP_BYPASS=1` logs to `gate_bypasses[]`. AC-17.                                                                | `.husky/pre-commit`.                    |
| `scripts/bundle-lambdas.sh`                   | esbuild each Lambda's handler → single CJS `handler.js` with workspace deps inlined. AWS SDK kept external. Sourcemaps dropped per onboarding-flow-v3 AC-12 audit.                                                 | Pre-deploy.                             |
| `scripts/audit-prod.sh`                       | Strict-mode DB invariant audit. Runs `auditDb({mode:'prod'})` for gio + zefyra against `DATABASE_URL`. Tighter thresholds vs test mode (gen_jobs.no_stuck: 5min vs 30min).                                         | Pre-deploy gate.                        |
| `scripts/smoke-prod.sh`                       | Post-deploy smoke against prod endpoints. Minimal stub for deploy workflow's smoke-test step. AC-15.                                                                                                               | Post-deploy.                            |
| `scripts/bootstrap-supabase.sh`               | Apply all SQL migrations + seed to a fresh Supabase project. Run once per project (dev or prod). Requires DIRECT connection (port 5432), not pgBouncer (6543).                                                     | One-time per Supabase project.          |
| `scripts/migrate-remote.sh`                   | Apply `@lifeos/db` migrations to remote Supabase. Port-swaps :6543 → :5432 (pgBouncer rejects DDL). Credential redaction in stdout/stderr. Requires `--yes` or DB-host confirmation. onboarding-flow-v3 AC-11.     | Deploy chain.                           |
| `scripts/seed-ssm.sh`                         | Seed the 4 SSM parameters for a LifeOS Pulumi stack at `/lifeos/<stage>/`. STAGE=dev                                                                                                                               | prod.                                   | Per stack creation. |
| `scripts/seed-synthetic-user.mjs`             | Create archetype synthetic users (maximalist/minimalist/injured/stressed) for QA. Triple-gated: NODE_ENV≠prod + no `prod` in DATABASE_URL + `LIFEOS_ALLOW_SYNTHETIC_SEED=true`. AC-46.                             | Local QA only.                          |
| `scripts/setup-ruflo.sh`                      | One-time-per-dev ruflo (formerly claude-flow) MCP setup. Idempotent. Daemon, plugins, memory index, encryption.                                                                                                    | After `git clone`.                      |
| `scripts/generate-openapi.sh`                 | Boot `apps/lambdas/local-server.ts`, call `/_docs.json`, capture OpenAPI 3.1 to `docs/openapi.json`, shut down. For offline codegen + diffable spec.                                                               | `pnpm generate:openapi`.                |
| `scripts/coverage-from-playbook.sh`           | Run LifeOS playbook against instrumented dev API for SonarQube coverage. c8-wrapped tsx, `--no-mock` for real Gemini/S3/HealthKit.                                                                                 | CI coverage; pre-Sonar runs.            |
| `scripts/coverage-c8-from-playbook.sh`        | c8-flavored variant: boots `pnpm dev:api:cov`, runs playbook, SIGTERMs server, generates per-Sonar-project lcov via `c8 report --reporter=lcov`.                                                                   | CI coverage.                            |
| `scripts/sonar-scan-all.sh`                   | Local Sonar orchestrator. Runs every configured project serially against `localhost:9000`. Uses brew-installed native arm64 `sonar-scanner` (Docker image is amd64-only).                                          | Local Sonar runs.                       |
| `scripts/mutation-baseline.sh`                | Run Stryker mutation testing on `packages/utils`, extract mutation score, write `coverage/mutation-baseline.txt`.                                                                                                  | Baseline refresh.                       |
| `scripts/playbook-remote.sh`                  | Run full playbook against deployed AWS Lambdas + prod Supabase. Pulls 4 secrets from SSM `/lifeos/<stage>/`, API URL from Pulumi stack output. Wipes user-scoped data for gio + zefyra.                            | Smoke against live stack.               |
| `scripts/launchd/install-memory-decay.sh`     | Install/refresh `com.lifeos.sprint-memory-decay.plist` in `~/Library/LaunchAgents/`. Nightly 02:00 sprint-memory-decay run. AC-6.                                                                                  | One-time per dev machine.               |
| `scripts/patches/apply-ruflo-trigger-race.sh` | Idempotent patch on global `ruflo daemon trigger` so it awaits async init before firing (else falls through to local stub). Re-apply after every `npm i -g ruflo`. Detects via `LIFEOS PATCH 2026-05-19` sentinel. | Post `npm i -g ruflo`.                  |
| `scripts/extract-nutrition-pdf-screens.py`    | Extract screen captures from the nutrition spec PDF (one-off helper for design intake).                                                                                                                            | Ad-hoc design intake.                   |

---

## Out of scope (V3 / swarm-comms infrastructure)

The following `.claude/helpers/` files are unrelated to the sprint protocol — they belong to legacy claude-flow V3 telemetry, swarm-comms experiments, or generic MCP plumbing. They are NOT documented here. If you need their behavior, read the file itself.

- `adr-compliance.sh`, `auto-commit.sh`, `checkpoint-manager.sh`, `daemon-manager.sh`, `ddd-tracker.sh`
- `github-safe.js`, `github-setup.sh`, `guidance-hook.sh`, `guidance-hooks.sh`, `health-monitor.sh`
- `learning-hooks.sh`, `learning-optimizer.sh`, `pattern-consolidator.sh`, `perf-worker.sh`
- `quick-start.sh`, `security-scanner.sh`, `setup-mcp.sh`, `standard-checkpoint-hooks.sh`
- `statusline-hook.sh`, `statusline.js`, `statusline.cjs`, `swarm-comms.sh`, `swarm-hooks.sh`, `swarm-monitor.sh`
- `sync-v3-metrics.sh`, `update-v3-progress.sh`, `v3-quick-status.sh`, `v3.sh`, `validate-v3-config.sh`
- `worker-manager.sh`, `aggressive-microcompact.mjs`, `context-persistence-hook.mjs`, `patch-aggressive-prune.mjs`
- `router.js`, `session.js`, `session.cjs`, `memory.js`, `pre-commit`, `post-commit` (helper variants; the active hooks live in `.husky/`)

---

## Maintenance

When adding a new script:

1. Add a `# <name> — <purpose>` header docstring (≤2-line summary, then expand).
2. Append a row to the appropriate section above.
3. If it mutates `state.json` or `state.phase`, route through `atomic-state.sh` / `sprint-advance-phase.sh` — never write directly.
4. If it adds a new sub-step gate, register it in `scripts/lib/gate-names.json` AND `phase-manifest.json`.
5. Run `node scripts/sprint-replay-validator.mjs --quiet` — `doc_drift` must stay at 0.
