# Prerequisites

> **Locked assumption:** Target machine has **only Claude Code** preinstalled. The installer handles every other dependency.

This document inventories every dependency the harness uses, why it's needed, and how it gets onto your machine.

---

## TL;DR — one command does it all

```
npx @ordex/sprint-harness install
```

This installs everything below in the correct order, with interactive prompts for optional tools. To skip prompts (CI-friendly), use `--non-interactive`.

Verify after install:

```
npx @ordex/sprint-harness doctor
```

---

## Tier 1 — Critical (without these, harness doesn't run)

| Tool | Min version | Why | Auto-installed? |
|---|---|---|---|
| Claude Code CLI | latest | Skills, PreToolUse hooks, subagent spawns | No (only preinstall required) |
| node | 20+ | Half the harness scripts are .mjs | Yes (via nvm if missing) |
| git | 2.30+ | Drift baseline, branch resolution | Yes (instructive) |
| jq | 1.6+ | state.json mutations across ~30 scripts | Yes (brew/apt) |
| pnpm or npm or yarn | pnpm 9+ / npm 10+ / yarn 4+ | Workspace task runner, dlx | Yes (detects existing) |
| ruflo (claude-flow) | 3.7.0-alpha.44+ | Daemon workers, memory recall, hive-mind, MCP | Yes (`npm install -g ruflo@latest`) |
| husky | 9+ | Pre/post-commit, pre-push, post-merge hooks | Yes (`pnpm dlx husky init`) |

---

## Tier 2 — Recommended (installer offers; you can skip)

| Tool | Min | Why | Auto-install offer |
|---|---|---|---|
| gh (GitHub CLI) | 2.40+ | sprint-pr-body, sprint-gh-mirror, rebase-check | Yes; auth manual |
| sonar-scanner | 5+ | sprint-sonar-parse static-analysis gate | Yes via brew |
| docker | 24+ | Local SonarQube server | No (install via docker.com) |
| Playwright | 1.40+ | playbook E2E runner | Optional prompt |
| launchctl (macOS) / systemd-user (Linux) | — | memory-decay, workers-shim, sprint-standup schedules | Yes (macOS) |

---

## Tier 3 — On-demand via dlx (no install needed)

Pulled on first use; installer verifies network access only:

- madge, knip, jscpd, c8, eslint

---

## Platform support

| Platform | Status |
|---|---|
| macOS 14+ (arm64/x64) | Primary — all 71 capabilities |
| Linux (Ubuntu 22+/Debian 12+) | v0.2 — instructive |
| Windows | v0.2 — WSL2 recommended |

---

## Doctor output sample

```
═══ sprint-harness doctor ═══

  Tier 1 (critical):
    ✓ claude (CLI)            v1.x.x
    ✓ node                    v20.10.0
    ✓ git                     v2.42.0
    ✓ jq                      v1.7
    ✓ pnpm                    v9.0.0
    ✓ ruflo                   v3.7.0-alpha.44
    ✓ husky                   v9.0.0
    ✓ ruflo daemon            RUNNING (PID 12345)

  Tier 2 (recommended):
    ✓ gh                      v2.42.0    (authenticated)
    ⚠ sonar-scanner           not installed (Sonar gate will skip)

  Result: TIER 1 COMPLETE ✓
          TIER 2 PARTIAL (Sonar gate will skip)
  All 71 capabilities reachable.
```

Exit 0 if Tier 1 complete; exit 1 if missing.

---

## Manual fallback (if installer fails)

macOS Tier 1 manual:

```
brew install jq git
brew install pnpm   # or use installer script from pnpm.io
npm install -g ruflo@latest
pnpm dlx husky init
claude --version
ruflo daemon start --workspace .
```

Then copy harness pieces manually from this repo's `lib/` into your target.

---

## Verifying full functionality

```
npx @ordex/sprint-harness test:install
```

Expected: 71/71 PRODUCTION, exit 0.

---

## Troubleshooting

Common prereq issues (full list in target's `docs/sprints/_guides/troubleshooting.md`):

- ruflo daemon not RUNNING → `ruflo daemon start --workspace .`
- jq missing → `brew install jq`
- gh not authenticated → `gh auth login --scopes project`
- husky hooks not firing → `pnpm dlx husky init && git config core.hooksPath .husky`

---

**Last refreshed:** 2026-05-17
