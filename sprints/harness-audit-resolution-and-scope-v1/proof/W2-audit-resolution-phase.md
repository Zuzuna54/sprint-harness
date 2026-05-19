# Wave 2 — Audit-resolution phase infrastructure (AC-5..8)

**Verdict:** Production
**Methodology:** new phase + new predicate kind + 2 new scripts + template. Live smoke via --status mode + manifest validator + predicate vacuous-PASS path.

## What landed

| AC   | Change                                                                                                                                                                                                     | Files                                                                                                                                                     |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AC-5 | `audit-resolution` phase added between `verifying` and `pre-deploy`; new predicate kind `audit_resolution_complete` for exit-predicate arithmetic                                                          | `scripts/lib/phase-manifest.json`, `scripts/lib/phase-manifest.schema.json`, `scripts/lib/validate-phase-manifest.mjs`, `scripts/lib/phase-predicates.sh` |
| AC-6 | `scripts/sprint-audit-resolve.sh` — interactive finding walker with --status + --finding HAR-N {fix\|defer\|accept} programmatic mode; atomically persists every decision (C2); PII-redacts rationale (C5) | NEW `scripts/sprint-audit-resolve.sh` (293 LOC)                                                                                                           |
| AC-7 | `scripts/sprint-audit-rerun.sh` — re-fires audit worker with env-stripped invocation (C6); diffs FIXED/REGRESSION/UNCHANGED; consecutive-regression streak counter (C3)                                    | NEW `scripts/sprint-audit-rerun.sh` (130 LOC)                                                                                                             |
| AC-8 | `docs/sprints/_templates/audit-resolutions.md` — canonical template seeded at audit-resolution phase entry                                                                                                 | NEW `docs/sprints/_templates/audit-resolutions.md` (88 lines)                                                                                             |

## Phase-manifest changes

```json
"audit-resolution": {
  "advances_to": ["pre-deploy", "verifying", "paused"],
  "required_artifacts": [
    {"kind": "file_min_bytes", "path": "audit-resolutions.md", "min_bytes": 1024}
  ],
  "required_state_fields": [
    {"kind": "json_path_present", "path": "state.json", "json_path": ".audit_findings_total"},
    {"kind": "json_path_present", "path": "state.json", "json_path": ".audit_findings_resolved_count"},
    {"kind": "audit_resolution_complete", "path": "state.json"}
  ],
  "required_sub_step_gates": [
    "audit-resolution-fired",
    "audit-findings-exit-predicate"
  ]
}
```

`verifying.advances_to` now includes `audit-resolution` as the first option (operators can still go directly to `pre-deploy` via bypass for sprints with zero findings).

## C1 — exit predicate is PURE STATE.JSON

`_pp_pred_audit_resolution_complete` in `scripts/lib/phase-predicates.sh:248-296`. Reads ONLY `state.json` fields (no spec.md dependency at exit time):

```
resolved_count + deferred[].length + accepted[].length == audit_findings_total
AND every deferred[] entry has non-empty deferred_to_sprint + ac_id
```

Vacuous PASS when `audit_findings_total == 0` (no findings → nothing to resolve).

Smoke:

```
$ bash -c "source scripts/lib/phase-predicates.sh && _pp_pred_audit_resolution_complete harness-audit-resolution-and-scope-v1"
$ echo $?
0  # vacuous PASS — audit_findings_total not yet set
```

## C2 — atomic per-decision persistence (Ctrl-C safe)

Every Fix/Defer/Accept call in `sprint-audit-resolve.sh` invokes `atomic_update_state` IMMEDIATELY. No batching. Resume reads `state.audit_findings_{deferred[],accepted[]}` to know which HAR-N entries already triaged (via `is_triaged()` helper at line ~155).

## C3 — twice-consecutive regression threshold

`sprint-audit-rerun.sh` lines 110-128. Tracks `state.audit_rerun_regression_streak`. First regression detection: streak=1, exit 0 (don't block, ask operator to re-run). Second consecutive detection: streak=2, exit 1 + record `audit-rerun-regression-blocked` gate. PASS resets streak to 0.

## C5 — PII redaction on rationale fields

`sprint-audit-resolve.sh::redact()` pipes operator-typed strings through `scripts/sprint-pii-redact.sh` before they land in state.json. Applies to `defer.rationale` + `accept.business_rationale`. Strips emails, UUIDs, JWTs, API keys, password=, postgres URLs.

## C6 — env-stripped audit worker invocation

`sprint-audit-rerun.sh:87` wraps `trigger_worker` with `env -i HOME PATH SHELL` so operator shell env vars (AWS keys, PROD URLs, secrets) cannot leak into the headless audit worker invocation.

## Live smoke

```
$ node scripts/lib/validate-phase-manifest.mjs
[OK] manifest valid: 12 phases, 70 unique sub-step gates (70 enforced, 0 deferred per T4)

$ bash scripts/sprint-audit-resolve.sh --slug harness-audit-resolution-and-scope-v1 --status
[sprint-audit-resolve] no audit.json — must run verifying phase first
```

Error correctly when no audit.json exists. Real end-to-end smoke happens during W4 dogfood when this sprint advances `verifying → audit-resolution`.

## Files modified

- `scripts/lib/phase-manifest.json` (+18 lines: new audit-resolution phase block)
- `scripts/lib/phase-manifest.schema.json` (+1 line: "audit-resolution" in enum)
- `scripts/lib/validate-phase-manifest.mjs` (+2 lines: VALID_PHASES + VALID_PREDICATE_KINDS)
- `scripts/lib/phase-predicates.sh` (+55 lines: \_pp_pred_audit_resolution_complete + dispatcher case)
- `scripts/sprint-audit-resolve.sh` (NEW, 293 lines)
- `scripts/sprint-audit-rerun.sh` (NEW, 130 lines)
- `docs/sprints/_templates/audit-resolutions.md` (NEW, 88 lines)

## C-condition coverage (W1 + W2 cumulative)

| Condition                                               | Wave | Status                                                                 |
| ------------------------------------------------------- | ---- | ---------------------------------------------------------------------- |
| C1 (architect): exit predicate pure-state.json          | W2   | ✓ implemented + smoke-tested                                           |
| C2 (architect): atomic per-decision persistence         | W2   | ✓ implemented (every Fix/Defer/Accept atomic_update_state immediately) |
| C3 (architect): twice-consecutive regression threshold  | W2   | ✓ implemented (audit_rerun_regression_streak counter)                  |
| C5 (security): PII-redact rationale before state.json   | W2   | ✓ implemented (redact() helper)                                        |
| C6 (security): env-stripped audit worker fire           | W2   | ✓ implemented (`env -i HOME PATH SHELL trigger_worker`)                |
| C4 (security): encryption key 0600 + crypto.randomBytes | W3   | pending                                                                |
| C7 (security): atomic encryption migration              | W3   | pending                                                                |
| C8 (reviewer): W4 dogfood proves resolved == total      | W4   | pending                                                                |
| C-base scope-bounding                                   | W1   | ✓ done                                                                 |

## Done = all of

- ✓ AC-5 audit-resolution phase added with audit_resolution_complete predicate
- ✓ AC-6 sprint-audit-resolve.sh with --status / --finding / interactive modes
- ✓ AC-7 sprint-audit-rerun.sh with env-strip + consecutive-regression counter
- ✓ AC-8 template at `docs/sprints/_templates/audit-resolutions.md`
- ✓ Manifest validator passes: 12 phases, 70 gates, 0 deferred
- ✓ All 5 W1+W2 C-conditions satisfied (C1, C2, C3, C5, C6)
- ⏸ W3 covers HAR-1..10 + remaining C4 + C7
- ⏸ W4 dogfood end-to-end validates the whole chain (C8)
