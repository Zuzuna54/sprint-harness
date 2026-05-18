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