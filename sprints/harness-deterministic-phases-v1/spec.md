# Sprint harness-deterministic-phases-v1: Deterministic phase enforcement

## Status

- **Phase:** spec-wizard
- **Day:** 0 of 14
- **Started:** 2026-05-19
- **Gates passed:** []
- **Drift score (latest):** null
- **Wizard sections captured:** A, B, C, D, E, F, G, H, I, J (driven from approved plan `~/.claude/plans/hazy-gathering-kettle.md`)

---

## §A — Problem & Vision

### Problem statement

The sprint harness has 8 mechanical phase-progression gates today (spec-lock, design-lock, drift-on-commit, scope-on-edit, duplication, verify-workers, pre-deploy, deploy HUMAN PAUSE). The other ~32 documented steps in `lib/templates/sprints/USAGE.md` — wizard sections, 4-way review, day-5 check-in, cleanup, retro patterns, DAA feedback, velocity, every code-quality sub-check (sonar, knip dead-code, cycle-check, audit-deps, bundle-budget, coverage-delta, migration-check) — are **prose-only**. The orchestrator skill describes them; nothing refuses to advance the sprint when one is skipped.

Observed in real sprints (harness-portability-v1/v2 retros, sprint-system-100 retro 38/20/42 verdict, recent harness-parallel-safety-v2 dogfood): the model under token pressure or autopilot skips sub-steps and the protocol still reports complete. State.json reaches `phase=done` without proof every required gate fired.

### Who suffers

- **Operator (Gio)** — reads "Sprint closed, 14/14 ACs Production" and trusts the verdict, but model skipped retro pattern extraction or skipped a verify-chain command and the audit trail doesn't show it.
- **Future contributors** — read the protocol prose in USAGE.md, copy it, find half the steps optional in practice; documentation rots into folklore.
- **Future Claude sessions** — recall the orchestrator skill, see "do X then Y then Z" prose, treat it as advisory because nothing actually blocks Z when Y was skipped.

### Why now

We just shipped parallel-safety-v2 (v0.5.0) and workers-on-demand (v0.6.0). Both surfaced real cases of "the model did N-1 of N steps and we only noticed in retro." The primitives needed for deterministic gating (atomic_update_state, session-file, lock-dir) all landed in v0.5.0. The cost of building deterministic phase enforcement now is much lower than the recurring cost of partial-protocol sprints.

### Strategic fit

Core promise of the harness: "you make decisions at 5 gates; everything else is enforced." Today 5 gates are enforced; 32+ sub-steps are not. This sprint closes the gap and makes the promise true.

### Success vision

After this sprint: every USAGE.md step has either a mechanical gate or an explicit `SPRINT_BYPASS_GATE=<name> SPRINT_BYPASS_WHY=<reason>` audit entry. CI replay validator asserts every closed sprint's `gate_history` is monotonic and complete. The model cannot reach `phase=done` while skipping required gates — the canonical phase mutator (`sprint-advance-phase.sh`) refuses to advance until the current phase's manifest is satisfied. Operator can trust "phase=done" as proof of protocol completion, not aspirational.

---

## §B — Business Logic & Domain Rules

### Entities

- **Phase** — enum: `spec-wizard | spec-locked | design-locked | building | day-5-checkin | cleaning | verifying | pre-deploy | deploying | done | paused`.
  - **Transitions:** governed by `phase-manifest.json:<phase>.advances_to`. ONLY `sprint-advance-phase.sh` can mutate `state.phase`.
- **Gate** — named precondition. Identified by a string slug (`spec-lock-solution-sketches`, `verify-typecheck`, `retro-pattern-1`, etc.). Has one of: `verdict=pass`, `verdict=bypassed`, or absent (= not satisfied).
- **Sub-step** — granular gate within a phase. Recorded via `record_sub_step <slug> <gate-name> <verdict> [evidence]`.
- **Bypass** — explicit audited skip of a single gate. Requires `SPRINT_BYPASS_GATE=<name>` AND `SPRINT_BYPASS_WHY=<reason ≥10 chars>`. Logged to `state.gate_bypasses[]`.

### Invariants

- Inv 1: `state.phase` is mutated by exactly one script: `sprint-advance-phase.sh`. PreToolUse hook blocks every other path (inline jq, direct Edit on state.json).
- Inv 2: A phase advance succeeds iff `check_phase_requirements <slug> <current_phase>` returns 0 for ALL predicates in `phase-manifest.json:<current_phase>` — OR each failing predicate is explicitly bypassed via `SPRINT_BYPASS_GATE`.
- Inv 3: Every entry in `state.gate_history[]` is monotonic by ISO timestamp. Replay validator asserts.
- Inv 4: Every gate name in `state.gates_passed[]` and `state.gate_bypasses[]` must match a string declared in `phase-manifest.json`. Unknown gate names = replay failure.
- Inv 5: `state.worker_rigor` is `lax` (default) or `strict`. Set once at spec-lock. `strict` makes additional worker outputs required predicates.
- Inv 6: `record_sub_step` is idempotent on `(slug, gate-name)` — re-recording the same gate updates timestamp, doesn't duplicate.
- Inv 7: All today's `SPRINT_*_BYPASS=1` envs emit a deprecation warning but still work in v0.7.x. Removed in v0.8.0.

### Calculations / aggregations

- `phase-predicates.sh::check_phase_requirements`: load manifest entry → iterate predicates → return 0 iff all pass or all failures have matching bypass entries.
- `sprint-system-test.sh --replay-gate-history`: for each closed sprint, assert `gates_passed[] ∪ gate_bypasses[].gate ⊇ ⋃(phase.required_sub_step_gates for phase in walked_path)`.

### Edge cases

- Edge 1: `SPRINT_BYPASS_GATE` set but `SPRINT_BYPASS_WHY` missing → exit 1 with `[bypass] WHY missing or <10 chars`.
- Edge 2: Re-running `sprint-advance-phase.sh design-locked` when phase is already `design-locked` → idempotent no-op, exits 0.
- Edge 3: Sprint closed before v0.7.0 release → replay validator skips by default (`--ignore-pre <date>` flag).
- Edge 4: `worker_rigor=strict` + worker timed out → verify gate fails fatal (vs lax advisory).
- Edge 5: `phase-manifest.json` has a typo in a sub-step gate name → schema validator catches at script start; advance-phase exits 1.
- Edge 6: Two concurrent sprints call `sprint-advance-phase.sh` simultaneously → per-slug flock from `atomic_update_state` serializes.

---

## §C — Data & Schema

### State.json fields (additive — no migration required)

```json
{
  "phase_requirements": { "loaded_from": "lib/scripts/lib/phase-manifest.json", "version": "1.0.0" },
  "worker_rigor": null,            // set at spec-lock to "lax" or "strict"
  "gates_passed": [                // already exists; extended
    { "gate": "spec-lock-solution-sketches", "at": "2026-05-19T11:00:00Z", "evidence": "solution-sketches.md", "verdict": "pass" }
  ],
  "gate_bypasses": [               // already exists; extended
    { "gate": "verify-sonar", "why": "sonar container down", "at": "...", "caller": "sprint-advance-phase.sh" }
  ],
  "gate_history": [                // already exists; canonical phase-transition log
    { "from": "spec-wizard", "to": "spec-locked", "at": "...", "gates_satisfied": [...], "bypasses": [...] }
  ]
}
```

No new tables. No DB migrations. Pure JSON schema in state.json.

### Relationships

- `phase-manifest.json` = source of truth for valid gate names + per-phase requirements.
- `state.gates_passed[].gate` MUST match a gate name in `phase-manifest.json` (asserted by replay validator).
- `state.gate_bypasses[].gate` MUST match a gate name in `phase-manifest.json`.
- `state.gate_history[].from → state.gate_history[].to` MUST appear in `phase-manifest.json:<from>.advances_to`.

### RLS policies

N/A — file-based state.json, not a database table.

---

## §D — API Surface

### New scripts (bash + node)

| Script                                   | Purpose                                                                 |
| ---------------------------------------- | ----------------------------------------------------------------------- |
| `scripts/sprint-advance-phase.sh`        | The canonical phase mutator. ONLY caller of `.phase = X` jq filter.     |
| `scripts/lib/phase-manifest.json`        | Per-phase required artifacts / state fields / sub-step gate names.      |
| `scripts/lib/phase-manifest.schema.json` | JSON schema for manifest format validation.                             |
| `scripts/lib/phase-predicates.sh`        | `check_phase_requirements <slug> <phase>` — predicate engine.           |
| `scripts/lib/sub-step.sh`                | `record_sub_step <slug> <gate-name> <verdict> [evidence]` — idempotent. |
| `scripts/lib/bypass.sh`                  | `check_bypass <gate>` — enforces `SPRINT_BYPASS_GATE` + `_WHY`.         |

### Modified scripts (all delegate phase write to advance-phase.sh)

- `scripts/sprint-start.sh` — init `phase_requirements`, `worker_rigor=null`
- `scripts/sprint-amend-spec.sh` (`--lock`) — delegate
- `scripts/sprint-design-lock.sh` — delegate
- `scripts/sprint-build-launch.sh` — delegate + per-AC commit recording
- `scripts/sprint-checkin.sh` — delegate + 3-sentinel-heading enforcement
- `scripts/sprint-cleanup-launch.sh` — delegate + 3-sub-step recording
- `scripts/sprint-verify.sh` — delegate + 18-entry verify-chain recording
- `scripts/sprint-predeploy-gate.sh` — delegate
- `scripts/sprint-end.sh` — delegate + retro completeness + 9 sub-step recordings
- `scripts/sprint-pause.sh` — delegate
- `scripts/sprint-resume.sh` — delegate
- `scripts/sprint-spec-wizard.mjs` — 14 wizard sub-step recordings
- `scripts/sprint-rebaseline.sh` — drift-baseline sub-step
- `scripts/sprint-wizard-assemble.mjs` — writes `worker_rigor`
- `scripts/sprint-system-test.sh` — `--replay-gate-history` mode + doc-vs-manifest drift check

### Hook modifications

- `.claude/helpers/sprint-hook.cjs` — Bash regex blocks `jq … .phase = …` unless `SPRINT_ADVANCE_PHASE_RUNNING=1` AND parent process resolves to `sprint-advance-phase.sh`. Write/Edit path-prefix blocks any direct edit of `docs/sprints/*/state.json`.

---

## §E — UI Components & Pages

Skipped — backend-only sprint per §A. No UI changes.

---

## §F — UX Flow & Interactions

Operator-facing UX changes are CLI-level:

1. Operator runs `sprint-advance-phase.sh design-locked` (or scripts delegating to it like `sprint-design-lock.sh`).
2. If manifest pass: phase advances, `gate_history[]` entry written, exit 0.
3. If manifest fail: stderr prints `[FAIL] <predicate>: <expected> vs <actual>` per failing predicate; exit 1.
4. Operator either: (a) satisfies the predicate (write missing file, complete missing sub-step) and re-runs, or (b) sets `SPRINT_BYPASS_GATE=<name> SPRINT_BYPASS_WHY="<reason ≥10 chars>"` and re-runs.

Coherence check at §F: this UX is identical to today's `sprint-design-lock.sh` and `sprint-predeploy-gate.sh` — same `exit 1 with predicate trace` pattern. Operators already trained on this idiom.

---

## §G — Visual Design & Brand

Skipped — no UI, no design tokens, no brand surface.

---

## §H — Integration Points

### Files touched

Path list governs PreToolUse Write/Edit scope hook. **Must be explicit and complete** for drift+scope enforcement.

```
scripts/sprint-advance-phase.sh
scripts/lib/phase-manifest.json
scripts/lib/phase-manifest.schema.json
scripts/lib/phase-predicates.sh
scripts/lib/sub-step.sh
scripts/lib/bypass.sh
scripts/sprint-start.sh
scripts/sprint-amend-spec.sh
scripts/sprint-design-lock.sh
scripts/sprint-build-launch.sh
scripts/sprint-checkin.sh
scripts/sprint-cleanup-launch.sh
scripts/sprint-verify.sh
scripts/sprint-predeploy-gate.sh
scripts/sprint-end.sh
scripts/sprint-pause.sh
scripts/sprint-resume.sh
scripts/sprint-spec-wizard.mjs
scripts/sprint-rebaseline.sh
scripts/sprint-wizard-assemble.mjs
scripts/sprint-system-test.sh
.claude/helpers/sprint-hook.cjs
.claude/skills/sprint-spec-wizard/sections/J-risks.md
.claude/skills/sprint-orchestrator/SKILL.md
docs/sprints/USAGE.md
docs/sprints/DEVELOPER.md
docs/sprints/_guides/bypass-cheatsheet.md
docs/sprints/_guides/sub-step-coverage.md
docs/sprints/_template/spec.md
docs/sprints/harness-deterministic-phases-v1/spec.md
docs/sprints/harness-deterministic-phases-v1/design.md
docs/sprints/harness-deterministic-phases-v1/solution-sketches.md
docs/sprints/harness-deterministic-phases-v1/architect-review.md
docs/sprints/harness-deterministic-phases-v1/security-review.md
docs/sprints/harness-deterministic-phases-v1/consensus-spec.json
docs/sprints/harness-deterministic-phases-v1/retro.md
docs/sprints/harness-deterministic-phases-v1/check-in-day5.md
docs/sprints/harness-deterministic-phases-v1/state.json
docs/sprints/harness-deterministic-phases-v1/proof/AC-1.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-2.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-3.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-4.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-5.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-6.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-7.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-8.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-9.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-10.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-11.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-12.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-13.md
docs/sprints/harness-deterministic-phases-v1/proof/AC-14.md
```

Sprint-harness mirror at `~/Desktop/sprint-harness/lib/...` — synced via `scripts/sync-mirror.sh` per AC-9 contract from harness-parallel-safety-v2.

### External integrations

- ruflo daemon — worker triggers (already integrated via `worker-trigger.sh` from v0.6.0). No new ruflo surfaces.
- GitHub Actions — `.github/workflows/test.yml` extended to run replay validator on every PR.
- husky — no new hooks; existing pre-commit/pre-push/post-commit/post-merge stay.

### Modules

| Module                                  | Role                                                               |
| --------------------------------------- | ------------------------------------------------------------------ |
| `scripts/lib/atomic-state.sh`           | Foundation primitive — every state write goes through it           |
| `scripts/lib/session-file.sh`           | Slug resolution chain v2                                           |
| `scripts/lib/lock-dir.sh`               | Per-slug + git-index flock dir                                     |
| `scripts/lib/phase-manifest.json` (NEW) | Source of truth for required gates per phase                       |
| `scripts/lib/phase-predicates.sh` (NEW) | Predicate engine — file_exists, json_path, sub_step_recorded, etc. |
| `scripts/lib/sub-step.sh` (NEW)         | Atomic recording of sub-step completion                            |
| `scripts/lib/bypass.sh` (NEW)           | `SPRINT_BYPASS_GATE` + `_WHY` enforcement                          |
| `scripts/sprint-advance-phase.sh` (NEW) | Canonical phase mutator                                            |
| `.claude/helpers/sprint-hook.cjs`       | PreToolUse blocker for unauthorized state.phase mutation           |

---

## §I — Acceptance Criteria

14 ACs across 4 waves. Two-verdict policy: Production OR Broken-with-followup-AC. Each AC requires inject-violation-catch-restore proof at `docs/sprints/harness-deterministic-phases-v1/proof/AC-N.md`.

### Wave 1 — Foundation (Days 1-3)

**AC-1** `complex: false` — `scripts/lib/phase-manifest.json` ships with full manifest for all 10 phases. JSON-schema-validated against `scripts/lib/phase-manifest.schema.json`. 40+ named sub-step gates enumerated. **Production proof:** corrupt a gate name in manifest → schema validator catches at script start → exit 1.

**AC-2** `complex: false` — `scripts/lib/phase-predicates.sh::check_phase_requirements <slug> <phase>` returns 0/1 with `[FAIL] <predicate>: <expected> vs <actual>` lines on stderr per failing predicate. **Production proof:** invoke with missing artifact → expect `[FAIL] file_exists: solution-sketches.md` + exit 1.

**AC-3** `complex: false` — `scripts/lib/sub-step.sh::record_sub_step` idempotent on `(slug, gate-name)`. **Production proof:** call twice for same `(slug, gate)` → state.gates_passed[] has 1 entry with updated `at`.

**AC-4** `complex: true` (auth/state-mutation keyword) — `scripts/sprint-advance-phase.sh <next-phase>` is canonical mutator. Sets `SPRINT_ADVANCE_PHASE_RUNNING=1`. **Production proof:** happy path (clean spec-locked) → advances; missing artifact → exits 1 with predicate trace; bypass → records to `gate_bypasses[]`.

**AC-5** `complex: true` (PreToolUse / auth) — `.claude/helpers/sprint-hook.cjs` blocks (a) Bash `jq ... .phase = ...` unless env+ppid match, (b) Write/Edit on `docs/sprints/*/state.json` always. **Production proof:** inject malicious jq command → hook exits 2 with block message.

**AC-6** `complex: false` — `scripts/lib/bypass.sh::check_bypass <gate>` requires `SPRINT_BYPASS_GATE` + `SPRINT_BYPASS_WHY` (≥10 chars). **Production proof:** missing `_WHY` → exit 1; empty `_WHY` → exit 1; valid → records to `gate_bypasses[]`.

### Wave 2 — Migrate phase-writers (Days 4-7)

**AC-7** `complex: false` — Refactor 11 scripts to delegate phase write. `grep -nE "\.phase\s*=" scripts/` returns ONLY hits inside `sprint-advance-phase.sh`. **Production proof:** grep result attached to proof file.

**AC-8** `complex: false` — Per-sub-step instrumentation (50+ named gates). Coverage map at `docs/sprints/_guides/sub-step-coverage.md`. **Production proof:** run full sprint synthetic walk → assert every manifest sub-step appears in `state.gates_passed[]`.

**AC-9** `complex: false` — Schema unification dual-write (`gates` + `gates_passed`). Loader reads union. **Production proof:** synthetic old-format sprint passes replay; new sprint writes both fields.

### Wave 3 — Worker rigor + wizard (Days 8-9)

**AC-10** `complex: false` — Wizard §J adds `J.worker_rigor` question. `state.worker_rigor` populated at spec-lock. **Production proof:** wizard answer "strict" → state.worker_rigor=="strict" + verify gate requires all worker outputs.

**AC-11** `complex: false` — `sprint-checkin.sh` enforces 3 sentinel headings (`### Cut` / `### Push` / `### Pivot`) ≥30 chars each. **Production proof:** missing one heading → exit 1.

### Wave 4 — Retro + replay + docs (Days 10-12)

**AC-12** `complex: false` — `sprint-end.sh` enforces retro.md required sections + ≥3 patterns + metrics.json + dashboard.html + DAA + trajectory + velocity. **Production proof:** missing pattern → exit 1.

**AC-13** `complex: true` (CI gate / replay) — `sprint-system-test.sh --replay-gate-history`. CI-wired. Asserts monotonic + complete + valid-bypass + doc-vs-manifest drift. **Production proof:** synthetic incomplete sprint → replay exits 1.

**AC-14** `complex: false` — Documentation: USAGE.md "## Phase enforcement" + DEVELOPER.md extension guide + bypass-cheatsheet rewrite + SKILL.md calls advance-phase.sh. **Production proof:** doc-vs-manifest drift validator passes.

---

## §J — Risks, Security, Rollback

### Worker rigor (per AskUserQuestion decision)

**worker_rigor: lax** for this sprint. Rationale: this is harness infrastructure, not a feature-rich sprint with code-quality-heavy verify. Audit + testgaps gates (today's default) are sufficient.

### Security risks

1. **`SPRINT_ADVANCE_PHASE_RUNNING=1` env spoofable by model.** Mitigation: hook ALSO checks `process.ppid` resolves to `sprint-advance-phase.sh`. Belt + suspenders.
2. **`SPRINT_BYPASS_GATE` abuse.** Mitigation: every bypass surfaced in dashboard.html + retro.md auto-fill + velocity script flags >3 bypasses as "high-bypass" sprint.
3. **PreToolUse hook block on jq could break legitimate tooling.** Mitigation: pattern matches ONLY `\.phase\s*=` (specific to state.phase mutation), not all jq.
4. **state.json edit-block could break operator debugging.** Mitigation: temporary `SPRINT_BYPASS_GATE=state-edit SPRINT_BYPASS_WHY=...` allowed but logged.

### Operational risks

1. **Existing closed sprints fail replay validator.** Mitigation: `--ignore-pre <date>` flag; default ignores pre-v0.7.0.
2. **Phase manifest drifts from USAGE.md.** Mitigation: AC-13 sub-clause (d) — replay validator asserts every gate name in USAGE.md "## Phase enforcement" matches a manifest entry.
3. **`worker_rigor=strict` adds time when workers stall.** Mitigation: per-worker 10-min timeout from v0.6.0 stays.
4. **Schema migration (`gates` → `gates_passed`) breaks third-party tooling.** Mitigation: dual-write for v0.7.x; removal v0.8.0.

### Rollback strategy

Per-AC reverts:

- AC-1..6 (foundation): `git revert <sha>` — new scripts deleted, no callers reference them yet (Wave 1 isolated).
- AC-7 (delegation): `git revert <sha>` — phase-writers restore inline `state.phase = X`. Works against old state.json.
- AC-8 (sub-steps): `git revert <sha>` — instrumentation removed; sub-step gates become empty.
- AC-13 (CI replay): unwire from `.github/workflows/test.yml` without code revert.
- Full rollback: revert all sprint commits + reset `package.json` from 0.7.0 → 0.6.0.

State.json forward-compatibility: new fields (`phase_requirements`, `worker_rigor`, `gate_history` extensions) are ADDITIVE. Old scripts ignore them. Rollback doesn't break already-active sprints.

### Open questions (spike-during-build)

1. PreToolUse hook ppid resolution on macOS — `process.ppid` works in Node; need to verify the parent script name extraction is reliable across shells. Spike in AC-5 first iteration.
2. Sub-step idempotency under concurrent calls — `atomic_update_state` per-slug flock should serialize, but worth a 2-process race test in AC-3.
3. Manifest JSON schema validation library — use `ajv` (npm) or roll a minimal validator in bash? Decide at AC-1 build time based on whether ajv is already in the harness package.json.
4. Whether to relocate this sprint's dir from lifeos `docs/sprints/` to sprint-harness `lib/docs/sprints/` at end. Per current convention sprints live in lifeos; mirror to sprint-harness at completion. Re-decide at retro.

---

## Amendments

(none yet)
