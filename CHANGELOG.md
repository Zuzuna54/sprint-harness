## v0.6.0 — 2026-05-19

### Workers → sprint-protocol on-demand integration

- Daemon worker scheduling replaced with sprint-stage-driven invocation.
  Workers fire ONLY at protocol checkpoints (Day 0 map, Day 1-2 ultralearn/
  deepdive, per-wave predict, Day 5 consolidate, Day 11 refactor, Day 11-12
  audit+testgaps+optimize, Day 14 document+consolidate).
- ~9h/day silent Sonnet burn → ~50min per 14-day sprint (>99% reduction).
- New: `lib/scripts/lib/worker-trigger.sh`, `lib/scripts/lib/worker-gates.sh`,
  `lib/scripts/sprint-verify.sh`, `lib/scripts/sprint-wave-start.sh`.
- audit gate: zero-tolerance (any finding blocks deploy).
- testgaps gate: scope-bounded to spec ## Files touched.
- optimize: advisory only.
- CI hard-fails if claude OAuth missing; local dev degrades gracefully.

### Token-burn cleanup (rolled in from lifeos@47b29ab)

- statusline-sprint.cjs: 10s file-cache
- hook-handler.cjs: 30s intelligence cache + skip-short-prompts + drop
  25-line theatrical routing table
- sprint-start.sh: graphify-rebuild skips when <4h fresh
- post-commit: POSIX child-spawn timeout (replaces perl-alarm misfires)

# Changelog

All notable changes to `@ordex/sprint-harness` are documented here.
This project follows [Semantic Versioning](https://semver.org/).

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

## [0.2.0]

- Multi-sprint parallel state-locking (`scripts/lib/state-lock.sh`).
- Atomic state.json mutations.
- Bypass-env logging (SPRINT_DRIFT_BYPASS, SPRINT_DUP_BYPASS, AMEND_ALLOW_EMPTY).

## [0.1.0]

- Initial extraction of the sprint harness from internal product codebase.
- Installer CLI (`install` / `verify` / `doctor` / `uninstall` / `update`).
- Brand-stripping templating (`<BRAND_NAME>`, `<BRAND_SLUG>`, `<NAMESPACE>`, `<GITHUB_ORG>`, `<AWS_PROFILE_NAME>`, `<REPO_ROOT>`).
- Sprint protocol skills (orchestrator + spec-wizard).
