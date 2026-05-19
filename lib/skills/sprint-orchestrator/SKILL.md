---
name: sprint-orchestrator
description: Run a complete 2-week Shape Up + SPARC sprint for LifeOS — from spec wizard through deploy + retro — using the full ruflo orchestration stack (workflows, swarms, claims, hive-mind, autopilot, DAA, SONA). Invoked when user says "start a sprint", "let's plan a sprint", "begin sprint for X", or "/sprint <slug>".
---

# Sprint Orchestrator

This skill defines the **14-day protocol** Claude follows to drive a LifeOS sprint end-to-end with deterministic gates, drift control, and full ruflo activation. It is the centerpiece skill of the LifeOS sprint system.

> **Source of truth:** `/Users/gio/.claude/plans/hazy-gathering-kettle.md` — the approved sprint system plan. This skill operationalizes that plan.

> **Companion skills:** `sprint-spec-wizard` (the adaptive wizard runs as part of phase 1), `sparc-methodology` (phase 3 SPARC chain), `verification-quality` (verify phase), `swarm-orchestration` (build-phase swarm).

---

## When to invoke

Activate this skill when the user says any of:

- "start a sprint"
- "let's start a sprint for X"
- "begin sprint <slug>"
- "/sprint <slug>"
- "plan a sprint for <module>"
- "kick off the <X> module build"

Also activate **passively** (don't ask first, just load context) when:

- The user references an active sprint by ID
- The user mentions `docs/sprints/<id>/`
- The user invokes `bash scripts/sprint-status.sh`

---

## The 14-day protocol

Each sprint is ONE module slice in a 2-week Shape Up + SPARC cycle. Phases below are deterministic — every sprint follows this shape.

### Phase 0 — Pre-sprint (Day 0)

**Trigger:** user says "start a sprint for <slug>".

**Actions:**

1. Run `bash scripts/sprint-start.sh <slug>` — this creates:
   - `docs/sprints/<slug>/` directory
   - `state.json` with phase=`spec-wizard`, day=0, started_at=now
   - Empty `hill-chart.md`, `spec.partial.json`, `wizard-transcript.md`
   - Git branch `sprint/<slug>` (checked out)
   - GitHub Issue (if `gh` available + repo has a remote)
2. Invoke the `sprint-spec-wizard` skill — it takes over for the wizard run (20-40 min).
3. Once wizard completes, return here for **Phase 1** review chain.

**Verification:**

- `ls docs/sprints/<slug>/` shows the expected files
- `bash scripts/sprint-status.sh` reports `phase: spec-wizard`
- Branch `sprint/<slug>` is current

---

### Phase 1 — Spec lock (Day ½)

**Pre-condition:** wizard completed; `spec.partial.json` and `wizard-transcript.md` exist; `spec.md` assembled from template.

**Actions (run in order):**

1. **Generate 2-3 alternative solution sketches.** Read §A (Problem), §B (Business logic), §C (Data), §D (API), §E/F (UI/UX) from the spec. Propose 2-3 different solution sketches with explicit tradeoffs (e.g., "Option A: monolithic — fewer files, simpler; Option B: split — more reusable, more setup; Option C: leverage existing Y"). Write to `docs/sprints/<slug>/solution-sketches.md`. Present to user for selection.
2. **Architect-agent review.** Spawn Agent with `subagent_type: architect` (or `subagent_type: Plan`). Prompt: "Review the spec at `docs/sprints/<slug>/spec.md` for architectural soundness. Focus on §C (data boundaries), §D (API surface coherence), §E (component decomposition). Report blockers and structural concerns. Under 400 words." Append output to `docs/sprints/<slug>/architect-review.md`.
3. **Security-architect review.** Spawn Agent with `subagent_type: security-architect`. Prompt: "Review the spec at `docs/sprints/<slug>/spec.md` for security. Focus on §C (RLS policies, PII handling), §D (auth on every route), §H (external APIs), §J (security risks). Report any RLS gaps, auth holes, or PII leak risks. Under 400 words." Append output to `docs/sprints/<slug>/security-review.md`.
4. **Hive-mind consensus.** Initialize hive-mind via `mcp__claude-flow__hive-mind_init` with `queen-type: strategic`, spawn 4 workers, broadcast the spec content, run Raft consensus on the question: _"Is this scope coherent and shippable in 14 days? Vote yes/no with reasoning."_ Wait for quorum (4 of 5 = unanimous including queen). Record outcome to `docs/sprints/<slug>/consensus-spec.json`.
5. **Present to user.** Show the 4 outputs together (solution sketches + architect + security + consensus). User edits `spec.md` if needed. User signs off → run `bash scripts/sprint-amend-spec.sh --lock` which:
   - Embeds `spec.md` to `.baseline-embedding.json` (the drift baseline)
   - Updates `state.json` phase=`spec-locked`, gates+=spec-lock
   - Commits `spec.md` + reviews with message `sprint(<slug>): spec-lock`

**Verification:**

- All 4 review files present
- `state.json` shows `phase: spec-locked`, gates includes `spec-lock`
- `.baseline-embedding.json` exists and is 384-dim
- Git log shows `sprint(<slug>): spec-lock` commit

**If consensus fails:** the spec is incoherent. Present the dissenting reasoning to the user, propose specific edits, re-run from step 4. Do NOT lock spec until consensus passes.

---

### Phase 2 — SPARC design (Day 1-2)

**Pre-condition:** `state.json.phase == spec-locked`.

**Actions:**

1. **Invoke `/sparc:spec-pseudocode`** — using the spec's §A-J as input, produce the Specification + Pseudocode block. Append to `docs/sprints/<slug>/design.md` under `## SPARC Specification` and `## SPARC Pseudocode`.
2. **Invoke `/sparc:architect`** — produce the Architecture block. Component diagram (ASCII or mermaid), sequence diagram for happy path, file structure plan. Append to `design.md` under `## SPARC Architecture`.
3. **Present design.md to user.** User reviews, requests changes, signs off → run `bash scripts/sprint-design-lock.sh` which updates `state.json` phase=`design-locked`, gates+=design-lock, commits with `sprint(<slug>): design-lock`.

**Verification:**

- `design.md` has 3 SPARC sections filled
- `state.json.phase == design-locked`

---

### Phase 3 — Build (Day 3-11)

**Pre-condition:** `state.json.phase == design-locked`.

**Actions:**

1. **Kick off build workflow.** Run `bash scripts/sprint-build-launch.sh` which executes `ruflo workflow execute lifeos-sprint-build --input spec=docs/sprints/<slug>/spec.md`.
2. **The workflow:**
   - Initializes 8-agent `hierarchical-mesh` swarm via `mcp__claude-flow__swarm_init`
   - Grants claims per file-ownership domain via `mcp__claude-flow__claims_claim`:
     - `coder` × 2 → backend (apps/lambdas) + frontend (apps/web)
     - `architect` → database (packages/db) + types (packages/types)
     - `tester` → tests across all domains
     - `reviewer` → continuous code review
     - `security-architect` → audit RLS/auth on every commit
     - `cicd-engineer` → infra/ + .github/ (idle unless infra touched)
     - Coordinator (queen, tactical) → routes blockers
   - Spawns 3 autopilot side-cars (in parallel):
     - `lint-fix`: `pnpm lint:fix` bounded to changed files; max 5 iterations
     - `test-backfill`: paired with daemon `testgaps` worker; writes Vitest tests for new uncovered routes
     - `doc-sweep`: updates CLAUDE.md + JSDoc when convention emerges
3. **Per-AC build loop:**
   - For each AC in §I of spec, in declared order:
     - If AC is flagged `complex: true` → switch to pair-programming DRIVER mode for that AC
     - Otherwise → swarm executes via TDD: red (test first) → green (implementation) → refactor → review → commit
   - Each commit runs `bash scripts/sprint-drift-check.sh` (husky pre-commit) — drift score logged to `state.json`; pauses on <0.75
4. **Stream-chain pipelines** (when spec mentions NL parsing or AI scheduler work):
   - Invoke `/stream-chain` skill with the pipeline definition from §F
5. **Tactical queen for blockers:** if any agent reports blocker, escalate to second hive-mind session with `queen-type: tactical`. Workers vote on resolution.
6. **Mid-build standup (daily):** daemon's `document` worker runs `scripts/sprint-standup.mjs` once per day; appends to `standup.md`.

**Verification:**

- After day 11, `state.json.acs_closed` reflects all ACs marked closed
- Git log shows commits with `sprint(<slug>): AC-N close`
- All side-car autopilot loops report success in `state.json.autopilot_log`

---

### Phase 4 — Mid-cycle check-in (Day 5)

**Trigger:** day 5 reached OR user runs `bash scripts/sprint-checkin.sh`.

**Actions:**

1. Update `hill-chart.md` based on current `state.json.acs_closed` and `state.json.acs_in_progress`. Each AC is a dot on the curve:
   - **Uphill (figuring out):** AC where design questions remain
   - **Top of hill (locked):** AC where approach is clear
   - **Downhill (making it happen):** AC where implementation is underway
   - **At bottom (done):** AC closed
2. Ask user 3 questions:
   - Which ACs are over the hill (building)?
   - Which are stuck under the hill (still figuring out)?
   - Cut, push, or pivot anything?
3. If user cuts ACs → run `bash scripts/sprint-amend-spec.sh --cut "<AC-IDs>"`
4. If user pivots → run `bash scripts/sprint-amend-spec.sh --pivot` to open spec.md in editor; on save, re-baseline the embedding
5. Update `state.json` gates+=mid-checkin, write `check-in-day5.md`, commit with `sprint(<slug>): day-5-checkin`

**Verification:**

- `hill-chart.md` and `check-in-day5.md` updated
- `state.json` gates includes `mid-checkin`

---

### Phase 5 — Verify (Day 11-12)

**Pre-condition:** all §I ACs closed; entering verify phase.

**Actions:**

1. Run `ruflo workflow execute lifeos-sprint-verify --input spec=docs/sprints/<slug>/spec.md` which chains:
   - `pnpm typecheck` (full project)
   - `pnpm lint` (with `next lint` filter — per LifeOS memory, next lint is interactive; use the project's CI-safe wrapper)
   - `pnpm test` (unit + integration)
   - `/api-contract-validation` (manifest vs Zod schemas)
   - `/debug-rls` (verify RLS on new tables)
   - `/module-status <module>` (DoD checklist verification)
   - `mcp__claude-flow__performance_profile` (P95 latency check vs §I bars)
   - `mcp__claude-flow__aidefence_scan` on any user-input surfaces in spec
2. Any failure → pause, surface to user, prompt fix
3. All green → `state.json.phase = pre-deploy`

---

### Phase 6 — Pre-deploy review (Day 12)

**Pre-condition:** verify all green.

**Actions:**

1. Spawn Agent with `subagent_type: reviewer` — full diff review against spec.md
2. Spawn Agent with `subagent_type: security-architect` — final security pass on RLS/auth
3. Present both reviews to user, edit if needed, sign off → run `bash scripts/sprint-predeploy-gate.sh` which updates gates+=pre-deploy

---

### Phase 7 — Deploy (Day 13)

**Pre-condition:** `state.json.phase == pre-deploy`, gates includes pre-deploy.

**Actions:**

1. Run `ruflo workflow execute lifeos-deploy --input branch=sprint/<slug>` which:
   - Bundles Lambdas
   - Runs `pulumi preview --stack Zuzuna54/dev`
   - **PAUSES** for human approval — workflow_pause invoked
2. User reviews preview output → says "proceed"
3. Workflow resume → `pulumi up --stack Zuzuna54/dev --yes`
4. Smoke test
5. `vercel deploy --prod`

**Forbidden during sprint:** even at deploy phase, `git push origin main` (direct push) and `pulumi destroy` are hook-blocked. PR flow only for merging back to main.

---

### Phase 8 — Retro + pattern extract (Day 14)

**Trigger:** `bash scripts/sprint-end.sh <slug>`.

**Actions:**

1. **Generate retro** from session logs:
   - What worked / didn't / surprised (3 prompts to user)
   - Velocity metrics: time-to-design-lock, drift events, scope amendments, AC closure rate
   - Write to `docs/sprints/<slug>/retro.md`
2. **Extract patterns.** Claude reads `spec.md` + `wizard-transcript.md` + `retro.md` and proposes 3-5 reusable patterns (e.g., "lifeos-<feature>-pattern: <recipe>"). User approves each → store via `ruflo memory store --vector --upsert`.
3. **CLAUDE.md sync.** If any pattern is now repo-wide, propose addition to CLAUDE.md (e.g., new convention emerged about RLS on a new table type).
4. **DAA reviewer feedback.** Batch the sprint's PR feedback to the DAA reviewer agent via `mcp__claude-flow__daa_agent_adapt`.
5. **Trajectory close.** `mcp__claude-flow__hooks_intelligence_trajectory-end` with success signal.
6. **Re-enable workers** disabled during sprint: `refactor`, `document` daemon workers re-enabled.
7. **Close GitHub Issue** if created.
8. **Update `metrics.json`** with final sprint metrics.
9. **Update `state.json.phase = done`**.
10. **Train check:** if `sqlite3 .swarm/memory.db "SELECT count(*) FROM trajectories"` ≥ 20 → propose `ruflo neural train --type coordination --epochs 50`.

---

## State machine (deterministic) — v0.7.0+ phase enforcement

```
spec-wizard ─────→ spec-locked ─────→ design-locked ─────→ building
                                                              │
                                       ┌──────────────────────┤
                                       ↓                       ↓
                                  day-5-checkin           (continue)
                                       ↓
                                  building (continued)
                                       ↓
                                  cleaning ─────→ verifying ─────→ pre-deploy ─────→ deploying ─────→ done

Anywhere ─────→ paused ─────→ (resume to previous phase)
```

State is persisted in `docs/sprints/<slug>/state.json`.

### Canonical phase transitions (v0.7.0+)

**Since `harness-deterministic-phases-v1`, `state.phase` is mutated by ONE script only: `scripts/sprint-advance-phase.sh`.** Every other phase-writer (`sprint-amend-spec.sh --lock`, `sprint-design-lock.sh`, `sprint-build-launch.sh`, `sprint-checkin.sh`, `sprint-cleanup-launch.sh`, `sprint-verify.sh`, `sprint-predeploy-gate.sh`, `sprint-end.sh`, `sprint-pause.sh`, `sprint-resume.sh`) delegates the phase write to `sprint-advance-phase.sh` after running its own artifact-build code.

The PreToolUse hook (`.claude/helpers/sprint-hook.cjs`) blocks every other path: inline `jq '.phase = X'`, direct `Edit` on state.json, `sed -i` on state.json, `>` redirects to state.json.

#### Calling sprint-advance-phase.sh between phases

When you (the orchestrator) drive a phase transition, the pattern is:

1. **Do the phase's work** (assemble artifacts, run agents, record sub-steps).
2. **Call `bash scripts/sprint-advance-phase.sh <next-phase>`** — the script reads `scripts/lib/phase-manifest.json`, evaluates per-phase predicates, refuses to advance if any predicate fails.
3. **If predicates fail**, either: (a) fix the missing artifact and re-run, or (b) bypass with `SPRINT_BYPASS_GATE=<name> SPRINT_BYPASS_WHY='<rationale ≥10 chars>'` and re-run.

Each phase's predicates are documented in `docs/sprints/USAGE.md` "## Phase enforcement" table.

Example: completing day-5 check-in and resuming building:

```bash
# 1. Generate the template (records day-5-hill-chart-refreshed sub-step)
bash scripts/sprint-checkin.sh <slug>
# 2. Operator fills check-in-day5.md with real ### Cut / ### Push / ### Pivot answers
# 3. Validate the file content (records day-5-question-cut/push/pivot sub-steps)
bash scripts/sprint-checkin.sh <slug> --validate
# 4. Advance back to building (or forward to cleaning/verifying)
bash scripts/sprint-advance-phase.sh building
```

You (the orchestrator) **must not** write `state.phase` via any other path. The hook will block.

### Bypass procedure (when a predicate genuinely cannot be satisfied)

```bash
SPRINT_BYPASS_GATE=<manifest-gate-name>  \
SPRINT_BYPASS_WHY='<reason ≥10 chars>'   \
  bash scripts/sprint-advance-phase.sh <next-phase>
```

Multi-gate (comma-separated): `SPRINT_BYPASS_GATE='gate1,gate2,gate3'`. Single WHY applies to all.

Bypasses are recorded to `state.gate_bypasses[]` with timestamp + caller. Velocity flags >3 bypasses/sprint as `high-bypass`. See `_guides/bypass-cheatsheet.md` for the full bypass catalog.

---

## Drift control responsibilities (this skill enforces)

When invoked during an active sprint, this skill must:

1. **Refuse out-of-scope edits silently.** If a tool call would touch a file outside `state.json.files_touched`, pause and prompt:
   > "This edit touches `<path>` which is outside the spec's `## Files touched` section. Options: (a) amend spec to include this file (will re-baseline drift), (b) skip this edit, (c) override once with rationale (will be logged for retro)."
2. **Refuse forbidden bash commands.** Block: `git push *` (any target — PR flow only), `pulumi up`, `pulumi destroy`, `rm -rf *`, raw `DELETE FROM` outside test files.
3. **Run drift check on commits.** Every commit invokes `bash scripts/sprint-drift-check.sh`; below 0.75 → pause + prompt with 3 options (amend spec / discard / override).
4. **Honor pause/resume.** If `state.json.phase == paused`, do NOT auto-resume work. Wait for user to run `bash scripts/sprint-resume.sh`.
5. **Auto-trigger pair mode.** When working on an AC flagged `complex: true`, switch to pair-programming DRIVER mode automatically. Announce: "AC-<N> is flagged complex (keywords: <list>). Engaging pair-programming DRIVER mode."

---

## Ruflo features used (full activation map)

| Feature                                                                         | Where in protocol                                                                     |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Memory recall (`memory_search`)                                                 | Phase 0 pre-sprint context, Phase 1 wizard recall augmentation                        |
| Hive-mind (`hive-mind_init/spawn/consensus`)                                    | Phase 1 spec consensus (strategic queen), Phase 3 blocker resolution (tactical queen) |
| Architect / Security-architect subagents                                        | Phase 1 reviews, Phase 6 pre-deploy review                                            |
| SPARC modes (`/sparc:spec-pseudocode`, `/sparc:architect`)                      | Phase 2 design                                                                        |
| Workflows (`workflow_execute`)                                                  | Phase 3 build, Phase 5 verify, Phase 7 deploy                                         |
| Swarm (`swarm_init` hierarchical-mesh, 8 agents)                                | Phase 3 build                                                                         |
| Claims (`claims_claim`)                                                         | Phase 3 build domain ownership                                                        |
| Stream-chain (`/stream-chain`)                                                  | Phase 3 NL/AI-scheduler pipelines                                                     |
| Pair-programming DRIVER mode                                                    | Phase 3 complex ACs                                                                   |
| Autopilot (lint-fix, test-backfill, doc-sweep)                                  | Phase 3 side-cars                                                                     |
| Daemon workers (audit, optimize, testgaps, predict, document, map, consolidate) | Continuous throughout sprint                                                          |
| Embeddings (`embeddings_compare`)                                               | Spec drift baseline + per-commit checks                                               |
| Performance profile (`performance_profile`)                                     | Phase 5 verify                                                                        |
| AIDefence (`aidefence_scan`)                                                    | Phase 5 verify on user-input surfaces                                                 |
| ReasoningBank (`trajectory-start/step/end`)                                     | Whole sprint = one trajectory                                                         |
| DAA reviewer adaptation (`daa_agent_adapt`)                                     | Phase 8 retro batch feedback                                                          |
| SONA real-time adaptation                                                       | Continuous via daemon                                                                 |
| Neural train (`neural train`)                                                   | Phase 8 if ≥20 trajectories accumulated                                               |
| Memory consolidation (`agentdb_consolidate`)                                    | Phase 8 retro                                                                         |
| `agentdb_pattern-store --vector --upsert`                                       | Phase 8 pattern extraction                                                            |
| `hooks_intelligence_trajectory-end`                                             | Phase 8 trajectory close                                                              |
| `aidefence_has_pii`                                                             | Phase 1 wizard input check                                                            |

---

## Companion scripts (you may invoke directly)

| Script                                                             | Purpose                                       |
| ------------------------------------------------------------------ | --------------------------------------------- |
| `bash scripts/sprint-start.sh <slug>`                              | Phase 0 init                                  |
| `bash scripts/sprint-status.sh`                                    | Print current phase, day, gates, drift score  |
| `bash scripts/sprint-pause.sh`                                     | Pause sprint, disable drift-prone workers     |
| `bash scripts/sprint-resume.sh`                                    | Resume from paused state                      |
| `bash scripts/sprint-checkin.sh`                                   | Day-5 hill chart update                       |
| `bash scripts/sprint-amend-spec.sh [--lock\|--cut <ids>\|--pivot]` | Spec amendments                               |
| `bash scripts/sprint-drift-check.sh`                               | Husky pre-commit drift check (called by hook) |
| `bash scripts/sprint-end.sh <slug>`                                | Phase 8 retro + pattern extract               |

---

## What this skill does NOT do

- **Does not write LifeOS code itself.** It delegates to coder/tester/architect agents during build phase.
- **Does not deploy without user approval.** Deploy workflow always pauses at `pulumi preview`.
- **Does not push to main.** PR flow only. `git push` is forbidden during sprint.
- **Does not run mid-sprint.** Daemon's `refactor` and `document` workers are paused at sprint-start (drift risk); re-enabled at sprint-end.

---

## Error recovery

| Failure                     | Action                                                                                            |
| --------------------------- | ------------------------------------------------------------------------------------------------- |
| Wizard interrupted          | `bash scripts/sprint-resume.sh` reads `spec.partial.json` and resumes from last completed section |
| Drift pause unresolved      | Sprint phase stays at `paused`; agent activity blocked until user resolves                        |
| Hive-mind consensus fails   | Present dissenting reasoning, propose spec edits, re-run consensus (do not lock until pass)       |
| Verify phase fails          | Pause at verify, surface failures to user, fix, re-run verify                                     |
| Deploy preview unacceptable | User cancels at pulumi preview pause; workflow halts, sprint stays in `pre-deploy` phase          |

---

## Reference

- Full plan: `/Users/gio/.claude/plans/hazy-gathering-kettle.md`
- Wizard skill: `.claude/skills/sprint-spec-wizard/SKILL.md`
- LifeOS feature map: `docs/ruflo-sessions/ruflo-for-lifeos.md`
- Sprint directory: `docs/sprints/README.md`
