# <BRAND_SLUG_TITLE> sprint capabilities index

Auto-aggregated from each sprint's CHANGELOG.md + manually-curated for cross-sprint reference. Last updated: 2026-05-17.

**Wizards: grep this file during §H integration to find existing capabilities before proposing a duplicate surface.**

---

## harness-full-coverage (closed 2026-05-17, 71/71 Production)

The full sprint-harness surface, proven via inject-violation-catch-restore methodology. Each capability has `docs/sprints/harness-full-coverage/proof/AC-N.md` documenting baseline + injected violation + caught output + restore evidence.

### Group 1 — Verify-workflow gates (AC-1-15)

| AC    | Capability                                      | What it catches                                                                 |
| ----- | ----------------------------------------------- | ------------------------------------------------------------------------------- |
| AC-1  | `pnpm turbo run typecheck --filter='...[HEAD]'` | TS type errors in affected packages                                             |
| AC-2  | `scripts/sprint-lint-check.sh` (ESLint shim)    | `var`, `debugger`, lint violations (.js/.mjs scope)                             |
| AC-3  | `pnpm turbo run test --filter='...[HEAD]'`      | Failing vitest/supertest cases                                                  |
| AC-4  | `pnpm graphify:rebuild`                         | Generates fresh graph corpus (god-nodes + communities)                          |
| AC-5  | `pnpm test:playbook:cov` (playbook + c8 lcov)   | Coverage drops vs baseline                                                      |
| AC-6  | `pnpm sonar` + `scripts/sprint-sonar-parse.mjs` | New critical/blocker Sonar issues vs baseline                                   |
| AC-7  | `scripts/sprint-migration-check.sh`             | Schema change without corresponding Drizzle migration                           |
| AC-8  | `pnpm knip`                                     | Unused exports/files (real catches: 34 files this sprint)                       |
| AC-9  | `scripts/sprint-coverage-delta.mjs`             | Coverage drop >5% per file vs main                                              |
| AC-10 | `scripts/sprint-audit-deps.sh`                  | New high/critical CVE in pnpm-lock                                              |
| AC-11 | `scripts/sprint-bundle-budget.mjs`              | Lambda bundle exceeds 5MB budget (real catch: ai-scheduler 5.20MB, auth 7.99MB) |
| AC-12 | `scripts/sprint-cycle-check.sh`                 | New cyclic dep introduced (madge-backed)                                        |
| AC-13 | `scripts/sprint-perf-check.mjs`                 | P95/payload/db-query bars exceeded vs §I spec                                   |
| AC-14 | `mcp__claude-flow__aidefence_scan`              | Prompt-injection / jailbreak attempts                                           |
| AC-15 | all-pass-gate (last step in verify chain)       | Workflow chain semantics — gate only fires if all prior passed                  |

### Group 2 — Workflows (AC-16-19)

All invoked via `scripts/run-workflow.sh <yaml>` shim (Ruflo #1916 upstream gap).

| AC    | Workflow                     | Purpose                                                         |
| ----- | ---------------------------- | --------------------------------------------------------------- |
| AC-16 | `<BRAND_SLUG>-sprint-build.yaml`   | 8-agent swarm + claims + autopilot side-cars + trajectory open  |
| AC-17 | `<BRAND_SLUG>-sprint-verify.yaml`  | 28-step verify chain (typecheck → all-pass) with audit wiring   |
| AC-18 | `<BRAND_SLUG>-sprint-cleanup.yaml` | deadcode-delete + lint --fix + tests + claude-md-autoclean      |
| AC-19 | `<BRAND_SLUG>-deploy.yaml`         | bundle → preview → **HUMAN PAUSE** → pulumi up → smoke → vercel |

### Group 3 — Pre-existing scripts (AC-20-25)

| AC    | Script                                 | Purpose                                         |
| ----- | -------------------------------------- | ----------------------------------------------- |
| AC-20 | `sprint-pause.sh` + `sprint-resume.sh` | Round-trip phase suspension                     |
| AC-21 | `sprint-checkin.sh`                    | Day-5 hill chart + 3 questions (cut/push/pivot) |
| AC-22 | `sprint-hillchart.mjs`                 | Shape Up hill chart per AC                      |
| AC-23 | `sprint-standup.mjs`                   | Daily standup auto-summary                      |
| AC-24 | `sprint-pr-body.mjs`                   | Auto-fill PR body from spec + diff              |
| AC-25 | `sprint-amend-spec.sh --cut/--pivot`   | Scope reduction + redirect modes                |

### Group 4 — Leftovers (AC-26-30)

| AC    | Capability                       | Status                                                           |
| ----- | -------------------------------- | ---------------------------------------------------------------- |
| AC-26 | DAA agent create + drain queue   | `<BRAND_SLUG>-reviewer-v1` agent + workflow lifecycle via MCP          |
| AC-27 | hive-mind consensus polling loop | 60s bounded poll for terminal state (fixed from single-poll bug) |
| AC-28 | GH addSubIssue end-to-end        | MIRROR mode auth + GraphQL verified                              |
| AC-29 | audit-semantic wiring            | `scripts/sprint-system-audit.sh` wired into verify.yaml          |
| AC-30 | audit-syntactic wiring           | `scripts/sprint-system-test.sh` wired into verify.yaml           |

### Group 5 — Wizard layer (AC-31-35)

| AC    | Component                     | Purpose                                                                                |
| ----- | ----------------------------- | -------------------------------------------------------------------------------------- |
| AC-31 | `sprint-spec-wizard.mjs`      | Orchestrator: section progression + recall augmentation                                |
| AC-32 | `sprint-wizard-context.mjs`   | grep + graphify god-nodes + Serena symbol augmentation                                 |
| AC-33 | `sprint-wizard-coherence.mjs` | Cross-section contradiction detection                                                  |
| AC-34 | `sprint-wizard-assemble.mjs`  | partial.json → spec.md rendering                                                       |
| AC-35 | 10 section skills A-J         | Discovery prompts (vision/business/data/api/ui/ux/design/integration/acceptance/risks) |

### Group 6 — Drift control (AC-36-40)

| AC    | Component                          | What it does                                                                      |
| ----- | ---------------------------------- | --------------------------------------------------------------------------------- |
| AC-36 | `sprint-drift-check.sh`            | Pre-commit drift score check (paused-sprint skip)                                 |
| AC-37 | `sprint-drift-score.mjs`           | Cosine similarity score computation                                               |
| AC-38 | `.claude/helpers/sprint-hook.cjs`  | Drift + scope + forbidden enforcement (live evidence: fired 6+ times this sprint) |
| AC-39 | PreToolUse Bash forbidden-actions  | Blocks `git push`, `pulumi up`, `rm -rf`, raw `DELETE FROM`                       |
| AC-40 | PreToolUse Write/Edit out-of-scope | Blocks file edits not in spec.files_touched                                       |

### Group 7 — Husky chain (AC-41-44)

| AC    | Hook                 | Purpose                                                         |
| ----- | -------------------- | --------------------------------------------------------------- |
| AC-41 | `.husky/pre-commit`  | Drift check + duplication (>50% jscpd) BLOCK                    |
| AC-42 | `.husky/post-commit` | AUDIT_LOCK + nohup-detached reuse audit (prevents 7GB RAM leak) |
| AC-43 | `.husky/pre-push`    | Review-gate via `sprint-pre-merge-gate.sh`                      |
| AC-44 | `.husky/post-merge`  | DAA reviewer feedback queue (main-branch only)                  |

### Group 8 — Build orchestration (AC-45-49)

| AC    | Component                      | Purpose                                                                           |
| ----- | ------------------------------ | --------------------------------------------------------------------------------- |
| AC-45 | 8-agent swarm spawn            | `swarm_init` hierarchical-mesh, persisted state                                   |
| AC-46 | `claims_grant` per-domain      | Issue → agent claim tracking                                                      |
| AC-47 | stream-chain skill             | JSON-stream-between-agents pipeline pattern                                       |
| AC-48 | Pair-mode keyword auto-trigger | Detects auth/RLS/payment/migration/JWT/secret/delete/password/token               |
| AC-49 | 7 daemon workers               | audit, optimize, consolidate, testgaps, predict, document, map (all 100% success) |

### Group 9 — Autopilot side-cars (AC-50-52)

| AC    | Loop            | Trigger                              |
| ----- | --------------- | ------------------------------------ |
| AC-50 | `lint-fix`      | Per AC commit; max 5 iterations      |
| AC-51 | `test-backfill` | Paired with `testgaps` daemon worker |
| AC-52 | `doc-sweep`     | 5+ commits same area within 2h       |

### Group 10 — Verify skills (AC-53-56)

| AC    | Skill                                   | Wired in verify.yaml step |
| ----- | --------------------------------------- | ------------------------- |
| AC-53 | `/api-contract-validation`              | api-contract              |
| AC-54 | `/debug-rls`                            | rls-debug                 |
| AC-55 | `/module-status`                        | module-status             |
| AC-56 | `mcp__claude-flow__performance_profile` | perf-profile              |

### Group 11 — Reporting + dashboard + GH (AC-57-60)

| AC    | Component                                   | Output                                                      |
| ----- | ------------------------------------------- | ----------------------------------------------------------- |
| AC-57 | `statusline-sprint.cjs`                     | `[sprint:<slug> day N/14 phase:X gates:N drift:0.XX]`       |
| AC-58 | `sprint-dashboard.mjs`                      | `dashboard.html` with hill chart + AC list + drift timeline |
| AC-59 | `.github/workflows/sprint-pr-body.yml`      | Auto-fill PR body on PR open from `sprint/*`                |
| AC-60 | `.github/workflows/sprint-rebase-check.yml` | Warns when sprint branch >20 commits behind main            |

### Group 12 — End-to-end workflows (AC-61-62)

| AC    | Workflow                     | Past step 1                                                                                   |
| ----- | ---------------------------- | --------------------------------------------------------------------------------------------- |
| AC-61 | `<BRAND_SLUG>-deploy.yaml`         | Reaches turbo build, then halts before pulumi destructive steps                               |
| AC-62 | `<BRAND_SLUG>-sprint-cleanup.yaml` | + sprint-deadcode-delete (34 files), sprint-claude-md-check (9 stale refs), <BRAND_SLUG>-retro.yaml |

### Group 13 — Amend modes + memory (AC-63-67)

| AC    | Component                         | Purpose                                                                  |
| ----- | --------------------------------- | ------------------------------------------------------------------------ |
| AC-63 | `sprint-amend-spec.sh --add-file` | Widen scope; strict mode WHY+INTENT required                             |
| AC-64 | `sprint-amend-spec.sh --lock`     | Spec-lock gate; writes baseline                                          |
| AC-65 | `sprint-amend-spec.sh --close-ac` | Mark specific AC closed                                                  |
| AC-66 | `sprint-memory-decay.mjs`         | Age + archive low-confidence patterns (real decay: 0.9 → 0.046 verified) |
| AC-67 | `sprint-cross-pattern-audit.mjs`  | Find never-recalled patterns for pruning                                 |

### Group 14 — Docs + self-audit + search (AC-68-71)

| AC    | Component                                                | Purpose                                                                        |
| ----- | -------------------------------------------------------- | ------------------------------------------------------------------------------ |
| AC-68 | `sprint-claude-md-upgrade.mjs` + docs accuracy           | Propose CLAUDE.md updates from retro patterns (real: generated 8-pattern diff) |
| AC-69 | `sprint-system-test.sh`                                  | Syntactic harness self-audit (134 lines, real findings)                        |
| AC-70 | `sprint-system-audit.sh`                                 | Semantic harness self-audit (49/49 observable outcomes)                        |
| AC-71 | `sprint-pii-redact.sh` + `sprint-pii-redacted-search.sh` | WebSearch PII redaction (verified end-to-end against real WebSearch call)      |

---

## sprint-system-100 (closed earlier, sprint-system retro acknowledged 38/20/42 verdict)

The harness foundation: 33 ACs that introduced statusline, trajectory, composite drift baseline, audit chain, GH Projects v2 sync, AC-31 strict amendment mode, hive-mind consensus + polling, DAA reviewer agent, autopilot side-cars, knip + duplication block, deadcode-delete, perf bar enforcement, Sonar parser, migration-check, cycle-check, audit-deps, bundle-budget, c8 coverage delta, etc. Each capability built per its retro evidence; full audit happened in harness-full-coverage which exercised each via inject-catch-restore.

---

## \_audit-test-94837 (synthetic — kept for self-test fixtures)

- ✓ **AC-1** — **AC-2** `complex: true` auth keyword (used by sprint-pair-check.mjs format tests)
