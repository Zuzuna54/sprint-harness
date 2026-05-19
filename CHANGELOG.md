# Changelog

All notable changes to `@ordex/sprint-harness` are documented here.
This project follows [Semantic Versioning](https://semver.org/) and the
[keep-a-changelog](https://keepachangelog.com/en/1.1.0/) format.

---

## [0.7.0] — 2026-05-19

### Added — Deterministic phase enforcement

- **`scripts/lib/phase-manifest.json`** — source-of-truth declaring 11 sprint phases and their required artifacts, state fields, sub-step gates (25 enforced + 43 deferred per T4), and `advances_to` transitions. New top-level fields: `_comment` (doc note) + `deferred_gates[]` (gates instrumented under follow-up sprint `harness-verify-instrumentation-v1`).
- **`scripts/lib/phase-manifest.schema.json`** — JSON-Schema for the manifest, validated at every `sprint-advance-phase.sh` invocation.
- **`scripts/lib/phase-predicates.sh`** — 9 predicate evaluators (`file_exists`, `file_min_bytes`, `file_contains_heading`, `json_path_present`, `json_path_equals`, `json_path_in`, `state_field_min_length`, `state_field_all_values_in`, `sub_step_recorded`).
- **`scripts/lib/sub-step.sh`** — `record_sub_step <slug> <gate> <pass|fail> [evidence-path]`. Writes atomic, append-only `state.sub_steps[]` entries. Path-canonicalizes evidence + rejects `..` traversal. Warns on unknown gate names.
- **`scripts/sprint-advance-phase.sh`** — canonical phase mutator. ONLY sanctioned writer of `state.phase`. Validates predicates, walks every `required_sub_step_gates`, supports `--from <expected-current>` invariant. TOCTOU-safe jq filter wraps the phase write in an `if .phase == $current` check.
- **`scripts/sprint-replay-validator.mjs`** — replays `gate_history[]` against the manifest after sprint close. Asserts monotonic transitions + per-phase coverage + doc-vs-manifest drift. `--report-file <path>` writes markdown artifact for CI.
- **`scripts/lib/validate-phase-manifest.mjs`** — startup-time schema check.
- **`scripts/lib/gate-names.json`** — generated constants file (68 gates) for cross-tool rename safety.

### Added — Hook chokepoint at write-time

- **`lib/templates/.claude/helpers/sprint-hook.cjs`** PreToolUse blocks:
  - `JQ_PHASE_WRITE` — `jq … .phase = …` and `jq … .["phase"] = …` (broad anchor, depth-3 ppid walk to allow sanctioned advance-phase delegates).
  - `SED_OR_REDIRECT_TO_STATE_JSON` — `sed -i … state.json` and `>> state.json` redirects.
  - `INTERPRETER_WRITE_TO_STATE_JSON` — `jq -f`, `python -c`, `node -e`, `awk`, `perl -i`, `ruby` writing to `state.json`.
  - `RM_OR_MV_STATE_JSON` — `rm`/`mv`/`trash`/`unlink` targeting `state.json`.
  - `parentIsAdvancePhase()` — depth-3 ppid ancestor walk; only sanctioned writes pass.

### Added — Single bypass UX

- `SPRINT_BYPASS_GATE=<gate-name>` + `SPRINT_BYPASS_WHY=<≥10 chars rationale>` is now the **only** bypass surface. Rationales pass through `sprint-pii-redact.sh` before landing in `state.gate_bypasses[]` (no plaintext emails/JWTs/API keys in git history).
- Deprecation shims: 7 legacy `SPRINT_*_BYPASS` envs (`DRIFT`, `DUP`, `SKIP_REUSE_AUDIT`, `NO_REVIEW_GATE`, `DESIGN_LOCK`, `PREDEPLOY`, `HIVE_MIND`) auto-translate + emit stderr warning. **Removal targeted for v0.8.0.**
- 9 sprint-`*`.sh scripts migrated: `sprint-cleanup-launch.sh`, `sprint-checkin.sh`, `sprint-end.sh`, `sprint-design-lock.sh`, `sprint-predeploy-gate.sh`, `sprint-amend-spec.sh`, `sprint-pause.sh`, `sprint-resume.sh`, `sprint-status.sh`. All sub-step records flow through canonical mutator.

### Added — Tier 1-4 audit closure

After post-implementation audit caught 5 ACs as `Broken-with-followup`, a fix-up pass landed:

- **T1.1-T1.7** — re-baselined docs (USAGE.md `## Phase enforcement`, DEVELOPER.md write-ordering rules, `_guides/bypass-cheatsheet.md`, `_guides/sub-step-coverage.md`, parent retro completeness).
- **T2.1-T2.13** — hook regex broadening, 9-script audit (1 false-pass risk filed v0.7.1), 4 untested predicate evaluators smoke-tested, strict-mode end-to-end, `--from` invariant smoke, retro completeness instrumentation verified.
- **T3.1-T3.4** — replay validator monotonic gate history + doc-drift regex + pre-v0.7 implicit skip + `--quiet` mode.
- **T4** — `deferred_gates[]` top-level manifest field marks the 43 unwired gates as `[DEFERRED]` not `[FAIL]`.

### Security improvements (vs v0.6.0)

- TOCTOU race in atomic phase writes — closed by expected-current check.
- Evidence path traversal (`record_sub_step ... ../../etc/passwd`) — rejected at function entry.
- PII in bypass rationale — redacted via `sprint-pii-redact.sh`.
- `rm`/`mv` state.json escape — blocked by hook.
- Hook regex bypass via `jq -f`/`python -c`/`awk`/`perl -i` — blocked.

### Breaking changes

None for v0.6.x consumers — all legacy bypass envs continue to work with deprecation warnings. Removal scheduled for v0.8.0; migrate to single-bypass UX before then.

### Files mirrored from lifeos (24 files)

Scripts: `sprint-advance-phase.sh`, `sprint-replay-validator.mjs`, `sprint-spec-wizard.mjs`, `sprint-system-test.sh` + 9 modified phase-writers. Lib: `phase-manifest.json`, `phase-manifest.schema.json`, `phase-predicates.sh`, `sub-step.sh`, `bypass.sh`, `validate-phase-manifest.mjs`, `gate-names.json`. Templates: `.claude/helpers/sprint-hook.cjs`, `skills/sprint-orchestrator/SKILL.md`, `skills/sprint-spec-wizard/sections/J-risks.md`, `sprints/USAGE.md`, `sprints/DEVELOPER.md`, `sprints/_guides/bypass-cheatsheet.md`, `sprints/_guides/sub-step-coverage.md`, `github/workflows/test.yml` (brand-stripped).

---

## [0.6.0] — 2026-05-19

### Added — Workers → sprint-protocol on-demand integration

- Daemon worker scheduling replaced with sprint-stage-driven invocation. Workers fire ONLY at protocol checkpoints (Day 0 `map`, Day 1-2 `ultralearn`/`deepdive`, per-wave `predict`, Day 5 `consolidate`, Day 11 `refactor`, Day 11-12 `audit`+`testgaps`+`optimize`, Day 14 `document`+`consolidate`).
- ~9h/day silent Sonnet burn → ~50min per 14-day sprint (>99% reduction).
- New helpers in `lib/scripts/lib/`: `worker-trigger.sh` (polls `.claude-flow/metrics/<worker>.json` mtime; copies output to `docs/sprints/<slug>/worker-output/`), `worker-gates.sh` (audit zero-tolerance gate + testgaps files-touched gate).
- New top-level scripts: `lib/scripts/sprint-verify.sh` (wraps full verify chain + parallel worker fires), `lib/scripts/sprint-wave-start.sh` (fires `predict` per wave).
- New patch artifacts: `lib/scripts/patches/ruflo-trigger-race.patch` + `lib/scripts/patches/apply-ruflo-trigger-race.sh` — fixes upstream ruflo `daemon trigger` async-init race that made workers fall to local-mode stubs.
- Audit gate: zero-tolerance (any finding blocks deploy).
- Testgaps gate: scope-bounded to spec `## Files touched` — vacuous-pass when no routes in scope.
- Optimize: advisory only (logged in `dashboard.html`, never blocking).
- CI hard-fails if `claude` OAuth missing; local dev degrades gracefully.

### Added — Token-burn cleanup (rolled in from lifeos@47b29ab + 58868b6)

- `statusline-sprint.cjs`: 10s file-cache eliminates redundant `state.json` reads on every prompt.
- `hook-handler.cjs`: 30s intelligence cache + skip-short-prompts + drop 25-line theatrical routing table.
- `sprint-start.sh`: `graphify-rebuild` skips when corpus is <4h fresh.
- `.husky/post-commit`: POSIX child-spawn timeout (replaces unreliable perl-alarm misfires).
- `lib/templates/.claude/settings.json`: `teammateMode=manual`, `daemon.autoStart=false`, `HOOK_BUDGET_MS=3000`, `skillListingBudgetFraction=0.06`.

### Fixed — Ruflo CLI drift sweep (lifeos@43047b8 + 41e12da)

- `ruflo memory embed` (does not exist) → `ruflo embeddings generate -t <text> -o json`.
- `ruflo hive-mind consensus -a submit` (invalid action) → `-a propose`.
- `ruflo neural train --type` (renamed flag) → drop `--type`.
- `ruflo embeddings encode` (renamed) → `ruflo embeddings generate`.
- `ruflo daa list` (deprecated) → `ruflo daa registry list`.

### Notes
- All 11 mirror commits since v0.5.0 absorbed here.
- Tags `v0.4.2` and `v0.5.0` (below) were not previously documented — backfilled in this release.

---

## [0.5.0] — 2026-05-18

### Added — harness-parallel-safety-v2 (lifeos@dccb8b4 → 8954a6a, 13/13 ACs)

Hardens parallel sprint workflows. Eliminates cross-FS races in `state.json` writes, mtime-based slug resolution drift between sessions, and inter-sprint claim collisions.

- **`lib/scripts/lib/atomic-state.sh`** [AC-3] — `atomic_update_state <slug> [jq-flags...] '<filter>'`. mktemp on same FS + `flock` (or PID-noclobber fallback) + `jq empty` validate + `.bak` backup + atomic `mv` rename. Variadic — forwards `--arg`/`--argjson`/`--slurpfile` to jq verbatim.
- **`lib/scripts/lib/lock-dir.sh`** [AC-6] — `LOCK_DIR=${XDG_RUNTIME_DIR:-$HOME/.cache/<BRAND_SLUG>/locks}` (0700-perm) for `flock` around git commits. Prevents concurrent-sprint git index corruption.
- **`lib/scripts/lib/session-file.sh`** [AC-1] — session-scoped active sprint context. Eliminates sibling-session interference.
- **Resolution chain v2** [AC-2] — `env-override → session-file → state.json → none`. **mtime fallback REMOVED**. Audit-log on `SPRINT_SLUG_OVERRIDE` usage.
- **16 unsafe scripts refactored** [AC-4] — every `cat | jq | tee state.json` callsite moved to `atomic_update_state`.
- **launchd reasserter phase-awareness** [AC-7] — corrupt `state.json` writes `needs-review.json` sidecar instead of clobbering. 24h hard-timeout escape for hung sprints.
- **`lib/scripts/sprint-mirror-check.sh`** [AC-13] — pre-push hard-fail when lifeos outpaces sprint-harness by > `MIRROR_LAG_THRESHOLD=2` commits on harness-scope files.
- **`lib/scripts/sync-mirror.sh`** [AC-9] — bulk sync helper with brand-strip for workflow yamls (`lifeos → <BRAND_SLUG>`).
- **`.claude/helpers/sprint-hook.cjs` session-file gate** [AC-12] — validates resolved sprint is `active`/`building`, not `paused`/`done`.
- **Drift-check no-sprint skip** [AC-11] — exits 0 cleanly when resolution chain returns "no active sprint".
- **`atomic_update_state` migration claim files** [AC-5] — atomic `mkdir`-as-lock. Whoever wins dir creation wins the AC.

### Fixed

- **macOS bash 3.2 + `set -u`** — `${arr[@]}` with empty array triggers unbound-var error. Variadic helpers use `${arr[@]+"${arr[@]}"}` guard.
- **Session-file gate** prevents the parallel-session pause loop bug (sibling session keeps un-pausing your active sprint, hook resolves wrong).

### Notes
- 5 patterns saved to ruflo memory: `lifeos-atomic-state-args-trap`, `lifeos-ruflo-cli-drift`, `lifeos-stale-bug-diagnosis`, `lifeos-ruflo-trigger-headless-race`, `lifeos-bash3-variadic-trap`.

---

## [0.4.2] — 2026-05-18

### Fixed — Token-efficiency mirror from lifeos

- **`hook-handler.cjs`** — lazy-require per-handler (was eager-loading 4 modules on every hook invocation).
- **`sprint-hook.cjs`** — 5-min TTL cache on `getActiveSprint()` (was re-reading `state.json` on every PreToolUse).
- **`lib/templates/.claude/settings.json`** — `teammateMode=manual`, daemon workers reduced to 4, `HOOK_BUDGET_MS=3000`.
- **`sprint-reuse-audit.sh`** — `timeout 120` on jscpd invocation (macOS perl-alarm fallback was unreliable).

---

## [0.4.1] — 2026-05-18

### Fixed
- **Critical:** Heredoc quoting — `<<EOF` changed to `<<'EOF'` in `sprint-smoke-validate.sh`, `sprint-system-audit.sh`, `sprint-amend-spec.sh` (3 instances), `sprint-start.sh`, `sprint-workers-shim.sh`. Without quoting, `<BRAND_SLUG>` was interpreted as shell stdin redirect, causing plist generation failures. (Found in internal audit, 2026-05-18)
- **Critical:** Duplicate `let adminPw` declaration in `bin/sprint-harness.mjs` caused syntax error on install. Removed the duplicate (introduced during token fallback fix).
- **High:** `smoke-prod.sh` listed in `sprint-smoke-validate.sh` file list but does not exist. Removed orphan reference.
- **High:** `update` command hardcoded `harnessVersion: '0.2.0'` instead of reading from `package.json`. Fixed to use `HARNESS_VERSION`.
- **Medium:** ruflo daemon polling was 30s (15×2s) — insufficient for fresh workspace initialization in ruflo v3.7.0-alpha.44. Bumped to 60s (30×2s).
- **Medium:** GH label creation failed silently in fresh repos with no GitHub remote. Added `git remote get-url origin` pre-check; skips block with informational message.
- **Medium:** Sonar token generation failed silently when `admin:admin` fallback failed (Sonar already initialized with different password). Now checks existing `~/.sprint-harness/sonar-token` file before attempting reset.

### Added
- **`docs/HISTORY.md`** — full 4-sprint provenance narrative, inject-violation-catch-restore methodology explanation, and version reference table. README.md no longer references a missing file.

---

## [0.4.0] — 2026-05-17

### Added
- **`ruflo init`** runs after `ruflo daemon start` — target gets the full ruflo skill/helper bundle (not just the 2 sprint-specific skills). [AC C1]
- **MCP wire-up** — installer idempotently adds a `ruflo` entry to target's `.mcp.json` (creates the file if absent, from `lib/templates/mcp.json`). [AC #6 / AC C4]
- **6 custom subagents** ship in `lib/templates/agents/` and land in target's `.claude/agents/` (api-contract-checker, design-reviewer, module-integrator, perf-auditor, rls-verifier, security-reviewer). [AC C2]
- **3 autopilot configs** ship in `lib/templates/claude-flow/autopilot/` (lint-fix, test-backfill, doc-sweep). [AC C3]
- **launchd templates** moved to `lib/templates/launchd/`; installer copies to `~/Library/LaunchAgents/` then bootstraps (fixes macOS 12+ launchctl behavior). [AC B3 / AC E5]
- **gh auth login** prompt when `gh` is installed but unauthenticated. [AC #7]
- **husky init** snapshots target `package.json` and preserves any pre-existing `prepare` script by chaining (`<old> && husky`). [AC #8]
- **WSL2 detection** — Linux branch warns when systemd-user isn't enabled; Windows native exits cleanly. [AC #10]
- **SonarQube bootstrap idempotency** — detects container state (not-exists / stopped / running); admin pw cached at `$HOME/.sprint-harness/sonar-admin` (0600). [AC #11]
- **Sonar token** moved to `$HOME/.sprint-harness/sonar-token` with chmod 0600 (was world-readable `/tmp/`). [AC #5]
- **Managed `.gitignore` block** — idempotently adds harness-generated paths to target's `.gitignore`. [AC #12]
- **package.json sprint:* aliases** — `sprint:start`, `sprint:status`, `sprint:end`, `sprint:pause`, `sprint:resume`, `sprint:doctor`, `sprint:verify`. [AC #13]
- **`doctor` covers all v0.3 surfaces** — launchctl loaded, systemd timers active, sonar token present, playwright installed, gh labels recorded, ruflo init ran, MCP configured, memory.db isolation. [AC #4]
- **Phase-transition gates** — new scripts `sprint-design-lock.sh` and `sprint-predeploy-gate.sh` for the orchestrator's design-lock (Phase 2) and pre-deploy (Phase 6) transitions. [AC D1 / D2]
- **Hook lifecycle coverage** — installer wires PreToolUse + PostToolUse + SessionStart + SubagentStop hooks, with dedupe-by-matcher (re-install is idempotent). [AC B9 / B10]
- **`harnessVersion` read from `package.json`** instead of hardcoded. [AC #3]
- **`test` npm script** chains install-smoke + matrix + 71-ACs. [AC B1]
- **Vendored proof fixtures** at `lib/proof/` — `tests/run-all-71-acs.mjs` no longer depends on external `PROOF_SOURCE`. [AC B5]
- **CI workflows** at `.github/workflows/test.yml` (PR gate) and `.github/workflows/publish.yml` (tag-driven npm publish with provenance). [AC B2 / AC #17]
- **`docs/PREREQUISITES.md`** documents Tier 1/2 deps, OS specifics, troubleshooting. [AC #15]
- **`.npmignore`** keeps tarball lean (excludes tests/, .github/, .husky/, .editorconfig, .nvmrc, .npmrc). [AC B6]
- **`homepage`** + **`LICENSE`** in `package.json.files`. [AC B8]
- **`.editorconfig`**, **`.nvmrc`** (20), **`.npmrc`** (registry pinning). [AC E2 / E3 / E4]
- **ISSUE_TEMPLATE** + **PULL_REQUEST_TEMPLATE** + **CODEOWNERS** under `.github/`. [AC E7 / E8]
- **`copyWithSubstitution` guards** each source dir with `existsSync` + clear error. [AC E6]

### Fixed
- **Critical:** `config` was referenced (`config.sonar_token_path`, `config.playwright_installed`) BEFORE `const config = await brandPrompts()` was declared. Interactive installs crashed on yes-to-SonarQube/Playwright. Fixed by moving `brandPrompts()` to Step 0. [AC #2]
- **Critical:** Hardcoded `/Users/gio/` paths in `lib/scripts/sprint-update-known-gaps.mjs` and `lib/scripts/sprint-drift-check.sh`. Replaced with `$HOME` / repo-relative. [AC B4]
- **Critical:** Empty `<AWS_PROFILE_NAME>` substitution left downstream bash scripts with `profile=""` syntax errors. Now substitutes `default` when the user opts out. [AC B7]
- **High:** Step numbering collision — Linux systemd block and macOS launchctl block both labeled "Step 10". Renumbered. [AC #14]
- **High:** Hardcoded `/Users/gio/.claude/plans/hazy-gathering-kettle.md` references in `lib/skills/sprint-orchestrator/SKILL.md` and `lib/skills/sprint-spec-wizard/SKILL.md`. Replaced with `docs/sprints/<slug>/spec.md`. [AC D3]
- **Low:** `Zuzuna54/sprint-harness` clone URL in CONTRIBUTING.md + lifeos attribution in README.md sanitized. [AC D4]
- **Low:** Tier 1 `node`/`git` deps were "instructive only" — now hard-fail with an actionable message. [AC #9]

### Notes
- 42 ACs closed in a single wave-based sprint (`harness-portability-v4`).
- Full proof: `npm test` runs 71/71 ACs against vendored fixtures + 3/3 install-matrix shapes + install-smoke.

---

## [0.3.0] — 2026-05-17

- Docker auto-install (macOS).
- SonarQube container + token bootstrap.
- launchctl auto-bootstrap (macOS).
- Linux systemd-user auto-install.
- Playwright install wire-up.
- Per-project `.swarm/memory.db` isolation.
- gh labels auto-create.
- 30s ruflo daemon polling.
- `tests/run-all-71-acs.mjs` (71/71 PASS) + `tests/install-matrix.mjs` (3/3 shapes).

---

## [0.2.0]

- Multi-sprint parallel state-locking (`scripts/lib/state-lock.sh`).
- Atomic state.json mutations.
- Bypass-env logging (SPRINT_DRIFT_BYPASS, SPRINT_DUP_BYPASS, AMEND_ALLOW_EMPTY).

---

## [0.1.0]

- Initial extraction of the sprint harness from internal product codebase.
- Installer CLI (`install` / `verify` / `doctor` / `uninstall` / `update`).
- Brand-stripping templating (`<BRAND_NAME>`, `<BRAND_SLUG>`, `<NAMESPACE>`, `<GITHUB_ORG>`, `<AWS_PROFILE_NAME>`, `<REPO_ROOT>`).
- Sprint protocol skills (orchestrator + spec-wizard).
