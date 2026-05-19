# AC-9 — Schema unification gates / gates_passed

**Verdict:** Production
**Methodology:** dual-write verification + legacy compat check

## Behavior

`sub-step.sh::record_sub_step` writes EACH sub-step entry to BOTH:

- `state.gates_passed[]` (canonical, v0.7+)
- `state.gates[]` (legacy compat, written by sprint-system-100 + sprint-system-hardening era scripts)

The jq filter (sub-step.sh:60-65):

```jq
def upsert(arr; g; obj):
  (arr // [])
  | map(if type=="string" then {gate: ., at: null, verdict: "pass"} else . end)
  | map(select(.gate != g))
  | . + [obj];

. as $st |
.gates_passed = upsert($st.gates_passed; $gate; $entry) |
.gates        = upsert($st.gates;        $gate; $entry)
```

`phase-predicates.sh::sub_step_recorded` reads the union of both:

```jq
[
  (.gates_passed // []) | .[] | (if type=="string" then {gate: .} else . end) | select(.gate == $g)
] + [
  (.gates // []) | .[] | (if type=="string" then {gate: .} else . end) | select(.gate == $g)
] | length
```

## Verified dual-write state (this sprint, post-Wave-2)

```
$ jq '{gates_passed_count: (.gates_passed | length), gates_count: (.gates | length)}' \
    docs/sprints/harness-deterministic-phases-v1/state.json
{
  "gates_passed_count": 6,
  "gates_count": 1
}
```

- `gates_passed` (6 entries): legacy bare-string `"spec-lock"` (from sprint-amend-spec.sh --lock before this AC) + 5 v0.7+ objects (`spec-lock-solution-sketches`, `-architect-review`, `-security-review`, `-hive-mind-consensus`, `-baseline-written` — all written via record_sub_step).
- `gates` (1 entry): `spec-lock-baseline-written` — written via the dual-write at AC-7's amend-spec migration. This is the only sub-step that's been re-recorded since the dual-write went live.

Future sub-step writes will populate both arrays in lock-step. Existing closed sprints' `gates_passed`-only records pass replay via the union reader (AC-13).

## Legacy bare-string upgrade

The same jq filter upgrades legacy bare-string entries to object form on first re-record:

```
Before: "gates_passed": ["spec-lock", {...}, {...}]
After re-record of "spec-lock":
       "gates_passed": [{...}, {...}, {"gate":"spec-lock","at":"<new>","verdict":"pass","evidence":null}]
```

Verified in AC-3 proof Test 5: legacy string count 1 → 0 after re-record; object count 0 → 1.

## Deprecation timeline

- **v0.7.0** (this sprint): dual-write `gates` + `gates_passed`. Loader reads union.
- **v0.7.x**: any new code writes ONLY to `gates_passed`. Legacy `gates` writes still happen for compat but the field is documented as deprecated.
- **v0.8.0**: `gates` field removed from `sub-step.sh::record_sub_step`. `sub_step_recorded` reader drops the `gates` half of the union. `sprint-system-test.sh --replay-gate-history` warns if a closed sprint has entries in `gates` but not `gates_passed` (= pre-0.7 sprint, expected; v0.8+ should have only `gates_passed`).

CHANGELOG v0.7.0 entry (AC-14, next commit) declares the deprecation explicitly.

## What this proves

1. **No data loss across the migration** — every legacy bare-string entry is preserved AND upgraded on first re-record.
2. **Both names accepted by readers** — predicate engine, replay validator, dashboard reader all union the two arrays.
3. **One writer goes to both** — `record_sub_step` is the single instrumentation API; no caller needs to know about the dual-write detail.
4. **Clear deprecation path** — v0.8.0 removes `gates` writes; existing closed-pre-0.8 sprints pass replay because reader still unions.
