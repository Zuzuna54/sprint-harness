# <BRAND_PRODUCT_NAME> Sprints

This directory holds every <BRAND_PRODUCT_NAME> sprint. One sprint = one 2-week Shape Up + SPARC cycle building one module slice end-to-end.

**Harness scale (as of 2026-05-17):** **71 harness capabilities** across **14 groups**, all proven via inject-violation-catch-restore. See [`_index/capabilities.md`](./_index/capabilities.md) for the full catalog. See [`harness-full-coverage/harness-readiness.md`](./harness-full-coverage/harness-readiness.md) for the latest readiness report.

## 📚 Documentation

| Doc                                                                                                      | For                  | When to read                                              |
| -------------------------------------------------------------------------------------------------------- | -------------------- | --------------------------------------------------------- |
| **[QUICKSTART.md](./QUICKSTART.md)**                                                                     | New users            | First sprint — 5 minute read                              |
| **[USAGE.md](./USAGE.md)**                                                                               | All users            | Full usage guide — ~25 min, cookbook included             |
| **[DEVELOPER.md](./DEVELOPER.md)**                                                                       | Extending the system | When modifying scripts/skills/hooks                       |
| **README.md** (this file)                                                                                | Reference            | Architecture + dir layout                                 |
| **[\_guides/](./_guides/)**                                                                              | Operational recipes  | When stuck — bypass cheatsheet, recovery, troubleshooting |
| **[\_index/capabilities.md](./_index/capabilities.md)**                                                  | Cross-sprint catalog | Find existing capability before proposing a duplicate     |
| **[~/.claude/plans/hazy-gathering-kettle.md](file:///Users/gio/.claude/plans/hazy-gathering-kettle.md)** | Design rationale     | Why we built it this way (36 captured decisions)          |

**Start here:** [QUICKSTART.md](./QUICKSTART.md) if you've never used the sprint system before. **Stuck mid-sprint:** [`_guides/troubleshooting.md`](./_guides/troubleshooting.md).

### `_guides/` operational recipes

| Guide                                                      | Use when                                                      |
| ---------------------------------------------------------- | ------------------------------------------------------------- |
| [bypass-cheatsheet.md](./_guides/bypass-cheatsheet.md)     | A gate is blocking you and you need the right escape hatch    |
| [state-json-recovery.md](./_guides/state-json-recovery.md) | state.json corrupted or sprint-status returns wrong sprint    |
| [extending-acs.md](./_guides/extending-acs.md)             | Adding/cutting ACs mid-sprint without breaking drift tracking |
| [troubleshooting.md](./_guides/troubleshooting.md)         | Anything else — symptom-indexed lookup                        |

---

## Directory layout

```
docs/sprints/
├── README.md                              # this file
├── _template/                             # the spec template (do not edit per-sprint)
│   └── spec.md
├── <sprint-id>/                           # one folder per sprint
│   ├── spec.md                            # the assembled spec (from wizard)
│   ├── spec.partial.json                  # wizard state — preserved for amendments
│   ├── wizard-transcript.md               # full Q&A log
│   ├── recalled-patterns.json             # which memories surfaced + which user accepted
│   ├── .baseline-embedding.json           # spec embedded at spec-lock (drift baseline)
│   ├── state.json                         # phase, day, gates passed, drift score
│   ├── hill-chart.md                      # Shape Up hill chart (markdown)
│   ├── check-in-day5.md                   # mid-cycle check-in (Shape Up hill chart update)
│   ├── design.md                          # SPARC architect output (day 2)
│   ├── standup.md                         # daily standup auto-summary
│   ├── retro.md                           # end-of-sprint retro
│   ├── metrics.json                       # velocity, drift events, AC closure rate
│   └── dashboard.html                     # local sprint dashboard (P4)
```

## Lifecycle

1. **`bash scripts/sprint-start.sh <slug>`** — creates the sprint folder, kicks off the adaptive wizard.
2. **Wizard runs** (20-40 min) — 10 sections, LLM-driven, memory-recall augmented, branching by sprint type.
3. **Review chain** — Claude generates solution sketches; architect + security-architect agents review; hive-mind consensus.
4. **Spec lock** — you sign off, `.baseline-embedding.json` written, build phase begins.
5. **SPARC design phase** (days 1-2) — design lock after your approval.
6. **Build phase** (days 3-11) — 8-agent swarm, claims, autopilot side-cars, pair-mode on complex ACs.
7. **Day-5 check-in** — `bash scripts/sprint-checkin.sh`, hill chart updated, 3 questions.
8. **Verify** (day 11-12) — `/api-contract-validation`, `/debug-rls`, `/module-status`, perf profile.
9. **Pre-deploy review** (day 12) — reviewer + security agents.
10. **Deploy** (day 13) — `<BRAND_SLUG>-deploy` workflow with human-approval gate.
11. **`bash scripts/sprint-end.sh <slug>`** — retro, pattern extraction, CLAUDE.md sync, trajectory close.

## Sprint state machine

```
spec-wizard → spec-locked → design-locked → building → mid-checkin → building
  → verifying → pre-deploy → cleaning → pre-deploy → deploying → done

Anywhere → paused → (resume to previous phase)
```

`bash scripts/sprint-status.sh` shows current state. **AC-3 time-box check** fires a ⚠️ warning when elapsed > appetite × 1.10 with cut/extend/abort menu.

**Phase-aware reasserter predicate (AC-7):** The reasserter does not blindly re-run the last command. It reads `state.phase` and applies phase-specific logic:

- `building` phase: re-runs the most recent broken command with same args
- `verifying` / `pre-deploy` phase: re-runs the full verify/deploy gate chain from scratch
- `paused` phase: skips re-assertion (system is intentionally idle)

**Atomic write guarantee:** All state mutations go through `atomic_update_state <slug> '<jq-filter>'` (AC-3) which:

1. Acquires per-slug flock (kernel-backed on Linux, PID-noclobber on macOS)
2. Creates temp file in same directory (same-filesystem as target → atomic POSIX rename)
3. Validates jq output before rename
4. Backs up current state to `state.json.bak` before overwriting

State files are never modified in-place. A signal between step 3 and step 4 leaves the old state intact (`.bak` exists). Recovery: `recover_state_from_bak <slug>`.

**Phase additions** (post-sprint-system-100):

- `cleaning` — between verify and deploy. Runs `<BRAND_SLUG>-sprint-cleanup.yaml` (AC-24): deadcode-delete (AC-18), eslint --fix, test re-run, claude-md-autoclean (AC-26).
- `spec-locked` now optionally pauses for hive-mind two-queen consensus (AC-12) before allowing design-lock.

**Parallel-safety contracts** (2026-05-17 harness-parallel-safety-v2):

- Lock dir: `${XDG_RUNTIME_DIR:-$HOME/.cache/<BRAND_SLUG>/locks}` (0700, umask 077). Git ops serialized via `git-index.lock`. Per-slug state locks via `state-<slug>.lock`.
- Session-file: `~/.claude/sessions/<session-id>/sprint-slug` — atomic mkdir + write, stale cleanup on `phase === "done"`.
- Migration claims: `docs/sprints/<slug>/.claims/<NNNN>` — atomic mkdir, used by build orchestrator to assign AC ranges.
- Resolution chain: `--slug` → `SPRINT_SLUG_OVERRIDE` → session-file → git branch → NULL (no mtime fallback). Skips paused sprints.

## Worker integration (2026-05-19 — on-demand, sprint-protocol-driven)

ruflo daemon workers (audit/optimize/testgaps/predict/document/refactor/ultralearn/deepdive/map/consolidate) no longer fire on hardcoded 10-30 min intervals. They run ONLY at sprint-protocol checkpoints where their output is consumed by a gate or surfaced in a deliverable.

**Per-sprint quota:** ~50 min Sonnet across the 14-day cycle, vs ~9 h/day silent burn under the old scheduled model (>99% reduction). Workers shell out to `claude --print` using the operator's OAuth session — not a separate API key — so every fire counts toward Pro/Max subscription quota.

| Stage                             | Worker(s)                                                                | Gate                      |
| --------------------------------- | ------------------------------------------------------------------------ | ------------------------- |
| Day 0 `sprint-start.sh`           | `map` (local, free)                                                      | advisory                  |
| Day 1-2 `sprint-design-lock.sh`   | `ultralearn` if §B.flags.architecture, `deepdive` if complex AC keywords | advisory                  |
| Per-wave `sprint-wave-start.sh`   | `predict` (haiku)                                                        | advisory preload hints    |
| Day 5 `sprint-checkin.sh`         | `consolidate` (local, free)                                              | free; memory dedup        |
| Day 11 `sprint-cleanup-launch.sh` | `refactor` if spec mentions "refactor"                                   | advisory                  |
| Day 11-12 `sprint-verify.sh`      | `audit` + `testgaps` + `optimize`                                        | audit + testgaps BLOCKING |
| Day 14 `sprint-end.sh`            | `document` + `consolidate`                                               | doc proposals → retro.md  |

Per-sprint worker outputs land at `docs/sprints/<slug>/worker-output/<worker>.{json,md}` (git-committed audit trail). Daemon state: `RUNNING` with `Workers Enabled: 0` (warm-but-empty). Manual trigger: `ruflo daemon trigger -w <worker>`.

Full spec: [`USAGE.md` §"Worker integration"](./USAGE.md#worker-integration-on-demand-sprint-protocol-driven).

## Audit fixes (2026-05-19 ruflo CLI sweep)

Comprehensive audit of all `ruflo` invocations across the harness. 5 confirmed bugs fixed, 4 reported-as-broken items confirmed already-working:

| Fix | File                                       | Bug                                                                     | Status                      |
| --- | ------------------------------------------ | ----------------------------------------------------------------------- | --------------------------- |
| 1   | `scripts/lib/atomic-state.sh`              | Didn't forward `--arg`/`--argjson` to jq → broke 11+ callers            | CRITICAL → fixed (variadic) |
| 2   | `scripts/sprint-hive-mind-spec-lock.sh:84` | `consensus -a submit` (invalid) → `-a propose`                          | CRITICAL → fixed            |
| 3   | `scripts/sprint-drift-score.mjs:46`        | `embeddings encode --text` (invalid) → `embeddings generate -t -o json` | CRITICAL → fixed            |
| 4   | `scripts/sprint-rebaseline.sh:99`          | Same as #3 (opt-in path)                                                | HIGH → fixed                |
| 5   | `scripts/sprint-end.sh:307`                | Echo string used wrong `--type --epochs` flags                          | LOW → fixed                 |

Already-working (user reported stale info):

- `hive-mind spawn` is `-n N -r specialist` (not the deprecated `--queen --workers`)
- `sprint-daa-feedback.sh` uses `agent list` (not the deprecated `daa list`)
- `sprint-train.sh` uses `neural train -p coordination -e 50`
- `run-workflow.sh` uses `ruflo swarm init` which IS still valid

## Harness capabilities — 14 groups, 71 ACs (all Production-grade)

| Group | Range    | Theme                                                                                                                                             |
| ----- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | AC-1-15  | Verify-workflow gates (typecheck/lint/test/graphify/playbook/sonar/migration/knip/coverage-delta/audit-deps/bundle/cycle/perf/aidefence/all-pass) |
| 2     | AC-16-19 | 4 workflows (build/verify/cleanup/deploy) — invoked via `scripts/run-workflow.sh` shim                                                            |
| 3     | AC-20-25 | Pre-existing scripts (pause/resume/checkin/hillchart/standup/pr-body/amend)                                                                       |
| 4     | AC-26-30 | Sprint-system-100 leftovers (DAA, hive-mind polling, GH addSubIssue, audit wiring)                                                                |
| 5     | AC-31-35 | Wizard layer (orchestrator, context, coherence, assemble, 10 section skills)                                                                      |
| 6     | AC-36-40 | Drift control (drift-check, drift-score, sprint-hook.cjs, PreToolUse Bash/Edit)                                                                   |
| 7     | AC-41-44 | Husky chain (pre-commit, post-commit, pre-push, post-merge)                                                                                       |
| 8     | AC-45-49 | Build orchestration (8-agent swarm, claims, stream-chain, pair-mode, 7 daemon workers)                                                            |
| 9     | AC-50-52 | Autopilot side-cars (lint-fix, test-backfill, doc-sweep)                                                                                          |
| 10    | AC-53-56 | Verify skills (api-contract, debug-rls, module-status, performance_profile MCP)                                                                   |
| 11    | AC-57-60 | Reporting (statusline, dashboard, sprint-pr-body GH action, sprint-rebase-check GH action)                                                        |
| 12    | AC-61-62 | End-to-end workflows (deploy chain, cleanup chain)                                                                                                |
| 13    | AC-63-67 | Amend modes + memory (--add-file/--lock/--close-ac, memory-decay, cross-pattern audit)                                                            |
| 14    | AC-68-71 | Docs + self-audit + search (claude-md-upgrade, sprint-system-test, sprint-system-audit, **WebSearch PII redaction**)                              |

Each AC has a `proof/AC-N.md` in `docs/sprints/harness-full-coverage/proof/` documenting baseline + inject + catch + restore.

## Drift control

- **Composite drift baseline (AC-4):** `spec.md` + top-5 god-nodes + top-3 communities from `graphify-out/GRAPH_REPORT.md`, embedded at spec-lock. Includes both `spec_hash` and `graph_hash` in `.baseline-embedding.json`. Default model: Xenova/all-MiniLM-L6-v2 384-dim; BoW fallback when ruflo `memory embed` CLI unavailable.
- **Per-commit check:** `.husky/pre-commit` embeds commit message + filtered diff (lockfiles + dist/ + .next/ + snapshots excluded per AC-4), compares cosine to baseline. Below threshold (default 0.75, tunable via `SPRINT_DRIFT_THRESHOLD`) → pause and prompt.
- **Out-of-scope hook:** PreToolUse:Write|Edit checks file path against `state.files_touched[]` (parsed from `spec.md` §H Files touched at spec-lock). Outside → prompt to amend spec or block.
- **Code-duplication block (AC-17):** `.husky/pre-commit` runs jscpd on staged TS/TSX. >50% similarity → BLOCK. Bypass: `SPRINT_DUP_BYPASS=1`.
- **Post-commit reuse audit (AC-5):** `.husky/post-commit` fires `sprint-reuse-audit.sh` advisory (lockfile-guarded, atomic state writes). Result → `state.reuse_audits[]`.
- **Pair-mode auto-trigger (AC-7):** `.husky/post-commit` parses commit msg for AC-N references; if AC marked `complex:true`, prints stderr advisory + logs to `state.pair_prompts[]`.
- **Pre-push review gate (AC-13):** `.husky/pre-push` checks PR body for `reviewer:✓` + `security:✓` marks. Missing → spawn-requests queued to `state.pending_review_spawns[]`. Warn-first mode through 2026-05-24, then BLOCK.
- **Post-merge DAA feedback (AC-11):** `.husky/post-merge` fires `sprint-daa-feedback.sh`; queue to `state.pending_daa_adapts[]` for next MCP-enabled Claude session.
- **Forbidden actions during sprint:** `git push`, `pulumi up`, `pulumi destroy`, `rm -rf`, raw `DELETE FROM` blocked by PreToolUse:Bash hook (`.claude/helpers/sprint-hook.cjs`).

## Approval gates (5)

1. Spec lock (user + hive-mind consensus + architect + security-architect)
2. Design lock (user after SPARC architect output)
3. Pre-merge review (reviewer + user, per commit)
4. Day-5 check-in (you decide: stay-course / cut / pivot)
5. Pre-deploy approval (deploy workflow pauses before `pulumi up`)

## Methodology references

- [Shape Up — Basecamp](https://basecamp.com/shapeup): pitch, hill chart, fixed-time/variable-scope, betting table
- [SPARC](../ruflo-sessions/ruflo-cheatsheet.md): Specification → Pseudocode → Architecture → Refinement → Completion
- [Gherkin Given-When-Then](https://testquality.com/how-to-write-effective-gherkin-acceptance-criteria/): UI/E2E acceptance criteria format
- [INVEST](https://www.altexsoft.com/blog/acceptance-criteria-purposes-formats-and-best-practices/): backend logic acceptance criteria checklist
- **Inject-violation-catch-restore methodology** ([`scripts/sprint-inject-violation.sh`](../../scripts/sprint-inject-violation.sh)): the bar for "Production" verdict. Each capability proven against a known injected violation; file presence ≠ production.

## Capability-proof methodology

After sprint-system-100 over-claimed at 99/99 file-presence tests, this directory enforces a stricter bar:

> **A capability is "Production" only when:**
>
> 1. It runs against real code (not synthetic)
> 2. When given a known injected violation, it CATCHES the violation
> 3. When the violation is removed, it goes back to green
> 4. There's a markdown proof file documenting all three

Two-verdict policy: **Production** or **Broken-with-followup-AC**. No "Scaffolded" middle. "Presence + invocability" is not Production.

See [`harness-full-coverage/proof/`](./harness-full-coverage/proof/) for 71 worked examples.

## Companion docs

- `../ruflo-sessions/ruflo-for-<BRAND_SLUG>.md` — feature-by-feature ruflo activation map
- `../ruflo-sessions/ruflo-syllabus.md` — 23-session ruflo learning syllabus
- `/Users/gio/.claude/plans/hazy-gathering-kettle.md` — the full sprint system plan (this doc's source of truth)
