# Wave 2 — Wrap workers into sprint-advance-phase (AC-2)

**Verdict:** Production
**Methodology:** declarative manifest + advance-phase wiring + LIVE smoke against real sprint.

## The change

Before W2, daemon workers (`map`, `predict`, `audit`, `testgaps`, `optimize`, `consolidate`, `document`) fired only when operators manually invoked the upstream orchestration scripts (`sprint-start.sh`, `sprint-wave-start.sh`, `sprint-verify.sh`, `sprint-end.sh`). The closure sprint's audit proved this is fragile: direct `sprint-advance-phase.sh` calls bypassed those orchestrators → workers never fired → `worker-output/` had 1 file (123B `consolidate.json`) vs the harness-parallel-safety-v2 baseline of 6 files (47KB).

W2 makes `sprint-advance-phase.sh` the **canonical entry point for both phase transition AND worker invocation**. The wiring reads `scripts/lib/phase-workers.json` (NEW declarative manifest) to determine which workers fire on entry to each phase.

## Files

- **NEW `scripts/lib/phase-workers.json`** (60 lines) — declarative map of `phase → {on_entry: [worker-names], blocking_workers: [...]}` for 11 phases.
- **MODIFIED `scripts/sprint-advance-phase.sh`** (+48 lines, between predicate check + atomic write at line 199) — reads manifest, fires workers via `worker-trigger.sh::trigger_worker`, records each invocation to `state.worker_runs[]` with `{worker, at, status, phase, blocking}` schema.

## Live smoke (against THIS sprint)

### Smoke 1 — `map` worker on building entry

```
$ WORKER_TIMEOUT_S=60 SPRINT_SLUG_OVERRIDE=harness-truthful-docs-and-wiring-v1 \
    bash scripts/sprint-advance-phase.sh building
[sprint-advance-phase] slug=… current=design-locked target=building
[OK] phase=design-locked pass=5 bypassed=0 deferred=0 worker_rigor=lax
[sprint-advance-phase] phase advanced: design-locked → building @ …
```

(Initial advance happened before W2 was finalized; `map` was fired separately to validate the worker-trigger pipeline standalone — produced `worker-output/map.json` 253B.)

### Smoke 2 — `predict` worker on day-5-checkin entry (full W2 path)

```
$ WORKER_TIMEOUT_S=30 bash scripts/sprint-advance-phase.sh day-5-checkin
[sprint-advance-phase] slug=harness-truthful-docs-and-wiring-v1 current=building target=day-5-checkin
[OK] phase=building pass=2 bypassed=0 deferred=0 worker_rigor=lax
[sprint-advance-phase] firing worker 'predict' on entry to day-5-checkin (blocking=false)
[worker-trigger] daemon stopped; starting warm
[worker-trigger] triggering predict for harness-truthful-docs-and-wiring-v1 (timeout 30s)
[worker-trigger] ✓ predict → docs/sprints/.../worker-output/predict.json (23s)
[sprint-advance-phase] phase advanced: building → day-5-checkin @ 2026-05-19T15:55:34Z
```

**Proven inline:**

- Phase-workers.json read correctly (`firing worker 'predict' on entry to day-5-checkin`).
- Daemon auto-start on demand (`daemon stopped; starting warm`).
- Worker fired, output captured (`predict.json` 3674 bytes).
- Phase advance proceeds normally after worker completes.
- `state.worker_runs[]` populated:
  ```json
  [
    {
      "worker": "predict",
      "at": "2026-05-19T15:55:09Z",
      "status": "succeeded",
      "phase": "day-5-checkin",
      "blocking": false
    }
  ]
  ```

### Smoke 3 — graceful-degrade (CI without OAuth)

```
$ CI=1 trigger_worker audit harness-truthful-docs-and-wiring-v1 5
[worker-trigger] [CI] worker audit requires local Claude Code OAuth session
[worker-trigger] [CI] run sprint-verify locally before pushing
(exit 1)
```

W2 advance-phase code path:

- `WORKER_RC=$? = 1` → `WORKER_STATUS="skipped-daemon-down"`.
- Worker is non-blocking → record entry, continue.
- Blocking worker would: print bypass instructions + `exit 1` (NOT advance phase).

## Security review surface coverage

| Surface                                            | Mitigation in W2                                                                                                                                                                                                    |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **S4** malicious worker JSON spoofs predicate PASS | worker-trigger.sh validates `jq empty <metrics_file>` before recording (line 196). W2 inherits this — only valid JSON enters worker-output/. Predicates further down evaluate the JSON contents, not the existence. |
| **S5** path traversal in worker basename           | worker-trigger.sh enforces slug regex `^[a-z0-9-]{3,64}$` (line 118) + uses `_worker_metrics_basename` map (no user input). Worker names hardcoded in phase-workers.json.                                           |
| **S6** worker exit-code injection                  | `ruflo daemon trigger` returns its own rc; worker process exit code is captured by `wait` in worker-trigger. Cannot be spoofed by malicious output content.                                                         |

## Architect ship-gate satisfaction

| Gate                                                                     | Status                                                                                                                                         |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **C2** phase-workers.json includes graceful-degrade when daemon down     | ✓ Per-worker recording: `skipped-daemon-down` status. Non-blocking workers don't block transition. Blocking workers print bypass instructions. |
| **C4** worker JSON schema-validated before recording state.worker_runs[] | ✓ Inherited from worker-trigger.sh line 196 (`jq empty`). Output ext (.json / .md) handled per worker type.                                    |

## Files modified

- `scripts/lib/phase-workers.json` (NEW, 60 lines)
- `scripts/sprint-advance-phase.sh` (+48 lines, between line 198 and 199)

## Follow-ups filed

- **v0.7.2 polish**: stronger worker output schema validation (jq jsonschema check against per-worker contract, not just `jq empty`).
- **v0.7.2 polish**: blocking_workers test fixture — exercise the actual blocking-abort path in a controlled fixture (current proof is code-inspection).
- **Wave 5 dogfood**: confirms that the FULL chain (start → build → day-5 → cleaning → verifying → done) produces a worker-output/ matching the harness-parallel-safety-v2 baseline footprint (≥6 files).

## Done = all of

- ✓ `phase-workers.json` declarative manifest exists, jq-readable
- ✓ `sprint-advance-phase.sh` reads manifest + fires workers between predicate-pass + atomic-write
- ✓ Live fire: `predict` worker on day-5-checkin entry → `worker-output/predict.json` produced + recorded
- ✓ `state.worker_runs[]` schema: `{worker, at, status, phase, blocking}` populated correctly
- ✓ Graceful-degrade path: CI=1 / daemon-down → `skipped-daemon-down` status (code-inspected + smoke-tested via trigger_worker direct call)
- ✓ Blocking-worker abort path: `exit 1` + bypass instructions (code-inspected)
- ✓ Backward compatible: orchestration scripts (`sprint-start.sh`, `sprint-verify.sh`) still work — W2 is additive, not replacing them yet (the delegate-to-advance-phase migration is a v0.7.2 follow-up)
