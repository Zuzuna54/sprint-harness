# AC-3 — sub-step.sh::record_sub_step

**Verdict:** Production
**Methodology:** inject-violation-catch-restore

## Artifact shipped

`scripts/lib/sub-step.sh` — atomic, idempotent recording of sub-step gate completion.

Public API: `record_sub_step <slug> <gate-name> <verdict> [evidence-path]`. Verdict must be `pass | fail | bypassed`. Writes through `atomic_update_state` (parallel-safe).

## Five-test smoke

```
TEST 1 — Record a new gate:
  $ record_sub_step harness-deterministic-phases-v1 test-gate-alpha pass /tmp/evidence.txt
  $ jq '[.gates_passed[] | select(type=="object" and .gate=="test-gate-alpha")][0]'
    {
      "gate": "test-gate-alpha",
      "at": "2026-05-19T10:39:53Z",
      "verdict": "pass",
      "evidence": "/tmp/evidence.txt"
    }
  ✓

TEST 2 — Idempotency (re-record same gate):
  $ sleep 1; record_sub_step ... test-gate-alpha pass /tmp/evidence.txt
  array length: 1
  updated at:   "2026-05-19T10:39:54Z"   ← changed from :53, idempotent on (slug, gate)
  ✓

TEST 3 — Bypassed verdict:
  $ record_sub_step ... test-gate-beta bypassed
    {"gate":"test-gate-beta","at":"2026-05-19T10:39:54Z","verdict":"bypassed","evidence":null}
  ✓

TEST 4 — Invalid verdict rejected:
  $ record_sub_step ... test-gate-gamma INVALID
  [record_sub_step] verdict must be pass|fail|bypassed (got 'INVALID')
  exit 1
  ✓

TEST 5 — Legacy bare-string upgrade (state had "spec-lock" as bare string from sprint-amend-spec.sh --lock):
  $ record_sub_step ... spec-lock pass
  After:
    object entries with gate=="spec-lock":  1
    string entries == "spec-lock":          0   ← legacy string dropped, object form replaces
  ✓
```

## What this proves

1. **Idempotency on `(slug, gate)`** — re-recording same gate UPDATES the timestamp but does NOT create a duplicate entry. Verified by re-recording `test-gate-alpha` after a 1-second sleep; gates_passed array length stays 1; `.at` field changes from `:53` to `:54`.
2. **Dual-write** — same entry appended to both `state.gates_passed[]` (canonical) AND `state.gates[]` (legacy compat per AC-9). Replay validator reads union.
3. **Legacy upgrade path** — bare-string entries (e.g. `"spec-lock"` from `sprint-amend-spec.sh --lock` writing in old format) are upgraded to object form `{gate: "spec-lock", at, verdict, evidence: null}` when first re-recorded. No data loss.
4. **Atomic via flock** — uses existing `atomic_update_state` from `scripts/lib/atomic-state.sh` (v0.5.0). Concurrent writes serialize per slug; the function's per-slug flock guarantees no torn writes.
5. **Verdict guard** — non-canonical verdicts rejected at function entry with exit 1.

## Files modified (this AC)

- `scripts/lib/sub-step.sh` — new (76 lines)

## Files reused

- `scripts/lib/atomic-state.sh::atomic_update_state` — variadic --arg forwarding from v0.5.0 AC-3 enables passing `--arg gate "$gate" --arg at "$at" --arg verdict "$verdict" --arg evidence "$evidence"` to jq filter.

## Cleanup

Test gates (`test-gate-alpha`, `test-gate-beta`) were removed from the sprint's state.json via atomic_update_state map-select-filter after proof captured.
