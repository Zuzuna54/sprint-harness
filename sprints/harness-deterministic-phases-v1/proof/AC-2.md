# AC-2 — phase-predicates.sh

**Verdict:** Production
**Methodology:** inject-violation-catch-restore

## Artifact shipped

`scripts/lib/phase-predicates.sh` — predicate engine implementing all 9 predicate kinds:

| Kind                        | Purpose                                                             |
| --------------------------- | ------------------------------------------------------------------- |
| `file_exists`               | Existence test                                                      |
| `file_min_bytes`            | Existence + min size                                                |
| `file_contains_heading`     | Markdown heading exists + ≥N chars of body under it                 |
| `json_path_present`         | jq path resolves non-null                                           |
| `json_path_equals`          | jq path == literal                                                  |
| `json_path_in`              | jq path ∈ array                                                     |
| `state_field_min_length`    | state.json array/string/number ≥ N                                  |
| `state_field_all_values_in` | every value at jq path ∈ array                                      |
| `sub_step_recorded`         | gate name in `state.gates_passed[]` ∪ `state.gates[]` (dual format) |

Public functions: `check_phase_requirements <slug> <phase>` + `sub_step_recorded <slug> <gate>`.

## Bypass integration

If a predicate fails AND `state.gate_bypasses[]` has an entry with `.gate` matching the failing predicate's name → predicate counts as `[BYPASS]` (passes), logged separately from `pass=` and `fail=` counters.

## Three-test smoke

```
TEST 1: empty-requirements phase (paused with prev_phase set)
  $ check_phase_requirements harness-deterministic-phases-v1 paused
  [OK] phase=paused pass=1 bypassed=0 worker_rigor=lax
  RC=0  (PASS as expected)

TEST 2: spec-locked phase with missing 4-way-review artifacts
  $ check_phase_requirements harness-deterministic-phases-v1 spec-locked
  [FAIL] file_min_bytes: solution-sketches.md missing (expected ≥ 200 bytes)
  [FAIL] file_min_bytes: architect-review.md missing (expected ≥ 200 bytes)
  [FAIL] file_min_bytes: security-review.md missing (expected ≥ 200 bytes)
  [FAIL] json_path_in: consensus-spec.json missing
  [FAIL] json_path_in: state.json:.worker_rigor is 'null', expected one of ["lax","strict"]
  [FAIL] sub_step_recorded: gate 'spec-lock-solution-sketches' not in state.gates_passed[]/gates[]
  [FAIL] sub_step_recorded: gate 'spec-lock-architect-review' not in state.gates_passed[]/gates[]
  [FAIL] sub_step_recorded: gate 'spec-lock-security-review' not in state.gates_passed[]/gates[]
  [FAIL] sub_step_recorded: gate 'spec-lock-hive-mind-consensus' not in state.gates_passed[]/gates[]
  [FAIL] sub_step_recorded: gate 'spec-lock-baseline-written' not in state.gates_passed[]/gates[]
  [SUMMARY] phase=spec-locked pass=2 fail=10 bypassed=0 worker_rigor=lax
  RC=1  (FAIL as expected — 10 missing predicates)

TEST 3: spec-locked phase after artifacts + sub-steps recorded
  $ check_phase_requirements harness-deterministic-phases-v1 spec-locked
  [OK] phase=spec-locked pass=12 bypassed=0 worker_rigor=lax
  RC=0  (PASS as expected)
```

## What this proves

1. The engine **identifies missing artifacts by name + minimum size + heading structure** — caller doesn't need to know predicate internals.
2. The engine **identifies missing sub-step gates by name** — instrumentation is checked against the manifest's `required_sub_step_gates[]`.
3. The engine **handles dual-format gates_passed[]** — legacy bare strings and v0.7+ objects normalize correctly (legacy: `"spec-lock"` → `{gate: "spec-lock"}` at read time).
4. The engine **respects bypasses** — if a failing predicate has a matching entry in `state.gate_bypasses[]`, it's counted as `[BYPASS]` not `[FAIL]`. `pass=` + `fail=` + `bypassed=` summary makes intent visible.
5. **worker_rigor=strict** activates `strict_only_sub_step_gates[]` from the manifest (verifying-phase: `verify-worker-map-refreshed`, `verify-worker-consolidate-refreshed`). When `worker_rigor=lax` those are silently skipped.

## Files modified (this AC)

- `scripts/lib/phase-predicates.sh` — new (358 lines)

## Files modified for the proof (sprint workspace, not part of harness)

- `docs/sprints/harness-deterministic-phases-v1/solution-sketches.md` — placeholder (569 bytes)
- `docs/sprints/harness-deterministic-phases-v1/architect-review.md` — placeholder (857 bytes)
- `docs/sprints/harness-deterministic-phases-v1/security-review.md` — placeholder (638 bytes)
- `docs/sprints/harness-deterministic-phases-v1/consensus-spec.json` — `{verdict:"pass"}`
- `docs/sprints/harness-deterministic-phases-v1/state.json` — 5 sub-step entries appended to `gates_passed[]` + `worker_rigor: "lax"`
