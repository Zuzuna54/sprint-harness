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

## Terminology contract

> **Why this section exists** (architect ship-gate C3). Three doc audits surfaced the same root cause: the same concept was defined in two or three places with subtle differences, so an LLM reading the docs could not pick a canonical meaning. This section enforces **define-ONCE-and-link**: each load-bearing term is defined in exactly one place (the _canonical home_), and every other mention is a markdown link to that anchor. `scripts/check-terminology.sh` greps for the `^### <Term>` definition pattern outside its owner and fails on duplicates.
>
> Each definition below names: (a) one-paragraph meaning, (b) canonical home (the file that owns the definition), (c) **grep-anchor** — a string that should only appear in the canonical home, never repeated elsewhere. Linting greps for the anchor to mechanize "is this concept documented in two places?".

### Phase

A named state in the 13-step state machine (v0.7.3+) that a sprint walks through: `spec-wizard`, `spec-locked`, `design-locked`, `building`, `day-5-checkin`, `cleaning`, `verifying`, `audit-resolution`, `review-resolution`, `pre-deploy`, `deploying`, `done`, `paused`. (Pre-v0.7.2: 11 phases; `audit-resolution` added in `harness-audit-resolution-and-scope-v1`; `review-resolution` added in `harness-review-resolution-v1` as the unified superset that walks audit + knip + sonar findings — `audit-resolution` retained as a legacy alias.) Each phase has required artifacts, required state fields, and required sub-step gates declared in `scripts/lib/phase-manifest.json`. `state.phase` is written **only** by `scripts/sprint-advance-phase.sh`; every other phase-writer (`sprint-amend-spec.sh --lock`, `sprint-build-launch.sh`, `sprint-audit-resolve.sh`, `sprint-review-resolve.sh`, etc.) delegates to it. The PreToolUse hook (`.claude/helpers/sprint-hook.cjs`) blocks any other path.

- **Canonical home:** this section (`DEVELOPER.md` §"Terminology contract" → `### Phase`).
- **Grep-anchor:** `phase-term-canonical-DEV-A1`.

### Sub-step gate

A step within a phase that must complete before phase advance. Each is a stable kebab-case name (e.g., `wizard-section-A`, `verify-typecheck`, `retro-pattern-1`) declared in `phase-manifest.json` under `required_sub_step_gates[]` or `strict_only_sub_step_gates[]`. Recorded at the producing call-site via `scripts/lib/sub-step.sh::record_sub_step <slug> <gate> <status> [evidence_path]`. The hybrid START+END schema (ADR-004) writes `status: "running"` on `--start` and overwrites with `passed`|`failed` + `elapsed_s` on `--end`. The predicate engine in `scripts/lib/phase-predicates.sh` evaluates whether a gate is satisfied; bypasses are recorded under `state.gate_bypasses[]`.

- **Canonical home:** this section → `### Sub-step gate`. Coverage map (which call-site instruments each gate) lives in [`_guides/sub-step-coverage.md`](./_guides/sub-step-coverage.md).
- **Grep-anchor:** `sub-step-term-canonical-DEV-A2`.

### Worker

A general-purpose label for "a process that does work on behalf of the sprint." The label is overloaded — there are **three distinct subtypes**, and conflating them is the audit's root finding. Read [`USAGE.md` §3 — Worker architecture](./USAGE.md#3--worker-architecture) for the full trigger / output / state-recording table.

- **Daemon worker** — long-running, LLM-backed (or local), managed by `ruflo daemon`. 10 types (`map`, `predict`, `audit`, `testgaps`, `optimize`, `consolidate`, `document`, `refactor`, `deepdive`, `ultralearn`). Fired by `sprint-advance-phase.sh` via `scripts/lib/worker-trigger.sh`, driven by `scripts/lib/phase-workers.json`. Output: `.claude-flow/metrics/<w>.json` → `docs/sprints/<slug>/worker-output/<w>.json`. State: `worker_runs[]` (W2 schema) + `worker_invocations[]` (legacy). *(Note: In OpenCode environments, daemon triggers gracefully yield to the active OpenCode agent via stderr instructions rather than requiring a background daemon).*
- **Task sub-agent** — spawned by the `sprint-orchestrator` skill via the Claude Task tool at spec-lock (Day ½) and pre-deploy (Day 12). Types in active use: `architect`, `security-architect`, `reviewer`, `deepdive`. Output: `<review-name>.md` directly (e.g., `architect-review.md`). State: `sub_steps[]` (as the relevant sub-step gate).
- **Autopilot side-car** — background helper configured in `.claude-flow/autopilot/*.json`. Three types: `lint-fix`, `test-backfill`, `doc-sweep`. Output: `.claude-flow/autopilot/<name>/` + proposed diffs. State: `autopilot_log[]`.

- **Canonical home:** this section → `### Worker` (defines the three subtypes); operational catalog and mermaid diagram live in [`USAGE.md` §3](./USAGE.md#3--worker-architecture).
- **Grep-anchor:** `worker-term-canonical-DEV-A3`.

### Predicate

A jq-expression or shell-test evaluator that decides whether a phase's requirements are met. Predicate kinds live in `scripts/lib/phase-predicates.sh` (`file_exists`, `file_min_bytes`, `file_contains_heading`, `json_path_present`, `json_path_equals`, `json_path_in`, `state_field_min_length`, `state_field_all_values_in`, `sub_step_recorded`, `audit_resolution_complete` — added in v0.7.2 for the `audit-resolution` phase exit; `review_resolution_complete` — added in v0.7.3 for the `review-resolution` phase exit, transparently consumes legacy `audit_findings_*` fields via union view). Each predicate row in `phase-manifest.json` declares its `kind` plus the fields the evaluator consumes (`path`, `field`, `min_bytes`, etc.). `sprint-advance-phase.sh` refuses to write `state.phase` until every predicate for the entering phase returns 0 (or has a recorded bypass).

- **Canonical home:** this section → `### Predicate`.
- **Grep-anchor:** `predicate-term-canonical-DEV-A4`.

### Bypass

The single sanctioned escape hatch: `SPRINT_BYPASS_GATE=<gate-name> SPRINT_BYPASS_WHY='<≥10 chars>' bash scripts/sprint-advance-phase.sh <phase>`. Accepts a sub-step gate name from the manifest OR a path-shaped predicate (string containing `.` or `/`). Recorded to `state.gate_bypasses[]` with `{gate, why, at, caller}`. Multi-gate via comma-separated `SPRINT_BYPASS_GATE`. Operational syntax + deprecated legacy envs (`SPRINT_DRIFT_BYPASS=1`, etc., removal v0.8.0) live in [`USAGE.md` §4 — Bypass cheatsheet](./USAGE.md#4--bypass-cheatsheet); long-form rationale and anti-patterns in [`_guides/bypass-cheatsheet.md`](./_guides/bypass-cheatsheet.md).

- **Canonical home:** this section → `### Bypass`.
- **Grep-anchor:** `bypass-term-canonical-DEV-A5`.

### Gate-history

The append-only audit trail at `state.gate_history[]`. Every phase transition writes an entry `{from, to, at}` via `sprint-advance-phase.sh`. The replay validator (`scripts/sprint-replay-validator.mjs`) asserts monotonicity by `at` and that every required sub-step gate for each phase walked through appears in `gates_passed[]` ∪ `gate_bypasses[]`. Distinct from `gates_passed[]` (the set of names) and `gate_bypasses[]` (the bypass-with-rationale list).

- **Canonical home:** this section → `### Gate-history`.
- **Grep-anchor:** `gate-history-term-canonical-DEV-A6`.

### Drift

Semantic divergence between a commit's content and the spec's baseline. Computed by `scripts/sprint-drift-score.mjs` as cosine similarity between an embedding of the commit's message + diff stat + sample lines and `.baseline-embedding.json` (written at spec-lock). Below `SPRINT_DRIFT_THRESHOLD` (default `0.75`), the husky pre-commit hook pauses the commit with three options: amend, discard, or canonical bypass. Distinct from **scope drift** (commit touches a file outside `## Files touched`), which is enforced by `.claude/helpers/sprint-hook.cjs` at PreToolUse:Write/Edit time.

- **Canonical home:** this section → `### Drift`.
- **Grep-anchor:** `drift-term-canonical-DEV-A7`.

### Audit findings

The `state.audit_findings_*` family of state-fields, populated when the `audit` daemon worker runs at `verifying` phase entry (v0.7.2+). Shape: `audit_findings_total` (int, set on entry to `audit-resolution`), `audit_findings_resolved_count` (int, incremented per Fix decision), `audit_findings_deferred[]` (array of `{har_id, deferred_to_sprint, ac_id, rationale, deferred_at}`), `audit_findings_accepted[]` (array of `{har_id, owner, business_rationale, accepted_at}`). Mutated **only** by `scripts/sprint-audit-resolve.sh` via `atomic_update_state`. The `audit-resolution` phase exit predicate (`audit_resolution_complete`) asserts `resolved_count + deferred[].length + accepted[].length == total` AND every deferred entry has non-empty `deferred_to_sprint` + `ac_id`. Operator rationale strings are PII-redacted via `sprint-pii-redact.sh` before persistence (C5). Distinct from `gate_bypasses[]` — a deferred audit finding is a tracked carry-forward, not a skipped check.

- **Canonical home:** this section → `### Audit findings`.
- **Grep-anchor:** `audit-findings-term-canonical-DEV-A8`.

### Enforcement

Mentions of these terms outside their canonical homes must be **markdown links** to the anchor in this section. `scripts/check-terminology.sh` walks `docs/sprints/` and `docs/ruflo-sessions/` and fails if it finds an `^### <Term>` heading in any file other than the canonical home. Wired into the `verify-docs-terminology` sub-step gate. The replay validator additionally checks doc-vs-manifest drift: every gate name mentioned in `USAGE.md` §1/§2 must exist in `phase-manifest.json`, and vice versa. `doc_drift == 0` is required.

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

### Layer 2 — Worker-trigger helpers (2026-05-19)

| Script                          | Purpose                                                                                                                                                                                                                                                       |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/lib/worker-trigger.sh` | `trigger_worker <name> <slug> [timeout]` + `trigger_workers_parallel`. Polls `.claude-flow/metrics/<basename>.json` mtime, validates JSON, copies to `docs/sprints/<slug>/worker-output/`. CI hard-fails if `claude` lacks OAuth + `ANTHROPIC_API_KEY` unset. |
| `scripts/lib/worker-gates.sh`   | `gate_audit_blocks <output.json>` (zero-tolerance), `gate_testgaps_blocks <output> <slug>` (scope-bounded to spec `## Files touched`), `gate_optimize_advisory`.                                                                                              |
| `scripts/sprint-verify.sh`      | Wraps USAGE.md verify chain (typecheck → lint → tests → workers). audit + testgaps BLOCKING; optimize advisory. Records `state.verify_runs[]`. macOS bash 3.2 compatible.                                                                                     |
| `scripts/sprint-wave-start.sh`  | Fires `predict` (haiku) at each build wave kickoff.                                                                                                                                                                                                           |

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
    "G": "Following Ordex brand book — no design questions needed"
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

### Extending phase-manifest.json (v0.7.0+)

`scripts/lib/phase-manifest.json` is the single declarative source of truth for per-phase predicate enforcement. Adding a new gate, predicate, or phase requires updates in ≥3 files.

#### Adding a new sub-step gate

A sub-step gate represents "a step within a phase that must complete before phase advance" (e.g., `wizard-section-A`, `verify-typecheck`, `retro-pattern-1`).

1. **Pick a gate name.** Must match regex `^[a-zA-Z0-9][a-zA-Z0-9-]+$` (kebab-case + optional uppercase letters for wizard sections like `wizard-section-A`).
2. **Add to manifest.** Open `scripts/lib/phase-manifest.json`, find the phase the gate belongs to, append to `required_sub_step_gates[]`:
   ```json
   "verifying": {
     "required_sub_step_gates": [
       ...existing...,
       "verify-my-new-check"
     ]
   }
   ```
   For gates that should ONLY fire when `state.worker_rigor === "strict"`, append to `strict_only_sub_step_gates[]` instead.
3. **Validate the manifest:** `node scripts/lib/validate-phase-manifest.mjs`. Must report `[OK] manifest valid: 11 phases, N unique sub-step gates`.
4. **Wire the instrumentation.** Find the script that produces the artifact this gate represents (e.g., `sprint-verify.sh` for verify-\* gates). Add:
   ```bash
   # shellcheck disable=SC1091
   source "$(dirname "$0")/lib/sub-step.sh" 2>/dev/null || true
   if declare -F record_sub_step >/dev/null 2>&1; then
     record_sub_step "$SLUG" "verify-my-new-check" pass "<optional evidence path>" || true
   fi
   ```
5. **Update the documentation table** in `docs/sprints/USAGE.md` "## Phase enforcement" section — add the gate name to the relevant phase row. Add a row in `docs/sprints/_guides/sub-step-coverage.md` under "Instrumented".
6. **Smoke-test:** run the instrumentation script against a test sprint. Verify `jq '.gates_passed[] | select(.gate=="verify-my-new-check")' state.json` returns the recorded entry.
7. **Validate replay:** run `bash scripts/sprint-system-test.sh --replay-gate-history` against any post-v0.7.0 closed sprint. The doc-vs-manifest drift gate (AC-13d) catches new gates not yet wired.

#### Adding a new predicate kind

Predicate kinds are evaluated by `scripts/lib/phase-predicates.sh`. Today's kinds: `file_exists`, `file_min_bytes`, `file_contains_heading`, `json_path_present`, `json_path_equals`, `json_path_in`, `state_field_min_length`, `state_field_all_values_in`, `sub_step_recorded`.

1. **Pick a kind name.** Must be a kebab-case string distinct from existing kinds.
2. **Add to schema enum.** Edit `scripts/lib/phase-manifest.schema.json` — append to `definitions.Predicate.properties.kind.enum`.
3. **Add to validator.** Edit `scripts/lib/validate-phase-manifest.mjs` — append to `VALID_PREDICATE_KINDS` Set.
4. **Implement evaluator.** Edit `scripts/lib/phase-predicates.sh` — add a `_pp_pred_<your_kind>()` function following the pattern of existing evaluators (return 0 pass / 1 fail; print `[FAIL]` line on fail).
5. **Wire into `check_phase_requirements`.** Find the `case "$kind" in` block; add your case branch that extracts predicate fields from `$pred` and calls your evaluator.
6. **Use the kind** in the manifest predicates as needed.
7. **Smoke-test:** add a predicate using the new kind to a fixture sprint, run `check_phase_requirements`, verify it fires/passes correctly.

#### Adding a new phase

A new phase between e.g. `building` and `verifying` would require:

1. **Add to schema.** `scripts/lib/phase-manifest.schema.json` — append to `properties.phases.propertyNames.enum`.
2. **Add to validator.** `scripts/lib/validate-phase-manifest.mjs` — append to `VALID_PHASES` Set.
3. **Add to manifest.** `scripts/lib/phase-manifest.json` — new `<phase-name>` key with `advances_to[]`, `required_artifacts[]`, `required_state_fields[]`, `required_sub_step_gates[]`.
4. **Update neighbor phases' `advances_to[]`** — `building.advances_to` should now include the new phase; the new phase should advance to whatever follows.
5. **Add a phase-writer script** (or extend an existing one) to call `bash sprint-advance-phase.sh <new-phase>` when its work is done.
6. **Update USAGE.md "## Phase enforcement" table** with the new phase row.
7. **Update DEVELOPER.md "## State machine reference"** — add the phase to the state diagram.
8. **Validate + smoke:** `node scripts/lib/validate-phase-manifest.mjs`; run against a fixture sprint to ensure transitions resolve.

#### Adding a new bypass gate name

Bypass gates are referenced by `SPRINT_BYPASS_GATE=<name>`. As of T2.1 (deterministic-phases-v1 follow-up), the bypass-validation in `sprint-advance-phase.sh` checks the gate name against the manifest before recording. Two valid gate-name shapes:

- **Sub-step gate names** — any name in `required_sub_step_gates[]` or `strict_only_sub_step_gates[]` of any phase. Always valid.
- **Path-shaped gates** — strings containing `.` or `/` (e.g., `design.md`, `docs/sprints/<slug>/x.json`). Valid because they represent artifact-path predicates (`file_exists`, `file_min_bytes`, etc).

To support a new bypass shape (e.g., a state-field bypass), update the validation block in `scripts/sprint-advance-phase.sh` to recognize it.

#### Verification after extending

Run **all** of these before committing a manifest change:

```bash
node scripts/lib/validate-phase-manifest.mjs                      # structural valid
bash scripts/sprint-system-test.sh --replay-gate-history --quiet  # no replay regressions
# Smoke against your dogfood sprint:
SPRINT_SLUG_OVERRIDE=<your-slug> bash scripts/sprint-advance-phase.sh <next-phase>
```

The replay validator's doc-vs-manifest drift check (AC-13d) will fail at PR time if USAGE.md mentions a gate name that's not in the manifest. Keep both in sync.

---

### Honest deferred-gates ledger (post-W4)

> **State as of this sprint close.** Post-Wave-4 of `harness-truthful-docs-and-wiring-v1`, `scripts/lib/phase-manifest.json.deferred_gates[]` is **EMPTY**. Every one of the 68 sub-step gates in the manifest has at least one `record_sub_step` call-site in the script tree. Prior to W4, 43 of 68 gates were declared in the manifest but had zero call-sites — passing them required no actual work. This ledger documents the 43 gates that W4 wired, grouped by class.
>
> Verify the empty state at any time: `jq '.deferred_gates | length' scripts/lib/phase-manifest.json` → `0`. The coverage check `bash scripts/check-sub-step-coverage.sh` greps every gate name in the manifest against the script tree and asserts ≥1 `record_sub_step` reference per name. Replay validator (`scripts/sprint-replay-validator.mjs`) blocks any PR that re-introduces a deferred gate.

#### Class A — Wizard (14 gates)

Instrumented in `scripts/sprint-spec-wizard.mjs::recordAnswer` and `scripts/sprint-wizard-coherence.mjs` + `scripts/sprint-wizard-assemble.mjs`. END-only schema (the artifact's existence is the proof).

| Gate                       | Call-site                                      | Trigger                                 |
| -------------------------- | ---------------------------------------------- | --------------------------------------- |
| `wizard-section-A`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section A complete                      |
| `wizard-section-B`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section B complete                      |
| `wizard-section-C`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section C complete                      |
| `wizard-section-D`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section D complete                      |
| `wizard-section-E`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section E complete                      |
| `wizard-section-F`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section F complete                      |
| `wizard-section-G`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section G complete                      |
| `wizard-section-H`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section H complete                      |
| `wizard-section-I`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section I complete                      |
| `wizard-section-J`         | `scripts/sprint-spec-wizard.mjs::recordAnswer` | Section J complete                      |
| `wizard-coherence-after-C` | `scripts/sprint-wizard-coherence.mjs::main`    | Coherence check after §C                |
| `wizard-coherence-after-F` | `scripts/sprint-wizard-coherence.mjs::main`    | Coherence check after §F                |
| `wizard-coherence-after-I` | `scripts/sprint-wizard-coherence.mjs::main`    | Coherence check after §I                |
| `wizard-assemble`          | `scripts/sprint-wizard-assemble.mjs::main`     | spec.md rendered from spec.partial.json |

#### Class B — Spec-lock (4 gates)

Instrumented at the Task sub-agent file-write call-site (`sprint-orchestrator` skill) plus `scripts/sprint-amend-spec.sh --lock` for the baseline. END-only.

| Gate                            | Call-site                                        | Trigger                                                                |
| ------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------- |
| `spec-lock-solution-sketches`   | `sprint-orchestrator` skill `phase-spec-lock.md` | `solution-sketches.md` ≥200B written                                   |
| `spec-lock-architect-review`    | `sprint-orchestrator` skill `phase-spec-lock.md` | architect Task sub-agent finishes; `architect-review.md` ≥200B         |
| `spec-lock-security-review`     | `sprint-orchestrator` skill `phase-spec-lock.md` | security-architect Task sub-agent finishes; `security-review.md` ≥200B |
| `spec-lock-hive-mind-consensus` | `scripts/sprint-hive-mind-spec-lock.sh`          | `consensus-spec.json.verdict ∈ {pass, pass-with-notes}`                |
| `spec-lock-baseline-written`    | `scripts/sprint-amend-spec.sh --lock`            | `.baseline-embedding.json` written                                     |

(Fifth row is the spare-but-tracked baseline gate; counted under the "4 spec-lock gates" because it was instrumented in the same wave.)

#### Class C — Verify (21 gates)

Instrumented in `scripts/verify-*.sh` scripts (and `scripts/sprint-verify.sh` for the worker-gate sub-set). Hybrid START+END schema (long-running; need to be visible mid-run).

| Gate                                  | Call-site                            | Inject technique used to prove the predicate (W4)         |
| ------------------------------------- | ------------------------------------ | --------------------------------------------------------- |
| `verify-typecheck`                    | `scripts/verify-typecheck.sh`        | Inject syntax error                                       |
| `verify-lint`                         | `scripts/sprint-lint-check.sh`       | Inject lint violation                                     |
| `verify-tests`                        | `scripts/verify-tests.sh`            | Inject failing test                                       |
| `verify-api-contract`                 | `scripts/verify-api-contract.sh`     | Inject schema mismatch                                    |
| `verify-debug-rls`                    | `scripts/verify-debug-rls.sh`        | Inject missing RLS policy                                 |
| `verify-module-status`                | `scripts/verify-module-status.sh`    | Inject missing module export                              |
| `verify-perf-profile`                 | `scripts/verify-perf-profile.sh`     | Inject regression > P95                                   |
| `verify-aidefence-scan`               | `scripts/verify-aidefence-scan.sh`   | Inject hardcoded JWT pattern                              |
| `verify-sonar`                        | `scripts/sprint-sonar-parse.sh`      | Inject Sonar violation                                    |
| `verify-knip`                         | `scripts/sprint-deadcode-delete.mjs` | Inject unused export                                      |
| `verify-cycle-check`                  | `scripts/sprint-cycle-check.sh`      | Inject import cycle                                       |
| `verify-audit-deps`                   | `scripts/sprint-audit-deps.sh`       | Inject high-CVE dep                                       |
| `verify-bundle-budget`                | `scripts/sprint-bundle-budget.sh`    | Inject 5MB+ bundle                                        |
| `verify-coverage-delta`               | `scripts/sprint-coverage-delta.sh`   | Inject coverage drop                                      |
| `verify-migration-check`              | `scripts/sprint-migration-check.sh`  | Inject schema-vs-tracker drift                            |
| `verify-worker-audit`                 | `scripts/sprint-verify.sh`           | Spoof worker JSON with no `findings` field                |
| `verify-worker-testgaps`              | `scripts/sprint-verify.sh`           | Spoof worker JSON with no `gaps` field                    |
| `verify-worker-optimize`              | `scripts/sprint-verify.sh`           | (advisory; no inject required)                            |
| `verify-worker-map-refreshed`         | `scripts/sprint-verify.sh`           | (strict-tier only) Stale `worker-output/map.json`         |
| `verify-worker-consolidate-refreshed` | `scripts/sprint-verify.sh`           | (strict-tier only) Stale `worker-output/consolidate.json` |
| `verify-docs-terminology`             | `scripts/check-terminology.sh`       | Inject duplicate `^### Phase` heading                     |

#### Class D — Deploy (5 gates)

Instrumented in `scripts/sprint-deploy.sh`. Hybrid START+END for execution gates, END-only for capture gates.

| Gate                             | Call-site                               | Trigger                                                         |
| -------------------------------- | --------------------------------------- | --------------------------------------------------------------- |
| `deploy-pulumi-preview-captured` | `scripts/sprint-deploy.sh::run_preview` | `pulumi preview` stdout captured to `deploy/pulumi-preview.txt` |
| `deploy-human-gate-approved`     | `scripts/sprint-deploy.sh::human_gate`  | Operator typed `proceed`                                        |
| `deploy-pulumi-up`               | `scripts/sprint-deploy.sh::run_up`      | `pulumi up` exit 0                                              |
| `deploy-smoke`                   | `scripts/sprint-deploy.sh::run_smoke`   | smoke URLs return 2xx                                           |
| `deploy-vercel`                  | `scripts/sprint-deploy.sh::run_vercel`  | `vercel deploy --prod` exit 0                                   |

> Deploy gates record **artifact paths only** to `state.sub_steps[].evidence_path` — never Pulumi stack contents, never AWS credentials, never raw secrets (security condition C6).

#### Verification commands

```bash
# Deferred gates list is empty:
jq '.deferred_gates | length' scripts/lib/phase-manifest.json    # → 0

# Every gate has ≥1 record_sub_step call-site:
bash scripts/check-sub-step-coverage.sh                          # exit 0

# Replay validator on this sprint's dogfood:
node scripts/sprint-replay-validator.mjs --quiet                 # doc_drift=0
```

---

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

### Proof-file location convention (v0.7.0+)

Two distinct directories serve two distinct purposes:

- **`docs/sprints/<slug>/proof/AC-N.md`** — per-AC evidence for a specific sprint. Lives inside the sprint dir, committed alongside the AC implementation. Read by `sprint-harness-readiness.mjs` when aggregating that sprint's verdicts. This is where every Production AC's inject-violation-catch-restore log lands.
- **`scripts/violation-fixtures/<name>.patch`** — reusable fixtures (the diffs that get injected). Shared across sprints when the same kind of violation needs to be reproduced (e.g., a `state.json` mutation that any future sprint may want to assert is blocked).

When porting to sprint-harness package, vendored fixtures live at `lib/proof/` (test-runner-readable at install time). Per-sprint proofs do NOT mirror — they're part of the consuming repo's sprint dir, not the harness package.

### Bugs caught in 2026-05-19 harness audit

Added to the registry below:

| Pattern                         | Symptom                                                                                                                | Fix                                                                                       |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `<BRAND_SLUG>-atomic-state-args-trap` | `atomic_update_state slug --arg X val '<filter>'` silently fails because helper only took 2 positional args            | Variadic forward: collect args between slug + last-arg (filter), pass all to `jq`         |
| `<BRAND_SLUG>-ruflo-cli-drift`        | `ruflo memory embed` / `embeddings encode` / `consensus -a submit` / `neural train --type` — all invalid as of v3.7.0+ | Re-verify against `ruflo <cmd> --help` before fixing; CLI surface shifts between versions |
| `<BRAND_SLUG>-stale-bug-diagnosis`    | Bug report based on file content that's already been fixed in a prior commit                                           | Re-grep the file before applying any fix; trust `grep -n` over memory                     |

### State.json race recipe (W1 fix, 2026-05-19)

**Symptom.** `docs/sprints/<slug>/state.json` shows an orphan `},` line or invalid JSON after a burst of concurrent commit hooks. Bypass entries land in `reuse_audits[]` instead of `gate_bypasses[]`. `jq . state.json` exits non-zero.

**Cause.** Two callers used **different lockfile paths** — `.husky/post-commit:32` previously acquired `docs/sprints/<slug>/state.json.lock` (in-repo) while `scripts/lib/atomic-state.sh:71` acquired `$HOME/.cache/<BRAND_SLUG>/locks/state-<slug>.lock` (per-user). No mutual exclusion between the two writers. Inline `jq … > state.json.tmp && mv` from the post-commit hook collided with `atomic_update_state` writes from the daemon-worker pipeline.

The third lockfile path was even more subtle: `.husky/post-commit:181` invoked the reuse-audit under `env -i` with an allowlist. The detached child shell had no inherited state and couldn't reliably `source scripts/lib/atomic-state.sh` (BASH_SOURCE resolution under env-strip).

**Fix.** All state.json writers — `.husky/post-commit` (inline AND the env-stripped audit heredoc), `atomic-state.sh`, `worker-trigger.sh`, every `sprint-*.sh` — acquire the **canonical path** `$LOCK_DIR/state-<slug>.lock` via `scripts/lib/atomic-state.sh::atomic_update_state`:

```bash
source "$REPO/scripts/lib/atomic-state.sh"
atomic_update_state "$SLUG" "$JQ_FILTER"
```

The env-stripped subprocess uses the new wrapper `scripts/sprint-state-append.sh` (env-strip-safe; resolves repo root from `BASH_SOURCE` then sources `atomic-state.sh`):

```bash
bash "$REPO/scripts/sprint-state-append.sh" "$SLUG" "$JQ_REUSE_AUDIT_APPEND"
```

**Verify.** Run the 20-writer stress harness:

```bash
bash scripts/test/stress-state-lock.sh <slug> 20
# expected: stress: PASS (20 writers, 0 corruption)
```

The harness simulates four caller classes × 5 each in parallel: post-commit appends, advance-phase writes, worker-trigger appends, sprint-checkin writes. Acceptance assertions:

- `jq empty docs/sprints/<slug>/state.json` (parses)
- `grep -c '^}$' state.json` returns `1` (single closing brace)
- All four writer classes' entries present in their target arrays
- No cross-leak between `gate_bypasses[]` and `reuse_audits[]`

**Invariant I-1 (load-bearing).** For any slug, every state.json write acquires the same path `$LOCK_DIR/state-<slug>.lock`. CI check:

```bash
grep -rn 'STATE_LOCK\|\.lock\b' scripts/ .husky/ | grep -v atomic-state.sh
# expected: empty
```

**Recovery from a corrupt state.json.** `atomic-state.sh::recover_state_from_bak <slug>` restores from `state.json.bak` (written before every successful update).

---

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
- **Security** — catch RLS/auth gaps; <BRAND_PRODUCT_NAME> specific
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
- Neural training can learn coordination patterns specific to <BRAND_PRODUCT_NAME>
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

## Audit-driven fix days

> **Status (v0.7.2+):** **IMPLEMENTED in `harness-audit-resolution-and-scope-v1`** (closed 2026-05-19). The `audit-resolution` phase + per-finding tracking + re-fire capability + scope-bounded audit/testgaps gates all shipped together. This section preserves the original design rationale + links the canonical template and a live example.
>
> **Canonical template:** [`docs/sprints/_templates/audit-resolutions.md`](../sprints/_templates/audit-resolutions.md) — auto-seeded into the sprint dir on phase entry.
> **Live example:** [`docs/sprints/harness-truthful-docs-and-wiring-v1/audit-resolutions.md`](../sprints/harness-truthful-docs-and-wiring-v1/audit-resolutions.md) — the 10 HAR-1..10 findings that drove the v0.7.2 sprint.

### The gap

The harness fires `audit` + `testgaps` + `optimize` daemon workers on entry to `verifying` phase (Day 11-12). When they produce real findings — like `docs/sprints/audit-driven-fidelity-v1/worker-output/audit.json` did with **9 vulnerabilities (riskScore=72)** including a high-severity command-injection in `.claude/helpers/github-safe.js:52` — there are only 2 days (Day 12 pre-deploy + Day 13 deploy) before sprint-end. That's not enough time to actually FIX 9 findings; the natural failure mode is "bypass with rationale" or "defer to follow-up" — which is the corner-cutting pattern that drove this sprint.

### What we actually need

The 14-day appetite must explicitly carve out **4 days of audit-resolution capacity AFTER verify runs but BEFORE sprint-end**. Concrete shape:

| Day        | Phase                       | Worker fires                               | Capacity for fixes                                  |
| ---------- | --------------------------- | ------------------------------------------ | --------------------------------------------------- |
| Day 9      | building (Wave-N close)     | `audit-light`, `testgaps-light` (advisory) | Findings logged; fix during next Wave               |
| **Day 10** | **verifying (FULL)**        | `audit`, `testgaps`, `optimize` (BLOCKING) | **Real audit fires here, NOT Day 11-12**            |
| **Day 11** | **fix-day-1**               | re-run audit after each fix                | **NEW PHASE** — operator addresses findings         |
| **Day 12** | **fix-day-2 OR pre-deploy** | re-run audit; advance only when clean      | Findings ≤ acceptance threshold or cut to follow-up |
| Day 13     | deploy                      | (no fire)                                  | Workflow pause for human gate                       |
| Day 14     | retro                       | `document` + `consolidate`                 | Patterns extracted; findings → memory               |

This requires:

1. **New phase in `phase-manifest.json`**: `audit-resolution` between `verifying` and `pre-deploy`. Required artifacts: `audit-resolutions.md` documenting each finding with status (fixed / deferred-with-AC / accepted-with-rationale). Required state field: `state.audit_findings_resolved_count == state.audit_findings_total` OR explicit `audit_findings_deferred[]` with each entry tagging the follow-up sprint slug.
2. **Re-fire audit on phase entry to `audit-resolution`** AND on each manual `re-audit` trigger so operators see progress against the finding list.
3. **Verify-fail = not-blocking-but-recorded.** Currently `verify-worker-audit` is BLOCKING (`phase-workers.json` line 33). With audit-resolution phase, verifying becomes the gate that _populates_ the finding list; resolution happens in its own phase with its own appetite.
4. **`audit-driven-fidelity-v1` IS the prior art** — that sprint's `worker-output/audit.json` shows the exact finding shape (`vulnerabilities[]` with severity/file/line/description + riskScore + recommendations[]) the resolution phase must consume.

### Why this wasn't in v0.7.0/v0.7.1 (historical)

- Adding a new phase requires updates in 7 places per the "Adding a new phase" recipe above. Each existing sprint's gate_history would need to be backfilled or skipped by the replay validator.
- The audit-finding-to-AC mapping (which findings get fixed, which get deferred to follow-up sprint as new ACs) is a workflow design problem worth its own appetite — not a tacked-on patch.
- `audit-resolution` phase + per-finding tracking + re-fire capability is a substantial chunk of work (~6 ACs estimated).

### As implemented in `harness-audit-resolution-and-scope-v1` (v0.7.2)

19 ACs delivered across 4 waves. Wave map:

- **W1 (AC-1..4)** — scope-bounded workers: `gate_audit_blocks` accepts `<slug>` arg + partitions findings (in-scope blocks, out-of-scope advisory); new `gate_optimize_scope_filter`; `sprint-verify.sh` passes `$SLUG`; `phase-workers.json` v1.0→1.1 + per-worker `worker_scope` map. See [`USAGE.md` §3 — Worker scope](./USAGE.md#worker-scope-v072).
- **W2 (AC-5..8)** — `audit-resolution` phase added (between `verifying` and `pre-deploy`); new predicate kind `audit_resolution_complete`; NEW `scripts/sprint-audit-resolve.sh` (interactive triage walker with `--status` + `--finding HAR-N {fix|defer|accept}` programmatic mode); NEW `scripts/sprint-audit-rerun.sh` (env-stripped audit re-fire + FIXED/REGRESSION/UNCHANGED diff + consecutive-regression streak counter); NEW template `docs/sprints/_templates/audit-resolutions.md`.
- **W3 (AC-9..18)** — 10 HAR security fixes in `.claude/helpers/{github-safe,memory,session,statusline}.js`: command-injection (HAR-1/5), AES-256-GCM at-rest encryption (HAR-2/4) via node built-in crypto with 0600 key file + atomic plaintext→encrypted migration, UUID session IDs (HAR-3), input validation (HAR-6/7), error-handling discipline (HAR-8/10), atomic tmp file via `O_EXCL` (HAR-9). 45/45 tests passing.
- **W4 (AC-19)** — replay-validator backward-compat (`phase_manifest_version_seen` per closed sprint), `sprint-status.sh` resolution fix, post-commit Edit-tool atomicity respect, docs+polish.

**Exit predicate:** `state.audit_findings_resolved_count + audit_findings_deferred[].length + audit_findings_accepted[].length == audit_findings_total` AND every deferred entry has non-empty `deferred_to_sprint` + `ac_id`. Vacuous PASS when `audit_findings_total == 0`.

### Companion (also delivered in v0.7.2) — scope-bounded workers

A parallel gap surfaced during W5 dogfood: verify-phase workers (`audit`, `testgaps`, `optimize`) currently scan the ENTIRE repository, producing 10+ pre-existing findings on every sprint regardless of which files this sprint touched. Without scope-bounding, the audit-resolution loop never converges — every fix cycle resurfaces noise from files outside the current sprint's scope.

Required parallel work alongside `harness-audit-resolution-v1`:

- `worker-trigger.sh::trigger_worker` accepts `--scope=files-touched` arg sourced from spec `## Files touched`.
- `phase-workers.json` declares per-worker scope defaults (verify-\* workers default to files-touched).
- Audit/testgaps/optimize prompt templates include explicit "ONLY review files in $FILES_TOUCHED" constraint when scope is set.
- `gate_audit_blocks` rechecks findings against scope before recording fail (drops out-of-scope findings to advisory).
- Mirror the existing `gate_testgaps_blocks` scope-bound pattern (already filters by spec `## Files touched` per harness-parallel-safety-v2 AC-3).

**Why both must ship before v0.8**: without scope-bounding, every fresh sprint that runs verify will surface the same pre-existing findings → operators desensitize to real audit signal → the audit-resolution-v1 infrastructure becomes ceremony rather than enforcement. Signal-to-noise is load-bearing.

### Operator guidance (v0.7.2+)

Sprints that touch security-sensitive code (auth/RLS/secrets/payments) should:

1. Allocate Days 12–13 as **audit-resolution capacity** — the phase is a peer of verify/pre-deploy, not a slack day. With 5+ findings, expect both days consumed.
2. Run `bash scripts/sprint-verify.sh` MANUALLY on Day 8 to surface findings early so build still has runway to fix in-line vs deferring.
3. Use `bash scripts/sprint-audit-resolve.sh --finding HAR-N {fix|defer|accept}` programmatically when scripting triage; default interactive mode walks all findings sequentially.
4. NEVER bypass `verify-worker-audit` or `audit-findings-exit-predicate` to ship a known-vulnerable diff. Defer with a named follow-up sprint instead — `audit_findings_deferred[]` is a different signal than `gate_bypasses[]` and surfaces in retro + dashboard.

---

## Worker scoping

> **Landed in v0.7.2** (`harness-audit-resolution-and-scope-v1` W1, AC-1..4). Operator-facing details: [`USAGE.md` §3 — Worker scope](./USAGE.md#worker-scope-v072). This subsection covers the implementation contract for developers adding scope-bounding to a new worker.

### The three scope strategies

| `scope`         | When to use                                                                                                                                               | `scope_mode`                | Status                                                                                                                                          |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `files-touched` | Worker output should only block on findings inside `state.files_touched[]`. Out-of-scope findings logged as advisory `[OUT/<severity>]` stderr lines.     | `post-filter`               | Implemented in v0.7.2. Applied at gate-eval time (NOT at worker invocation). Locked default (Sketch A).                                         |
| `repo`          | Worker is genuinely repo-wide (e.g., `optimize` — recommendations on the whole codebase are still useful, not noisy).                                     | `none`                      | Implemented (back-compat default for unmapped workers).                                                                                         |
| `spec-h1`       | Future: scope via env-var or prompt-inject at worker invocation. Useful when the LLM-backed worker can short-circuit its own scan given a file allowlist. | `env-var` / `prompt-inject` | **Placeholder.** Not implemented in v0.7.2. Reserved in schema so future workers can declare intent without re-versioning `phase-workers.json`. |

### The testgaps → audit retrofit pattern

`gate_testgaps_blocks` (`scripts/lib/worker-gates.sh:58-106`) is the canonical reference implementation. Originally shipped in `harness-parallel-safety-v2` AC-3, it accepts `<output.json> <slug>`, reads `state.files_touched[]` (with spec.md `## Files touched` fallback for legacy sprints), and partitions worker findings into in-scope (block on any) vs out-of-scope (advisory log only). In v0.7.2, `gate_audit_blocks` was retrofitted to mirror this exact pattern (`worker-gates.sh:25-127`):

1. Accept `<output.json> <slug>` (was `<output.json>` only).
2. Read `state.files_touched[]` via `jq -r '.files_touched[]?'` with fallback to awk-parse of spec.md `## Files touched`.
3. Iterate worker findings (`.findings.vulnerabilities[]` for audit; union with legacy `.vulnerabilities[]` for back-compat).
4. For each finding, check if its `file` field has string-suffix overlap with any `files_touched[]` entry.
5. Partition into `in_scope[]` + `out_of_scope[]` bash arrays.
6. Log `[OUT/<severity>] <file>:<line> — <desc>` for each out-of-scope finding on stderr (advisory).
7. Block (exit 1) **only** on in-scope findings of severity ≥ threshold. Exit 0 if all findings out-of-scope.

### Recipe — adding scope-bounding to a new worker

When introducing a new blocking worker that should respect scope:

1. **Declare the scope in `phase-workers.json`** under the phase's `worker_scope` block:
   ```json
   "worker_scope": {
     "your-worker": { "scope": "files-touched", "scope_mode": "post-filter" }
   }
   ```
2. **Update the gate** in `scripts/lib/worker-gates.sh` to accept `<slug>` as a second arg. Copy the `gate_testgaps_blocks` body and adapt the finding-iteration loop to your worker's output schema (declared in `phase-workers.json` `expects[]`).
3. **Update `sprint-verify.sh`** (or whichever script invokes the gate) to pass `$SLUG`.
4. **Smoke-test** against a closed sprint with known out-of-scope findings: gate should exit 0 + emit advisory log lines.
5. **Bump `phase-workers.json.version`** if the scope-bound worker also gains new structural fields. Otherwise leave at current minor.

### Source of truth

`state.json.files_touched[]` is canonical, populated by `sprint-amend-spec.sh --lock` from spec.md §H1 and amended by `sprint-amend-spec.sh --add-file`. The spec.md `## Files touched` section parse is a fallback for sprints predating spec-lock instrumentation. Never write `files_touched[]` directly — always route through `atomic_update_state`.

---

## Known limitations

> These 7 gaps were re-confirmed in the 2026-05-17 P5 QA audit (gaps #28-34). All upstream / by-design / environment-dependent — not addressable locally.
>
> **Resolved in v0.7.2** (sprint `harness-audit-resolution-and-scope-v1`): the prior limitations "`audit-resolution` phase doesn't exist" and "verify workers run repo-wide regardless of sprint scope" have both landed. The `audit-resolution` phase + scope-bounded `gate_audit_blocks` shipped together so the audit-resolution loop converges on in-scope signal rather than repo-wide noise. See [`## Audit-driven fix days`](#audit-driven-fix-days) and [`## Worker scoping`](#worker-scoping) above.

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
- [`SCRIPTS.md`](./SCRIPTS.md) — canonical inventory of every harness script (90+ files)
- [`README.md`](./README.md) — architecture + dir layout
- [`~/.claude/plans/hazy-gathering-kettle.md`](file:///Users/gio/.claude/plans/hazy-gathering-kettle.md) — original design with 36 decisions
- [`../ruflo-sessions/ruflo-for-<BRAND_SLUG>.md`](../ruflo-sessions/ruflo-for-<BRAND_SLUG>.md) — full ruflo feature reference
- [`../ruflo-sessions/ruflo-syllabus.md`](../ruflo-sessions/ruflo-syllabus.md) — 23-session ruflo learning syllabus

---

## License + maintenance

This sprint system is part of <BRAND_PRODUCT_NAME>. MIT licensed (<BRAND_PRODUCT_NAME> default). Edit freely. PRs welcome at the SKILL.md and section markdown level — those have the highest ROI per change. Lower layers (scripts, hooks) require more care.

**Last refreshed:** 2026-05-17
