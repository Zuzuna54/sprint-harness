# History — @ordex/sprint-harness

> **What this document covers:** The provenance, development journey, and acceptance criteria methodology behind the sprint-harness. Intended for contributors who need to understand why decisions were made, and for users who want to trust the system.

---

## Origin — The Problem

In an internal product codebase (lifeos), sprints had become unpredictable. The team would spend days planning, only to discover mid-sprint that:

- Claude was editing files outside the agreed scope
- No record existed of why architectural decisions were made
- The same patterns were being rebuilt every few months
- Push-to-main accidents happened during active sprints
- There was no way to prove a gate actually caught a bug until it was too late

The existing solutions were either too rigid (cookie-cutter templates) or too loose (open-ended workflows with no enforcement).

---

## Development Timeline

### Sprint 1 — Foundation (v0.1.0)

**Goal:** Bring structure to sprint execution. Prove that a scripted 14-day cycle could replace ad-hoc "build it and hope" workflows.

**What was built:**
- State machine: `sprint-start.sh`, `sprint-status.sh`, `sprint-end.sh`, `sprint-pause.sh`, `sprint-resume.sh`
- `sprint-spec-wizard.mjs` — adaptive 10-section spec generator (A through J)
- `docs/sprints/` directory structure with per-sprint state tracking

**What was learned:**
- The spec wizard was too static. It asked the same questions regardless of sprint type (backend-only, frontend-only, full-stack). Different sprint shapes need different coverage.
- Drift detection needed to be automatic, not a manual check. "Trust me, I was in scope" wasn't enough.
- The state.json had too many required fields that didn't exist at spec time.

**Delivered:** 33 acceptance criteria across the 33-AC "harness-full-coverage" sprint.

---

### Sprint 2 — Enforcement (v0.2.0)

**Goal:** Make the harness actually enforce its own rules, not just report them.

**What was built:**
- `sprint-drift-check.sh` + `sprint-drift-score.mjs` — cosine-similarity baseline against spec's files_touched list, triggered on every commit
- `.husky/pre-commit` integration with drift check gate
- `sprint-hook.cjs` — Claude Code PreToolUse hook that blocks out-of-scope edits and forbidden Bash commands (git push, pulumi, rm -rf)
- `sprint-amend-spec.sh` — structured scope amendment with audit trail
- `sprint-build-launch.sh` — 8-agent hierarchical-mesh swarm spawner

**What was learned:**
- File-presence tests were lying. A 99/99 syntactic check (every file exists) passed even when `sprint-pr-body.mjs` was writing to the wrong file and truncating keys. The fix was semantic outcome verification — for each capability, invoke with real input and assert observable output.
- The pre-commit hook had to be merge-safe, not overwrite-safe. Re-running install on a project that already had hooks would destroy existing ones.
- The PreToolUse hook needed to be branch-aware. Multiple sprints on `main` branch (worktree-per-sprint) required `--slug` resolution from git branch.

**Delivered:** AC-33 through AC-57. The inject-violation-catch-restore methodology was formalized in this sprint.

---

### Sprint 3 — Intelligence (v0.3.0)

**Goal:** Make the system learn from itself — recall patterns, surface prior art, detect cross-sprint duplication.

**What was built:**
- `sprint-memory-decay.mjs` — ruflo-backed confidence decay on recalled patterns (prevents stale recommendations from misleading)
- `sprint-reuse-audit.sh` — jscpd-based duplication detection, run post-commit, lockfile-guarded to prevent RAM pile-up
- `sprint-retro-save-patterns.mjs` — extract 3-5 patterns per sprint close, store to ruflo memory for future recall
- `sprint-wizard-context.mjs` — augmented wizard with memory recall (serena suggestions for §E, corpus analysis for §H)
- `sprint-pair-check.mjs` — complex AC detection (auth/RLS/migration/secret/delete/hash keywords) with pair-mode recommendation
- 7 daemon workers: audit, optimize, consolidate, testgaps, predict, document, map — running via ruflo

**What was learned:**
- Memory recall only worked if the namespace was consistent. Per-project isolation (`.swarm/memory.db` in each repo) vs shared-namespaced (single DB, prefix-scoped) both had merit. The harness had to support both via `.sprintrc.json`.
- The reuse audit needed to be async. jscpd scans consume 1-3 GB each; a synchronous post-commit scan would block commit completion. The fix was detached `nohup` execution with PID-based lockfile.
- Serena was referenced in the wizard but never installed. It remained an optional suggestion for §E (UI component symbol search), not a required dependency.

**Delivered:** AC-58 through AC-68.

---

### Sprint 4 — Self-Audit & Packaging (v0.4.0)

**Goal:** Prove the harness works on itself, package for npm distribution, and close the 71-AC regression suite.

**What was built:**
- `tests/install-smoke.mjs` — verify install/uninstall cycle
- `tests/install-matrix.mjs` — test across pnpm-blank, npm-blank, monorepo-with-husky shapes
- `tests/run-all-71-acs.mjs` — regression test against 71 PRODUCTION-verdict ACs
- `docs/PREREQUISITES.md` — Tier 1/2/3 dependency documentation
- macOS launchd plist generation (memory-decay, standup, workers-shim)
- Linux systemd-user timer generation
- `bin/sprint-harness.mjs` — single-entry CLI with install/verify/doctor/uninstall/update subcommands
- `docs/HISTORY.md` — this document

**What was proven:**
- All 71 ACs with PRODUCTION verdict pass against the installed target
- Install matrix covers all three project shapes
- Uninstall preserves docs/sprints history and .sprintrc.json while removing scripts, skills, helpers, hooks, workflows

**Delivered:** AC-69 through AC-71, npm packaging.

---

### Sprint 5 — Parallel-safety (v0.5.0)

**Goal:** Two concurrent sprints in different sessions should never corrupt each other's state. Three classes of bug were eliminated:

1. **Cross-filesystem `state.json` writes** — when `/tmp` was on a different FS than the repo, `mv` was non-atomic and left half-written JSON visible to readers.
2. **mtime-based slug resolution drift** — when a sibling session touched `state.json`, the wrong sprint resolved as "active" in this session's hooks.
3. **Inter-sprint claim collisions** — two sessions racing for the same AC could both grab it.

**What was built:**

- `lib/scripts/lib/atomic-state.sh` — variadic `atomic_update_state` helper (forwards `--arg`/`--argjson` to jq). mktemp on same FS + `flock` (or PID-noclobber fallback) + `jq empty` validate + `.bak` backup + atomic `mv` rename.
- `lib/scripts/lib/session-file.sh` — session-scoped active-sprint context. Eliminates sibling-session interference.
- `lib/scripts/lib/lock-dir.sh` — `LOCK_DIR=${XDG_RUNTIME_DIR:-$HOME/.cache/<BRAND_SLUG>/locks}` (0700-perm) for `flock` around git commits.
- Resolution chain v2 — `env-override → session-file → state.json → none`. **mtime fallback REMOVED**.
- 16 unsafe scripts refactored to use `atomic_update_state` (every `cat | jq | tee state.json` callsite).
- launchd reasserter phase-awareness + 24h hard-timeout escape for hung sprints. Corrupt `state.json` writes `needs-review.json` sidecar instead of clobbering.
- `lib/scripts/sprint-mirror-check.sh` — pre-push hard-fail when lifeos outpaces sprint-harness mirror by > `MIRROR_LAG_THRESHOLD=2` commits.

**What was learned:**

- macOS bash 3.2 + `set -u` trips on empty `${arr[@]}`. Variadic helpers must guard with `${arr[@]+"${arr[@]}"}`.
- The dogfooding-while-building pattern (using the harness to build itself) surfaced 2 upstream bugs the spec missed: the variadic `--arg` forwarding gap, and a ruflo `daemon trigger` async-init race that made every worker fall to local-mode stub instead of calling Claude.

**Delivered:** 13/13 ACs Production + 1 implicit AC-14 (ruflo trigger race patch).

---

### Sprint 6 — Workers → on-demand (v0.6.0)

**Goal:** Eliminate ~9 hours/day of silent Sonnet quota burn from scheduled daemon workers.

The problem: ruflo's 7 daemon workers (`audit`, `optimize`, `testgaps`, `predict`, `document`, `map`, `consolidate`) fire on hardcoded 10-30 min intervals. Each invocation shells out to `claude --print` using the **same Claude Code OAuth session** as interactive work — burning Pro/Max subscription quota silently while reports rotted in `.claude-flow/metrics/`, never consumed by a gate.

**What was built:**

- Workers re-mapped to **sprint-protocol checkpoints only**: Day 0 `map`, Day 1-2 `ultralearn`/`deepdive`, per-wave `predict`, Day 5 `consolidate`, Day 11 `refactor`, Day 11-12 `audit`+`testgaps`+`optimize`, Day 14 `document`+`consolidate`.
- `lib/scripts/lib/worker-trigger.sh` — polls `.claude-flow/metrics/<worker>.json` mtime, copies output to `docs/sprints/<slug>/worker-output/<worker>.json`.
- `lib/scripts/lib/worker-gates.sh` — `gate_audit_blocks` (zero-tolerance, any finding blocks deploy) + `gate_testgaps_blocks` (scope-bounded to spec `## Files touched`).
- `lib/scripts/sprint-verify.sh` — wraps the full USAGE.md verify chain (`typecheck → lint → tests → api-contract → debug-rls → module-status → perf-profile → aidefence-scan`) AND fires `audit`+`testgaps`+`optimize` workers in parallel at the end.
- `lib/scripts/sprint-wave-start.sh` — fires `predict` per wave for context preloading.
- `lib/scripts/patches/ruflo-trigger-race.patch` + `apply-ruflo-trigger-race.sh` — patches upstream ruflo `daemon trigger` async-init race (calls `triggerWorker()` before `initHeadlessExecutor()` resolves, so `headlessAvailable` stays false and every worker falls to a local-mode stub). Not fixed in alpha.69 either.
- Daemon settings flipped to `autoStart=false`, all workers `disabled` by default. Daemon stays warm but never fires on schedule.

**What was learned:**

- Workers use the user's OAuth session (Pro/Max quota), NOT a separate API key. Background scheduling is silent quota burn.
- The diagnosis pattern that surfaces this: count background processes (`ps aux | grep ruflo`), read `ruflo daemon status` for `Workers Enabled: N`, check `.claude-flow/metrics/<worker>.json` for `model` field. See `lifeos-diagnose-subscription-quota-burn` memory.

**Delivered:** ~9 h/day → ~50 min per 14-day sprint. >99 % reduction in worker quota usage. CI hard-fails when `claude` OAuth missing; local dev degrades gracefully.

---

## Methodology — Inject-Violation-Catch-Restore

After Sprint 2's discovery that file-presence tests were lying, every capability that ships in this harness is now proven by the following protocol:

1. **Baseline** — Run the gate against clean main (no violations)
2. **Inject** — `git apply` a known-violation fixture (e.g., bad type in source, missing RLS policy, oversized bundle)
3. **Catch** — Re-run the gate; assert it detects the violation and exits non-zero
4. **Restore** — `git apply -R` to revert the fixture
5. **Document** — Write proof markdown (`lib/proof/AC-N.md`) with all three steps and the verdict

**Two-verdict policy:** Each AC gets either:
- **PRODUCTION** — gate works end-to-end, real violation caught, real test executed
- **Broken-with-follow-up** — gate exists but has a documented gap; a follow-up AC closes it

There is no "Scaffolded" middle bucket. That category was where false victories lived.

---

## Version Reference

| Version | Date | Key Change |
|---|---|---|
| 0.1.0 | ~2026-04 | State machine + spec wizard foundation |
| 0.2.0 | ~2026-04 | Enforcement: drift hooks, PreToolUse, scope guard |
| 0.3.0 | ~2026-05 | Intelligence: memory recall, reuse audit, pair-mode |
| 0.4.0 | 2026-05-17 | Self-audit: 71-AC regression suite, npm packaging |
| 0.4.1 | 2026-05-18 | Heredoc + `<<'EOF'` quoting, hardcoded-path fixes, HISTORY.md |
| 0.4.2 | 2026-05-18 | Token-efficiency: lazy-require handlers + 5-min `getActiveSprint()` cache |
| 0.5.0 | 2026-05-18 | Parallel-safety: atomic-state + session-file + resolution-chain v2 + mirror-check |
| 0.6.0 | 2026-05-19 | Workers → on-demand sprint-protocol integration (~9h/day burn → ~50min/sprint) + ruflo trigger-race patch |

---

## What Was Not Built

The following were considered but deferred (not in scope for v0.4):

- **Windows native support** — WSL2 is the path for Windows users
- **Serena MCP integration** — referenced in wizard §E as an optional suggestion, never installed
- **SonarQube token auto-recovery** — when admin password differs from default and token file is absent, the installer warns rather than prompting
- **Semantic (LLM-based) code graph** — graphify runs in AST-only mode (tree-sitter, no LLM needed for code); semantic extraction requires an API key

---

## Extending the Harness

See `docs/sprints/DEVELOPER.md` (installed at target time) for the full guide. Key rules:

- **SKILL.md and section markdown changes** — highest ROI, lowest risk
- **New scripts or hooks** — requires an `inject-violation-catch-restore` proof before merge
- **Workflow YAML additions** — no proof required if the workflow is invoked by a script that has its own proof

The harness was designed to be absorbed by the team, not just used by it. Every decision is documented in the state.json audit trail, the wizard transcript, and the retrospective patterns store.