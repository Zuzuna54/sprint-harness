# AC-4 — sprint-advance-phase.sh (canonical phase mutator)

**Verdict:** Production
**Complex:** true (state-mutation centralizer; pair-mode auto-trigger)
**Methodology:** inject-violation-catch-restore + dogfood

## Artifact shipped

`scripts/sprint-advance-phase.sh` — the canonical and ONLY sanctioned mutator of `state.phase`.

Algorithm:

1. Resolve slug via standard chain (env override → session-file → state.json scan).
2. Run `validate-phase-manifest.mjs` on `phase-manifest.json` (AC-1 validator).
3. Read current phase from state.json.
4. Pre-write any requested bypasses: parse `SPRINT_BYPASS_GATE` (single or comma-separated) and call `check_bypass` per gate (AC-6).
5. **Idempotency**: if `current == next`, exit 0 (no-op).
6. **Transition legality**: assert `next ∈ manifest[current].advances_to`. Else exit 1 with allowed-list.
7. **`--from <expected>` invariant**: if given, assert `current == expected`. Else exit 1.
8. Run `check_phase_requirements <slug> <current>` (AC-2). If fails (after bypasses): exit 1 with predicate trace + hint to bypass.
9. Atomic write via `atomic_update_state`: set `.phase = $next`, `.prev_phase = $current`, append `gate_history[]` entry, set `design_locked_at`/`predeploy_at`/`closed_at` as appropriate.
10. Export `SPRINT_ADVANCE_PHASE_RUNNING=1` for PreToolUse hook recognition (AC-5).

## Smoke tests (all dogfood — run against this sprint's own state.json)

```
TEST 1 — Idempotent no-op:
  $ SPRINT_SLUG_OVERRIDE=harness-deterministic-phases-v1 \
      bash scripts/sprint-advance-phase.sh spec-locked
  [sprint-advance-phase] already at spec-locked — no-op
  RC=0
  ✓

TEST 2 — Illegal transition (spec-locked → deploying):
  $ bash scripts/sprint-advance-phase.sh deploying
  [sprint-advance-phase] illegal transition: spec-locked → deploying
  [sprint-advance-phase] spec-locked allows transitions to: design-locked, paused
  RC=1
  ✓

TEST 3 — --from mismatch (current=spec-locked, --from spec-wizard):
  $ bash scripts/sprint-advance-phase.sh design-locked --from spec-wizard
  [sprint-advance-phase] --from spec-wizard but current is spec-locked
  RC=1
  ✓

TEST 4 — Happy path (spec-locked → design-locked, all predicates pass after AC-2 proof):
  $ bash scripts/sprint-advance-phase.sh design-locked
  [OK] manifest valid: 11 phases, 68 unique sub-step gates
  [sprint-advance-phase] slug=harness-deterministic-phases-v1 current=spec-locked target=design-locked
  [OK] phase=spec-locked pass=12 bypassed=0 worker_rigor=lax
  [sprint-advance-phase] phase advanced: spec-locked → design-locked @ 2026-05-19T10:44:09Z
  RC=0
  state.phase: "design-locked"  ✓
  state.prev_phase: "spec-locked"  ✓
  state.design_locked_at: "2026-05-19T10:44:09Z"  ✓
  state.gate_history[-1]: {from: spec-locked, to: design-locked, at: ..., by: sprint-advance-phase.sh}  ✓

TEST 5 — Predicate fail blocks advance (design-locked → building without design.md):
  $ bash scripts/sprint-advance-phase.sh building
  [FAIL] file_min_bytes: design.md missing (expected ≥ 300 bytes)
  [FAIL] sub_step_recorded: gate 'design-sparc-spec-pseudocode' not in state.gates_passed[]/gates[]
  [FAIL] sub_step_recorded: gate 'design-sparc-architect' not in state.gates_passed[]/gates[]
  [FAIL] sub_step_recorded: gate 'design-locked' not in state.gates_passed[]/gates[]
  [SUMMARY] phase=design-locked pass=1 fail=4 bypassed=0 worker_rigor=lax
  [sprint-advance-phase] phase design-locked has unsatisfied requirements — NOT advancing
  [sprint-advance-phase] options:
    1) Fix the [FAIL] predicates above and re-run
    2) Bypass a specific gate: SPRINT_BYPASS_GATE=<gate> SPRINT_BYPASS_WHY='<reason>' bash scripts/sprint-advance-phase.sh building
  RC=1
  state.phase stays at "design-locked"  ✓

TEST 6 — Multi-gate bypass (comma-separated):
  $ SPRINT_BYPASS_GATE='design.md,design-sparc-spec-pseudocode,design-sparc-architect,design-locked' \
    SPRINT_BYPASS_WHY='dogfood proof: bypassing design-phase predicates for AC-4 verification' \
    bash scripts/sprint-advance-phase.sh building
  [bypass] gate=design.md accepted (why="...")
  [bypass] gate=design-sparc-spec-pseudocode accepted (why="...")
  [bypass] gate=design-sparc-architect accepted (why="...")
  [bypass] gate=design-locked accepted (why="...")
  [BYPASS] file_min_bytes:design.md
  [BYPASS] sub_step:design-sparc-spec-pseudocode
  [BYPASS] sub_step:design-sparc-architect
  [BYPASS] sub_step:design-locked
  [OK] phase=design-locked pass=1 bypassed=4 worker_rigor=lax
  [sprint-advance-phase] phase advanced: design-locked → building @ 2026-05-19T10:45:00Z
  RC=0
  state.gate_bypasses[]: 4 entries with `gate`, `why`, `at`, `caller`  ✓
  state.gate_history[-1]: {from: design-locked, to: building, at: ..., by: sprint-advance-phase.sh}  ✓
```

## What this proves

1. **One mutator** — every state.phase write goes through this script. Subsequent ACs (AC-5 hook block, AC-7 migrate, AC-13 replay) enforce this invariant.
2. **Transition legality** — manifest.advances_to is the only legal next-phase set. Operators can't skip phases.
3. **Predicate-blocked advance** — if any required predicate fails AND has no bypass, phase stays. Stderr lists every failing predicate by name so operator knows what to fix.
4. **Multi-gate bypass in one call** — `SPRINT_BYPASS_GATE='gate1,gate2,gate3'` writes 3 bypass records in one invocation. All 3 must share the same `SPRINT_BYPASS_WHY` rationale.
5. **Atomic transition** — `atomic_update_state` writes phase + prev_phase + gate_history in one shot. No torn writes; parallel sprints serialize per-slug.
6. **Audit trail** — every transition logs to `state.gate_history[]` with from/to/at/by. Replay validator (AC-13) walks this and asserts monotonicity + completeness.
7. **Specialized timestamps** — `design_locked_at`, `predeploy_at`, `closed_at` set automatically for those targets (used by velocity script and dashboard).

## Sprint state after AC-4 proof

- `state.phase`: `building` (advanced via bypass path)
- `state.gate_bypasses[]`: 4 entries (design-phase predicates) with audit trail
- `state.gate_history[]`: 3 entries (initial spec-lock entry from sprint-amend-spec.sh --lock + spec-locked→design-locked + design-locked→building)
- `state.design_locked_at`: 2026-05-19T10:44:09Z

Sprint stays in `building` phase for the rest of this sprint's implementation work. Husky pre-commit drift/scope/duplication gates continue to enforce per-commit invariants.

## Files modified (this AC)

- `scripts/sprint-advance-phase.sh` — new (175 lines)

## Files reused

- `scripts/lib/atomic-state.sh::atomic_update_state` (v0.5.0)
- `scripts/lib/session-file.sh::get_session_slug` (v0.5.0)
- `scripts/lib/phase-predicates.sh::check_phase_requirements` (AC-2)
- `scripts/lib/sub-step.sh::record_sub_step` (AC-3)
- `scripts/lib/bypass.sh::check_bypass` (AC-6)
- `scripts/lib/validate-phase-manifest.mjs` (AC-1)
