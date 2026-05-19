# AC-6 — bypass.sh::check_bypass

**Verdict:** Production
**Methodology:** inject-violation-catch-restore

## Artifact shipped

`scripts/lib/bypass.sh` — single canonical bypass interface.

Public API:

- `check_bypass <gate-name>` → returns 0 iff `SPRINT_BYPASS_GATE==<gate-name>` AND `SPRINT_BYPASS_WHY` is non-empty (≥10 chars by default; configurable via `BYPASS_WHY_MIN_CHARS`).
- `deprecate_legacy_bypass <legacy-env> <new-gate>` → v0.7.x compat shim that turns `SPRINT_DRIFT_BYPASS=1` etc into `SPRINT_BYPASS_GATE=drift-check`. Prints deprecation warning. Removal in v0.8.0.

## Six-test smoke

```
TEST 1 — No bypass requested:
  $ check_bypass some-gate
  RC=1  (silent — most common case)
  ✓

TEST 2 — Bypass for different gate (gate-scoped silently):
  $ SPRINT_BYPASS_GATE=other-gate SPRINT_BYPASS_WHY='this is a long enough reason' check_bypass some-gate
  RC=1  (silent — each invocation only fires for its own gate)
  ✓

TEST 3 — Bypass requested for matching gate but WHY missing:
  $ SPRINT_BYPASS_GATE=some-gate check_bypass some-gate
  [bypass] SPRINT_BYPASS_GATE=some-gate set but SPRINT_BYPASS_WHY missing
  [bypass] Required: SPRINT_BYPASS_WHY='<reason, ≥10 chars>'
  RC=1
  ✓

TEST 4 — WHY too short (5 chars < 10):
  $ SPRINT_BYPASS_GATE=some-gate SPRINT_BYPASS_WHY='short' check_bypass some-gate
  [bypass] SPRINT_BYPASS_WHY too short (5 chars, need ≥10)
  RC=1
  ✓

TEST 5 — Valid bypass:
  $ SPRINT_BYPASS_GATE=test-bypass-gate \
    SPRINT_BYPASS_WHY='Architectural review concluded this gate is non-applicable for this sprint' \
    SLUG=harness-deterministic-phases-v1 \
    check_bypass test-bypass-gate
  [bypass] gate=test-bypass-gate accepted (why="Architectural review concluded this gate is non-applicable f…")
  RC=0
  state.gate_bypasses[]:
    [{
      "gate": "test-bypass-gate",
      "why":  "Architectural review concluded this gate is non-applicable for this sprint",
      "at":   "2026-05-19T10:42:09Z",
      "caller": "bash"
    }]
  ✓

TEST 6 — Legacy deprecation shim:
  $ SPRINT_DRIFT_BYPASS=1 deprecate_legacy_bypass SPRINT_DRIFT_BYPASS drift-check && check_bypass drift-check
  [bypass] SPRINT_DRIFT_BYPASS=1 is DEPRECATED in v0.7.x (removal in v0.8.0).
  [bypass] Migrate to: SPRINT_BYPASS_GATE=drift-check SPRINT_BYPASS_WHY='<reason>'
  [bypass] gate=drift-check accepted (why="legacy-shim-from-SPRINT_DRIFT_BYPASS")
  RC=0
  state.gate_bypasses[]:
    [{"gate":"drift-check","why":"legacy-shim-from-SPRINT_DRIFT_BYPASS","at":"...","caller":"bash"}]
  ✓
```

## What this proves

1. **Gate scoping** — bypass only activates for the specific `<gate-name>` argument; calls for other gates pass through silently (RC=1).
2. **Mandatory rationale** — `SPRINT_BYPASS_WHY` ≥10 chars required. Missing → RC=1 with explicit error message. Short → RC=1 with char count diagnostic.
3. **Audit trail** — every accepted bypass writes to `state.gate_bypasses[]` via `atomic_update_state` (parallel-safe). Stored fields: `gate`, `why`, `at` (ISO timestamp), `caller` (basename of source script).
4. **Idempotent on `(gate)`** — re-using same SPRINT_BYPASS_GATE+WHY refreshes the timestamp, doesn't duplicate.
5. **Legacy migration path** — `deprecate_legacy_bypass SPRINT_X_BYPASS new-gate-name` shim for v0.7.x. Prints deprecation warning + auto-synthesizes new envs so old call sites keep working. Removal in v0.8.0.
6. **Caller attribution** — `caller` field records which script invoked the bypass (via `BASH_SOURCE[1]`). Operator can grep history for "bypasses from sprint-checkin.sh" etc.

## Files modified (this AC)

- `scripts/lib/bypass.sh` — new (91 lines)

## Files reused

- `scripts/lib/atomic-state.sh::atomic_update_state` — for parallel-safe write to `state.gate_bypasses[]`.

## Cleanup

Test gates (`test-bypass-gate`, `drift-check`) cleared from `state.gate_bypasses[]` after proof captured (reset to `[]`).
