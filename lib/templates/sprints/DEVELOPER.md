# Sprint System — Developer Guide

> **For:** developers extending or maintaining the sprint system itself (not just using it for feature work).
> **Pairs with:** [`USAGE.md`](./USAGE.md) (user-facing), [`README.md`](./README.md) (architecture), [`~/.claude/plans/hazy-gathering-kettle.md`](file:///Users/gio/.claude/plans/hazy-gathering-kettle.md) (original design).

---

## System overview

Three layers, each independent enough to modify without breaking the others.

**Capability scale:** 71 ACs across 14 groups. See [`README.md`](./README.md) for the catalog and [`harness-full-coverage/harness-readiness.md`](./harness-full-coverage/harness-readiness.md) for per-AC verdicts.

```
┌────────────────────────────────────────────────────────────────────────┐
│  LAYER 1 — Skill Layer (.claude/skills/)                               │
│  ────────────────────────────────────────                              │
│  • sprint-orchestrator/SKILL.md      ← THE 14-day protocol             │
│  • sprint-spec-wizard/SKILL.md       ← adaptive wizard protocol        │
│  • sprint-spec-wizard/sections/      ← 10 per-section question banks   │
│                                                                         │
│  Plain markdown. Claude reads these. No code. Easy to edit.            │
└────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼  Claude invokes scripts per protocol
┌────────────────────────────────────────────────────────────────────────┐
│  LAYER 2 — Script Layer (scripts/sprint-*.{sh,mjs})                    │
│  ───────────────────────────────────────────                           │
│  • State management (sprint-start, sprint-status, sprint-end)          │
│  • Wizard state machine (sprint-spec-wizard.mjs + 4 helpers)           │
│  • Drift detection (sprint-drift-check, sprint-drift-score)            │
│  • Pause/resume/amend (sprint-pause, sprint-resume, sprint-amend-spec) │
│  • Phase scripts (sprint-build-launch, sprint-checkin, sprint-        │
│    cleanup-launch, sprint-hive-mind-spec-lock, sprint-pre-merge-gate)  │
│  • Reporting (sprint-standup, sprint-pr-body, sprint-dashboard,       │
│    sprint-changelog, sprint-velocity, sprint-precheck)                 │
│  • Learning (sprint-train, sprint-daa-feedback, sprint-memory-decay,  │
│    sprint-research-cache, sprint-claude-md-upgrade)                    │
│  • Code quality (sprint-deadcode-delete, sprint-test-hardening,       │
│    pre-commit-duplication, sprint-coverage-delta, sprint-cycle-check,  │
│    sprint-audit-deps, sprint-bundle-budget, sprint-reuse-audit,        │
│    sprint-perf-check, sprint-migration-check, sprint-sonar-parse)      │
│  • Mirror sync (sprint-gh-project-sync, sprint-gh-mirror)              │
│  • Self-test (sprint-smoke-validate, sprint-system-test)               │
│                                                                         │
│  51 files. Bash + Node ESM. State in JSON files.                       │
└────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼  Scripts read/write state + invoke hooks
┌────────────────────────────────────────────────────────────────────────┐
│  LAYER 3 — Hook Layer (Claude Code + Husky)                            │
│  ───────────────────────────────────────────                           │
│  • .claude/helpers/sprint-hook.cjs   ← PreToolUse enforcement          │
│  • .husky/pre-commit                 ← drift + dup BLOCK (AC-17)       │
│  • .husky/post-commit                ← pair-mode + reuse audit         │
│  •                                     (AC-5/7, lockfile-guarded)      │
│  • .husky/pre-push                   ← review gate (AC-13)             │
│  • .husky/post-merge                 ← DAA feedback queue (AC-11)      │
│  • .claude/helpers/statusline-sprint.cjs ← AC-1 statusline fragment    │
│  • .github/workflows/sprint-pr-body.yml ← PR body auto-fill            │
│                                                                         │
│  Auto-fires. Reads sprint state. Decides allow/block/log.              │
└────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼  Reads from + writes to
┌────────────────────────────────────────────────────────────────────────┐
│  LAYER 4 — State (docs/sprints/<slug>/)                                │
│  ───────────────────────────────────────                               │
│  • state.json                ← phase, gates, drift, ACs                │
│  • spec.partial.json         ← wizard state                            │
│  • spec.md                   ← THE source of truth (drift baseline)    │
│  • .baseline-embedding.json  ← drift comparison vector                 │
│  • wizard-transcript.md      ← Q&A log                                 │
│  • recalled-patterns.json    ← memory hits + acceptance                │
│  • hill-chart.md, retro.md, standup.md, metrics.json, dashboard.html   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Data flow — what happens at each gate

### Sprint-start → Wizard

```
USER          bash scripts/sprint-start.sh <slug>
SCRIPT        creates docs/sprints/<slug>/{state.json, spec.partial.json, ...}
              git checkout -b sprint/<slug>
              gh issue create
USER          tells Claude "start the spec wizard"
CLAUDE        invokes sprint-spec-wizard skill
              reads .claude/skills/sprint-spec-wizard/sections/A-vision.md
              calls memory_search for context
              asks question, records answer via:
                node scripts/sprint-spec-wizard.mjs answer <slug> A A1 '<json>'
              after each section: complete-section
              after every 3 sections: coherence check
              after §J: assemble spec.md
```

### Wizard → Spec-lock

```
CLAUDE        generates solution-sketches.md (alternatives + tradeoffs)
              spawns architect agent → architect-review.md
              spawns security-architect agent → security-review.md
              runs hive-mind consensus → consensus-spec.json
USER          reads 4 files, edits spec.md, signs off
              bash scripts/sprint-amend-spec.sh --lock
SCRIPT        calls sprint-rebaseline.sh → writes .baseline-embedding.json
              updates state.phase = spec-locked
              git commit "sprint(<slug>): spec-lock"
HOOK CHAIN    drift control now ARMED:
              - husky/pre-commit runs sprint-drift-check.sh on every commit
              - .claude/helpers/sprint-hook.cjs blocks out-of-scope edits
              - forbidden bash patterns blocked
```

### Spec-lock → Build → Verify → Deploy → Retro

```
SPARC DESIGN  /sparc:spec-pseudocode + /sparc:architect → design.md
DESIGN LOCK   user signs off → state.phase = design-locked

BUILD         bash scripts/sprint-build-launch.sh
              executes <BRAND_SLUG>-sprint-build.yaml:
                swarm_init (8 agents)
                claims_claim × 7 domains
                autopilot side-cars × 3
                trajectory-start
              per-AC loop:
                if complex AC → pair-programming DRIVER mode
                else → swarm TDD
              every commit:
                husky → sprint-drift-check.sh
                drift score logged to state.drift_events
                <0.75 → prompt; user picks amend/discard/override

DAY 5         bash scripts/sprint-checkin.sh → check-in-day5.md + hill chart
              user: cut/push/pivot

VERIFY        <BRAND_SLUG>-sprint-verify.yaml
              typecheck → lint → tests → api-contract → debug-rls
              → module-status → perf-profile → aidefence-scan

PRE-DEPLOY    reviewer agent + security-architect agent
              user signs off

DEPLOY        <BRAND_SLUG>-deploy.yaml
              bundle → pulumi preview → PAUSE → pulumi up
              → smoke → vercel deploy

RETRO         bash scripts/sprint-end.sh <slug>
              generates retro.md skeleton
              Claude proposes patterns → ruflo memory store
              CLAUDE.md updates if convention emerged
              sprint-daa-feedback.sh
              trajectory-end
              consolidate
              workers re-enable
              sprint-train.sh (gated at ≥20 trajectories)
              metrics.json
              phase = done
```

---

## State machine reference

```
Initial:        no state (no sprint)
                  │
                  ▼  bash scripts/sprint-start.sh <slug>
State:          spec-wizard
                  │
                  ▼  wizard completes
State:          spec-locked-pending-review (transient)
                  │
                  ▼  bash scripts/sprint-amend-spec.sh --lock
State:          spec-locked
                  │
                  ▼  SPARC design done; user signs off
State:          design-locked
                  │
                  ▼  bash scripts/sprint-build-launch.sh
State:          building
                  │  ┌──────────────────────────────────────┐
                  │  │  Optional during build:              │
                  │  │  • mid-checkin (day 5) — adds gate   │
                  │  │  • drift pause (any commit < 0.75)   │
                  │  │  • spec amendment — re-baselines     │
                  │  └──────────────────────────────────────┘
                  ▼  all ACs closed
State:          verifying
                  │  if any verify gate fails → revert to building
                  ▼  all verify gates pass
State:          pre-deploy
                  │
                  ▼  reviewer + security agents sign off
State:          deploying
                  │  pulumi preview → HUMAN PAUSE → pulumi up
                  ▼  smoke + vercel deploy succeed
State:          done (after sprint-end.sh retro)


Anywhere:       paused (via sprint-pause.sh)
                  │
                  ▼  bash scripts/sprint-resume.sh
                returns to state.prev_phase
```

---

## File-by-file reference

### Layer 1 — Skills (Claude's protocol)

| File                                                             | Role                      | Edit when                                                                 |
| ---------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------- |
| `.claude/skills/sprint-orchestrator/SKILL.md`                    | THE 14-day protocol       | You want to change the sequence of phases, gates, or what each phase does |
| `.claude/skills/sprint-spec-wizard/SKILL.md`                     | Wizard system prompt      | You want to change Claude's role, voice, or operating procedure           |
| `.claude/skills/sprint-spec-wizard/sections/A-vision.md`         | §A goals + question banks | You want to change problem-discovery depth                                |
| `.claude/skills/sprint-spec-wizard/sections/B-business-logic.md` | §B                        | Add/remove entity discovery, invariants                                   |
| `.claude/skills/sprint-spec-wizard/sections/C-data-schema.md`    | §C                        | RLS conventions, migration rules                                          |
| `.claude/skills/sprint-spec-wizard/sections/D-api.md`            | §D                        | Default auth, error class hierarchy                                       |
| `.claude/skills/sprint-spec-wizard/sections/E-ui.md`             | §E                        | Component conventions, state mgmt rules                                   |
| `.claude/skills/sprint-spec-wizard/sections/F-ux-flow.md`        | §F                        | Error path defaults, empty state requirements                             |
| `.claude/skills/sprint-spec-wizard/sections/G-design.md`         | §G                        | Design system, brand book references                                      |
| `.claude/skills/sprint-spec-wizard/sections/H-integration.md`    | §H                        | Module list, event patterns                                               |
| `.claude/skills/sprint-spec-wizard/sections/I-acceptance.md`     | §I                        | AC format, **complexity keywords for pair-mode**                          |
| `.claude/skills/sprint-spec-wizard/sections/J-risks.md`          | §J                        | Rollback default, security depth rules                                    |

### Layer 2 — Scripts (state management)

| Script                                | Purpose                        | Critical invariants                                        |
| ------------------------------------- | ------------------------------ | ---------------------------------------------------------- |
| `scripts/sprint-start.sh`             | Phase 0 init                   | Refuses if another sprint active; refuses if dir exists    |
| `scripts/sprint-status.sh`            | Print state                    | Used by hooks programmatically (`--slug-only`)             |
| `scripts/sprint-end.sh`               | Phase 8 close                  | Re-enables paused workers; closes GH Issue                 |
| `scripts/sprint-pause.sh`             | Suspend enforcement            | Sets prev_phase before transition                          |
| `scripts/sprint-resume.sh`            | Resume from pause              | Restores prev_phase; only acts if currently paused         |
| `scripts/sprint-amend-spec.sh`        | Spec mods + re-baseline        | `--lock` is the spec-lock gate                             |
| `scripts/sprint-checkin.sh`           | Day-5 hill chart + 3 questions | Updates state.gates_passed += mid-checkin                  |
| `scripts/sprint-build-launch.sh`      | Phase 3 kickoff                | Requires phase=design-locked                               |
| `scripts/sprint-drift-check.sh`       | Husky pre-commit               | Exit 0=allow, 1=block, 2=config error (allow)              |
| `scripts/sprint-drift-score.mjs`      | Compute cosine                 | Stdout = single float in [0,1]                             |
| `scripts/sprint-rebaseline.sh`        | Re-embed spec                  | Archives old baseline as `.baseline-embedding.day<N>.json` |
| `scripts/sprint-spec-wizard.mjs`      | Wizard state machine           | Stateless — reads/writes spec.partial.json                 |
| `scripts/sprint-wizard-context.mjs`   | Emit context bundle            | JSON output for Claude to consume                          |
| `scripts/sprint-wizard-coherence.mjs` | Coherence checks               | Emits known contradiction patterns                         |
| `scripts/sprint-wizard-assemble.mjs`  | Render spec.md                 | `--partial` allows incomplete                              |
| `scripts/sprint-hillchart.mjs`        | Generate hill chart            | `--refresh` writes to hill-chart.md                        |
| `scripts/sprint-pair-check.mjs`       | Scan ACs for complex keywords  | `--json` for programmatic use                              |
| `scripts/sprint-standup.mjs`          | Daily standup entry            | Appends to standup.md                                      |
| `scripts/sprint-pr-body.mjs`          | PR body from spec              | `--pr <num>` updates via gh                                |
| `scripts/sprint-dashboard.mjs`        | Local HTML dashboard           | Auto-refresh meta tag (60s)                                |
| `scripts/sprint-gh-project-sync.sh`   | GH Project board               | Best-effort; skips if no gh auth                           |
| `scripts/sprint-train.sh`             | Gated neural training          | `--force` bypasses ≥20 trajectory gate                     |
| `scripts/sprint-daa-feedback.sh`      | DAA reviewer feedback batch    | Creates <BRAND_SLUG>-reviewer-v1 on first run                    |
| `scripts/sprint-velocity.mjs`         | Compute metrics.json           | 4 success criteria: ACs/appetite/drift/design-lock         |

### Layer 3 — Hooks (enforcement)

| File                                    | Trigger                           | What it does                                                  |
| --------------------------------------- | --------------------------------- | ------------------------------------------------------------- |
| `.husky/pre-commit`                     | Every `git commit`                | Runs `sprint-drift-check.sh` (if active sprint with baseline) |
| `.claude/helpers/sprint-hook.cjs`       | PreToolUse:Bash                   | Blocks forbidden bash patterns                                |
| `.claude/helpers/sprint-hook.cjs`       | PreToolUse:Write\|Edit\|MultiEdit | Blocks out-of-scope file edits                                |
| `.claude/helpers/statusline-sprint.cjs` | Statusline render                 | Emits compact fragment when sprint active                     |
| `.github/workflows/sprint-pr-body.yml`  | PR open on `sprint/*`             | Auto-fills PR body from spec                                  |

### Layer 4 — Workflows (orchestration)

| File                                       | Phase | Steps                                                                                          |
| ------------------------------------------ | ----- | ---------------------------------------------------------------------------------------------- |
| `docs/workflows/<BRAND_SLUG>-sprint-build.yaml`  | 3     | swarm_init → claims × 7 → autopilot × 3 → trajectory-start                                     |
| `docs/workflows/<BRAND_SLUG>-sprint-verify.yaml` | 5     | typecheck → lint → test → api-contract → debug-rls → module-status → perf → aidefence          |
| `docs/workflows/<BRAND_SLUG>-deploy.yaml`        | 7     | bundle → preview → **HUMAN PAUSE** → pulumi up → smoke → vercel                                |
| `docs/workflows/<BRAND_SLUG>-retro.yaml`         | 8     | velocity → retro → patterns → CLAUDE.md → DAA → trajectory-end → consolidate → workers → train |

### Layer 4 — Autopilot configs

| File                                        | Trigger                       | Side-car role                                      |
| ------------------------------------------- | ----------------------------- | -------------------------------------------------- |
| `.claude-flow/autopilot/lint-fix.json`      | Manual / per AC               | `pnpm lint:fix`, 5 iterations max                  |
| `.claude-flow/autopilot/test-backfill.json` | Paired with `testgaps` worker | Generate happy + auth-fail + validation-fail tests |
| `.claude-flow/autopilot/doc-sweep.json`     | 5+ commits same area / 2h     | Propose CLAUDE.md + JSDoc updates (NO auto-commit) |

---

## State file shapes

### `docs/sprints/<slug>/state.json`

```json
{
  "slug": "supplements-compliance",
  "phase": "building",
  "started_at": "2026-05-17T08:00:00Z",
  "started_at_epoch": 1747468800,
  "day": 5,
  "appetite_days": 14,
  "appetite_seconds": 1209600,
  "gates_passed": ["spec-lock", "design-lock", "mid-checkin"],
  "gate_history": [{ "gate": "spec-lock", "status": "passed", "at": "..." }],
  "gates_skipped": [],
  "acs_total": 5,
  "acs_closed": 2,
  "acs_in_progress": ["AC-3"],
  "acs_closed_ids": ["AC-1", "AC-2"],
  "acs_closed_at": {
    "AC-1": "2026-05-19T14:23:11Z",
    "AC-2": "2026-05-20T09:12:00Z"
  },
  "trajectory_id": "task-mp9nwdvj",
  "drift_score_latest": 0.81,
  "drift_events": [
    { "at": "2026-05-19T10:00:00Z", "score": 0.82, "msg": "AC-1: add Lambda route" }
  ],
  "pause_events": [],
  "scope_amendments": [
    {
      "at": "2026-05-20T08:00:00Z",
      "action": "add-file",
      "path": "apps/web/hooks/useCompliance.ts",
      "why": "Day-5 discovery: need a shared hook to power both Widget and detail page",
      "intent": "Single source for compliance % calc; reuse across surfaces",
      "scope_impact": "files_added: apps/web/hooks/useCompliance.ts",
      "acs_affected": "AC-3",
      "alternatives_considered": "Could inline in Widget, but detail page needs same calc",
      "decided_by": "user"
    }
  ],
  "files_touched": ["apps/lambdas/.../getCompliance.ts", "..."],
  "reuse_audits": [{ "at": "...", "report_path": "...", "dup_count": 0, "status": "clean" }],
  "pair_prompts": [{ "at": "...", "ac": "AC-3", "commit": "<sha>", "action": "stderr-advisory" }],
  "gate_bypasses": [{ "at": "...", "gate": "pre-merge-review" }],
  "pending_daa_adapts": [
    { "at": "...", "agent_id": "<BRAND_SLUG>-reviewer-v1", "feedback_path": "...", "applied": false }
  ],
  "pending_review_spawns": [
    { "at": "...", "pr_number": "42", "agent_type": "security-architect", "applied": false }
  ],
  "consensus": [
    {
      "proposal_id": "...",
      "proposal_sha": "<sha>",
      "hive_id": "hive-...",
      "outcome": "pending",
      "queens": ["strategic", "tactical"]
    }
  ],
  "workflow_runs": [],
  "autopilot_log": [],
  "wizard_state": {
    "current_section": "complete",
    "sections_status": { "A": "complete", "B": "complete" }
  },
  "git_branch": "sprint/supplements-compliance",
  "github_issue": "https://github.com/.../issues/123",
  "github_project": 42,
  "prev_phase": null,
  "abandoned_permanent": false,
  "closed_at": null
}
```

**New fields introduced by sprint-system-100:**

- `gate_history[]` / `gates_skipped[]` (AC-6) — intentional-skip tracking for success criteria
- `trajectory_id` (AC-2) — ruflo task-id from `pre-task` for trajectory accumulation
- `reuse_audits[]` (AC-5) — every post-commit reuse audit lands here
- `pair_prompts[]` (AC-7) — every complex-AC commit gets a stderr advisory entry
- `gate_bypasses[]` (multiple ACs) — every `SPRINT_*_BYPASS=1` invocation logged
- `pending_daa_adapts[]` (AC-11) — DAA reviewer adapt queue (Claude drains in MCP session)
- `pending_review_spawns[]` (AC-13) — reviewer/security-architect agent spawn queue
- `consensus[]` (AC-12) — hive-mind two-queen Raft outcome per spec-lock
- `workflow_runs[]` (AC-15) — verify/deploy/cleanup/retro workflow execution history
- `scope_amendments[].why/intent/scope_impact/alternatives_considered/decided_by` (AC-31) — structured amendment metadata, no more silent "(not provided)"
- `abandoned_permanent` — phantom-sprint marker (see `_guides/troubleshooting.md`)

**Adjacent files in sprint dir:**

- `systems-health.json` (AC-33) — precheck snapshot
- `claude-md-proposed-diff.patch` (AC-8) — CLAUDE.md additions
- `reuse-audit.json` + `.log` (AC-5) — jscpd output
- `deadcode-deletions.json` (AC-18) — knip + agent verify output
- `test-hardening.csv` + `.json` (AC-19) — route-coverage report
- `gh-mirror.json` (AC-32) — Epic + sub-issue ID map
- `full-system-test.md` + `smoke-validation.json` (AC-16) — closeout artifacts
- `CHANGELOG.md` (AC-30) — per-sprint capability log
- `handoffs/<layer>.md` (AC-20) — per-layer HANDOFF for integration-reviewer
- `integration-review.md` (AC-20) — cross-layer fit verdict
- `coverage-current.json` (AC-25) — lcov snapshot for next sprint's delta
- `daa-feedback.json` (AC-11) — DAA reviewer payload

**Transient lock files** (atomic-write coordinators, never committed):

- `state.json.lock` — held by writer; reclaimed if stale (>30s)
- `.reuse-audit.lock` — held by post-commit audit PID; AC-5 lockfile guard

### `docs/sprints/<slug>/spec.partial.json`

```json
{
  "slug": "supplements-compliance",
  "started_at": "2026-05-17T08:00:00Z",
  "current_section": "complete",
  "sections_status": {
    "A": "complete", "B": "complete", "C": "complete",
    "D": "complete", "E": "complete", "F": "complete",
    "G": "skipped",  "H": "complete", "I": "complete", "J": "complete"
  },
  "sections_answers": {
    "A": {
      "A1": "Users don't see compliance %...",
      "A2": "Early-users post-onboarding",
      "A3": "Zefyra dropped stack day 4",
      "A4": "Tactical fix",
      "A5": "User sees today's checklist + %",
      "flags": {
        "backend_only": false,
        "frontend_only": false,
        "pure_refactor": false,
        "no_schema_change": false,
        "no_ui": false,
        "strategic": false
      },
      "refinement": "Edge: partial completion (3 of 5)..."
    },
    "B": { ... }
  },
  "recalled_patterns": [
    { "key": "<BRAND_SLUG>-rls-4-policy-template", "section": "C", "accepted": true, "score": 0.72 },
    { "key": "frontend-hook-pattern", "section": "E", "accepted": true, "score": 0.61 }
  ],
  "codebase_refs": [
    { "section": "D", "files": ["apps/lambdas/supplements-lambda/src/manifest.ts"] }
  ],
  "coherence_checks": [
    { "after_section": "C", "passed": true, "notes": "no contradictions", "at": "2026-05-17T08:30:00Z" },
    { "after_section": "F", "passed": false, "notes": "fixed: A1 said no UI but E1 listed pages", "at": "..." }
  ],
  "skip_reasons": {
    "G": "Following <BRAND_NAME> brand book — no design questions needed"
  }
}
```

### `.baseline-embedding.json`

```json
{
  "model": "Xenova/all-MiniLM-L6-v2",
  "dim": 384,
  "embedded_at": "2026-05-17T12:00:00Z",
  "spec_hash": "abc123...",
  "embedding": [0.123, -0.456, ...]
}
```

Or in BoW fallback mode:

```json
{
  "model": "fallback-bow",
  "dim": 0,
  "embedded_at": "2026-05-17T12:00:00Z",
  "spec_hash": "abc123...",
  "text": "<full spec.md content>",
  "embedding": []
}
```

---

## Extending the system

### Adding a new wizard section

1. Create `.claude/skills/sprint-spec-wizard/sections/K-newthing.md` (follow the existing template — Discovery goals, Typical question shape, Conditional follow-ups, Output flags, Recall targets, Style guidance)
2. Add `K` to `SECTIONS` array in `scripts/sprint-spec-wizard.mjs`
3. Add to `sectionNameFor()` map: `K: "newthing"`
4. Add to `decideSkip()` if conditional
5. Add to spec template at `docs/sprints/_template/spec.md` — new `## §K — New Thing` heading
6. Add to `scripts/sprint-wizard-assemble.mjs` — pull `K` answers, render section
7. Update `.claude/skills/sprint-spec-wizard/SKILL.md` table

### Adding a new gate

1. Update `.claude/skills/sprint-orchestrator/SKILL.md` — add phase + actions + verification
2. Create `scripts/sprint-<gate-name>.sh` — implement the gate logic
3. Update state machine in `docs/sprints/README.md`
4. Add a new entry to `state.gates_passed` semantics
5. If automated workflow needed: create `docs/workflows/<BRAND_SLUG>-<gate>.yaml`

### Adding a new harness capability (Production-grade)

Bar: a capability is Production only when proven via inject-violation-catch-restore. Procedure:

1. Build the gate/script/hook as usual
2. Create a violation fixture in `scripts/violation-fixtures/<name>.patch` (use `git diff` against a real injection)
3. Run `scripts/sprint-inject-violation.sh <fixture-name> "<gate command>"` with env vars:
   - `PROOF_FILE=docs/sprints/<slug>/proof/AC-N.md`
   - `AC_ID=AC-N`
   - `GATE_NAME="<gate name>"`
   - `ASSERT_PATTERN="<output substring matched on catch>"`
4. Helper writes the proof file documenting baseline + injected + restore phases + verdict
5. Add to `scripts/sprint-harness-readiness.mjs` aggregator output (automatic when proof file exists)
6. Re-run `node scripts/sprint-harness-readiness.mjs <slug>` to update readiness report

**Two-verdict policy:** Production or Broken-with-followup-AC. Do not introduce middle-bucket verdicts like "Scaffolded."

### Bug patterns to watch for (codified)

These are the recurring traps caught by harness-full-coverage. When extending the system, check for them:

| Pattern                             | Symptom                                                                   | Fix                                                            |
| ----------------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `<BRAND_SLUG>-args-indexof-trap`          | `args[args.indexOf("--x") + 1]` returns `args[0]` (slug) when flag absent | Guard with `argAfter()` helper: `i >= 0 ? args[i+1] : default` |
| `<BRAND_SLUG>-grep-pattern-whitespace`    | grep `"key":"val"` misses JSON output `"key": "val"` (with space)         | Use `[[:space:]]*` or jq                                       |
| `<BRAND_SLUG>-pipe-rc-trap`               | `cmd \| tail; rc=$?` captures tail's exit, not cmd's                      | Use `${PIPESTATUS[0]}` or redirect to file then test           |
| `<BRAND_SLUG>-exit-vs-summary-divergence` | `console.log("FAIL")` + `process.exit(0)` — silent bug                    | Always tie exit to summary boolean                             |
| `<BRAND_SLUG>-pnpm-dlx-flag-trap`         | `pnpm dlx -y <pkg>` invalid; `-y` not in pnpm dlx                         | Drop the `-y` (npm-ism)                                        |
| `<BRAND_SLUG>-shim-when-upstream-broken`  | Upstream gap (ruflo #1916, ESLint config, etc.)                           | Own the chain — build a small shim                             |
| `<BRAND_SLUG>-spec-narrowing-trap`        | Wizard converts broad "full coverage" intent → narrow AC list             | At spec-lock, cross-check final §I against original ask        |
| `<BRAND_SLUG>-only-two-verdicts`          | Tempted to introduce "Scaffolded"/"Partial" middle                        | Production or Broken-with-followup-AC. No middle.              |
| `<BRAND_SLUG>-presence-isnt-production`   | "File exists + script runs + returns something" called Production         | Bar is observable catch on real injection, not "didn't crash"  |

### Adding a new forbidden action

Edit `.claude/helpers/sprint-hook.cjs`:

```javascript
const FORBIDDEN_PATTERNS = [
  /\bgit\s+push\b/i,
  /\bpulumi\s+up\b/i,
  // ... existing patterns
  /your-new-pattern/i, // ← add here
]
```

Also add to husky pre-commit if it's a shell-level concern.

### Adding a new autopilot side-car

1. Create `.claude-flow/autopilot/<name>.json` (follow lint-fix.json shape)
2. Add to `docs/workflows/<BRAND_SLUG>-sprint-build.yaml` → `autopilot-sidecars` step → `branches`
3. Document in `.claude/skills/sprint-orchestrator/SKILL.md` Phase 3 actions

### Changing the drift threshold default

Two options:

1. **Per-sprint:** set `SPRINT_DRIFT_THRESHOLD` env var
2. **Global default:** edit `scripts/sprint-drift-check.sh` line `THRESHOLD="${SPRINT_DRIFT_THRESHOLD:-0.75}"`

### Replacing the embedding model

Edit `scripts/sprint-drift-score.mjs`:

- `tryRufloEmbedding()` — shells out to `ruflo memory embed`; replace if you want a different model
- `bowVector()` / `bowCosine()` — fallback. Replace with transformers.js inline if you want semantic fallback without ruflo dependency.

Update `.baseline-embedding.json` schema accordingly.

### Adding a new metric to velocity

Edit `scripts/sprint-velocity.mjs`. Add to:

1. Computation block (read from state.json)
2. `metrics` object
3. `success_criteria` if it's a pass/fail criterion
4. Human-readable output (the `else` branch printing)

---

## Testing changes

### Smoke test the whole system end-to-end

```bash
# 1. Validate JSON configs
for f in .claude/settings.json .claude-flow/autopilot/*.json; do
  node -e "JSON.parse(require('fs').readFileSync('$f'))" && echo "✓ $f"
done

# 2. Run sprint-start, verify state.json shape
bash scripts/sprint-start.sh smoke-test --no-branch --no-issue
node -e "
  const s = require('./docs/sprints/smoke-test/state.json');
  if (s.phase !== 'spec-wizard') throw new Error('wrong phase');
  if (s.day !== 0) throw new Error('wrong day');
  console.log('✓ state.json shape correct');
"

# 3. Wizard state
node scripts/sprint-spec-wizard.mjs status smoke-test

# 4. Emit section A (should be skip:false)
node scripts/sprint-spec-wizard.mjs section smoke-test A

# 5. Record an answer
node scripts/sprint-spec-wizard.mjs answer smoke-test A A1 '"test problem"'

# 6. Partial assemble
node scripts/sprint-wizard-assemble.mjs smoke-test --partial --dry-run

# 7. Hill chart, pair check, velocity
node scripts/sprint-hillchart.mjs smoke-test
node scripts/sprint-pair-check.mjs smoke-test || true  # expected fail w/o spec
node scripts/sprint-velocity.mjs smoke-test

# 8. Dashboard
node scripts/sprint-dashboard.mjs smoke-test
test -f docs/sprints/smoke-test/dashboard.html

# 9. Hook (no active sprint — should fall through with exit 0)
echo '{}' | node .claude/helpers/sprint-hook.cjs pre-bash
echo "exit=$?"

# 10. Cleanup
rm -rf docs/sprints/smoke-test
```

All steps should succeed without manual intervention.

### Test the drift hook standalone

```bash
# Create a fake baseline + signal
mkdir -p /tmp/drift-test
cat > /tmp/drift-test/baseline.json <<EOF
{"model":"fallback-bow","dim":0,"text":"spec about lambda RLS soft-delete","embedding":[]}
EOF
echo "implementing lambda RLS policies for soft delete" > /tmp/drift-test/good.txt
echo "refactoring unrelated payment processing webhooks" > /tmp/drift-test/bad.txt

# Good commit should score high
node scripts/sprint-drift-score.mjs /tmp/drift-test/baseline.json /tmp/drift-test/good.txt
# Expected: ~0.7+

# Bad commit should score low
node scripts/sprint-drift-score.mjs /tmp/drift-test/baseline.json /tmp/drift-test/bad.txt
# Expected: ~0.0-0.3

rm -rf /tmp/drift-test
```

---

## Design rationale (why we built it this way)

> **Source:** `~/.claude/plans/hazy-gathering-kettle.md` — full plan with 36 captured decisions across 9 question rounds.

### Why Shape Up + SPARC hybrid?

- **Shape Up** gives anti-drift by construction (fixed time, variable scope, hill chart, no-goes). Pitched at solo founders.
- **SPARC** gives internal cadence (Specification → Pseudocode → Architecture → Refinement → Completion) and already exists as a ruflo skill.
- The pitch is the OUTER shell; SPARC is the INNER build cadence.

### Why 2 weeks?

Compromise between Shape Up's 6-week default (too long for solo dev iteration) and 1-week sprints (too little time for real module slices). Tunable per sprint via wizard A3.

### Why adaptive wizard, not static form?

A flat form re-asks decisions that are already captured in the plan doc (Shape Up cycle length, drift threshold, methodology). The adaptive wizard:

- Skips sections that don't apply (backend-only → no UI questions)
- Pre-fills defaults from recalled memory (RLS template, soft-delete pattern)
- Branches by sprint type (refactor vs new feature vs UI tweak)
- Loops on vague answers (refuses to advance §A until "why now" has signal)

### Why drift score 0.75?

[2026 research](https://stackpulsar.com/blog/llm-model-drift-detection/) finds 0.75 cosine similarity is industry baseline for paraphrase acceptance. Stricter (0.82) produces too many false pauses; looser (0.65) misses subtle drift. Tunable; expected to converge after 3 sprints of data.

### Why husky pre-commit + Claude Code hooks?

Two layers, two surfaces:

- **Husky** catches commits done at the git CLI (you, manually, or scripts)
- **Claude Code hooks** catches tool calls Claude makes (Bash, Write, Edit)

Together: no path around drift control without explicit `SPRINT_DRIFT_BYPASS=1`.

### Why all 4 spec-lock reviews?

Each catches a different failure mode:

- **Solution sketches** — surface alternatives you didn't consider
- **Architect** — catch structural bad ideas before you build them
- **Security** — catch RLS/auth gaps; <BRAND_SLUG_TITLE> specific
- **Hive-mind consensus** — catch incoherent scope (e.g., backend module but UI-heavy ACs)

### Why pair-mode on complex ACs?

Keyword detection (auth, RLS, payment, migration, JWT, secret, delete) flags high-risk surfaces. Pair-programming DRIVER mode adds:

- Real-time verification (truth score ≥ 0.95)
- Continuous code review
- Security scan per commit

Cheaper than catching the bug in prod.

### Why retro extracts patterns?

After 20+ sprints, the patterns store has enough density that:

- Memory recall finds the right past pattern with high score
- Neural training can learn coordination patterns specific to <BRAND_SLUG_TITLE>
- DAA reviewer matches your bar

Each pattern stored is compounded value across all future sprints.

---

## What we didn't build (out of scope, deferred)

These were in the original plan but explicitly deferred:

- **Multi-sprint concurrency** — current system assumes one active sprint per worktree
- **Cross-machine federation / WireGuard mesh** — solo dev
- **Hosted UI** (flo.ruv.io, goal.ruv.io)
- **Custom ruflo plugin** (`ruflo-<BRAND_SLUG>-conventions`) — write after 5+ sprints
- **Slack / email reporting**
- **Linear / Notion integration**
- **Pinning ruflo version** — `@latest` keeps current
- **Adaptive drift threshold via SONA** — manual tuning for first 3 sprints
- **Real-time dashboard auto-refresh via WebSocket** — uses meta refresh tag instead

Add any of these by following the "Extending the system" patterns above.

---

## Known limitations

> These 7 gaps were re-confirmed in the 2026-05-17 P5 QA audit (gaps #28-34). All upstream / by-design / environment-dependent — not addressable locally.

1. **7 of 12 daemon workers implemented in v3.7.0-alpha.42** _(gap #28)_ — `ultralearn`, `deepdive`, `refactor` (during sprint paused), `benchmark`, `preload` are config-only. No workaround until ruflo ships them.

2. **Hive-mind consensus is single-process** _(gap #29)_ (per ADR-095 G2) — for true multi-host consensus, federation plugin required.

3. **`gh project` commands vary by gh version** _(gap #30)_ — `sprint-gh-project-sync.sh` is best-effort. May need updates as gh CLI evolves.

4. **Drift score with no ruflo daemon = BoW fallback** _(gap #31)_ — less semantic. Symptoms: false-positive pauses on synonym-heavy diffs.

5. **Coherence checks are advisory** _(gap #32)_ — Claude reports contradictions, user resolves. No auto-veto.

6. **`pulumi-preview` pause in deploy workflow requires manual response** _(gap #33)_ — workflow runner needs to support `type: pause`. If ruflo CLI doesn't support pause/resume yet, run preview + up as separate commands.

7. **Skill discovery cap** _(gap #34)_ — `skillListingBudgetFraction: 0.06` in settings.json prevents truncation, but ~169 skills may still hit limits with rapid additions.

### P5 closed 25 of 34 audit gaps

For audit history + design rationale on what P5 changed, see [`~/.claude/plans/hazy-gathering-kettle.md`](file:///Users/gio/.claude/plans/hazy-gathering-kettle.md) "## P5 — QA Hardening" section. Sub-phases P5a-d shipped tools/scripts addressing gaps #1-27; this section (P5e) documents the 7 gaps that remain by design.

### Harness-full-coverage additions (2026-05-17)

Expanded capability coverage from 33 → 71 ACs. New tooling:

| File                                    | Role                        | Why                                                                                                                             |
| --------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/sprint-inject-violation.sh`    | Inject-catch-restore helper | Standard pattern for proving any gate Production-ready                                                                          |
| `scripts/violation-fixtures/`           | Per-gate injection patches  | Reusable fixtures (cycle-import.patch, typecheck-bad-type.patch, ...)                                                           |
| `scripts/run-workflow.sh`               | YAML workflow runner        | Ruflo #1916 doesn't decompose YAML `steps:` arrays; this shim parses + executes step-by-step with `on_failure: pause` semantics |
| `scripts/sprint-lint-check.sh`          | ESLint shim                 | Workspace lint surface broken (only apps/web has lint, interactive); shim runs ESLint directly with inline rules                |
| `scripts/sprint-pii-redact.sh`          | PII pattern redactor        | Strips 6 PII pattern classes (email, UUID, JWT, API key, password=, postgresql://)                                              |
| `scripts/sprint-pii-redacted-search.sh` | Redact-then-search wrapper  | Demonstrates the end-to-end chain for WebSearch                                                                                 |
| `scripts/sprint-harness-readiness.mjs`  | Per-AC verdict aggregator   | Reads `proof/AC-N.md` files, writes `harness-readiness.md` with counts                                                          |

12 inline bug fixes shipped this sprint (≤20 LOC each per §J #3 policy):

1. cycle-check: `pnpm dlx -y` flag, grep parse, restore-dirty whole-tree
2. migration-check: wrong path `schemas/` vs `schema/`, missed working-tree
3. knip.json: invalid `_comment` JSON key
4. audit-deps: grep missed `"severity": "high"` (space)
5. sonar-parse: args[indexOf+1] returned slug as URL
6. hive-mind: single poll, no terminal-state loop

---

## Where to read next

- [`USAGE.md`](./USAGE.md) — user-facing usage guide (this doc's user counterpart)
- [`QUICKSTART.md`](./QUICKSTART.md) — 5-minute first-sprint walkthrough
- [`README.md`](./README.md) — architecture + dir layout
- [`~/.claude/plans/hazy-gathering-kettle.md`](file:///Users/gio/.claude/plans/hazy-gathering-kettle.md) — original design with 36 decisions
- [`../ruflo-sessions/ruflo-for-<BRAND_SLUG>.md`](../ruflo-sessions/ruflo-for-<BRAND_SLUG>.md) — full ruflo feature reference
- [`../ruflo-sessions/ruflo-syllabus.md`](../ruflo-sessions/ruflo-syllabus.md) — 23-session ruflo learning syllabus

---

## License + maintenance

This sprint system is part of <BRAND_SLUG_TITLE>. MIT licensed (<BRAND_SLUG_TITLE> default). Edit freely. PRs welcome at the SKILL.md and section markdown level — those have the highest ROI per change. Lower layers (scripts, hooks) require more care.

**Last refreshed:** 2026-05-17
