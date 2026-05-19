# Wave 3 — Documentation reorg (AC-3)

**Verdict:** Production
**Methodology:** structural rewrite of 3 docs + terminology contract grep-verification + replay validator doc-drift check.

## What changed

| Doc                          | Before     | After          | Action                                                                                                                                                                                                                                                                                         |
| ---------------------------- | ---------- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs/sprints/QUICKSTART.md` | 322 lines  | **222 lines**  | Full rewrite. Single-purpose: 5-min new-operator onboarding. v0.7.0 callout box for phase enforcement. `SPRINT_BYPASS_GATE` as primary; `SPRINT_DRIFT_BYPASS=1` marked deprecated.                                                                                                             |
| `docs/sprints/USAGE.md`      | 1281 lines | **693 lines**  | Full rewrite into 5 clear sections (14-day flow / phase enforcement / worker architecture / bypass cheatsheet / troubleshooting). Two-worker-surface confusion fixed — three distinct worker concepts now explicit. 46% size reduction with zero info loss (audit-relevant content preserved). |
| `docs/sprints/DEVELOPER.md`  | 908 lines  | **1117 lines** | Additive (+209). Three new sections: terminology contract (with grep-anchors), honest deferred-gates ledger, state.json race recipe. All existing valid content preserved verbatim.                                                                                                            |

## Architect ship-gate C3 — terminology contract grep-verifiable

Each of 7 terms has a unique anchor that exists ONLY in `DEVELOPER.md`:

```
$ for anchor in phase-term-canonical-DEV sub-step-term-canonical-DEV \
    worker-term-canonical-DEV predicate-term-canonical-DEV \
    bypass-term-canonical-DEV gate-history-term-canonical-DEV \
    drift-term-canonical-DEV; do
    count=$(grep -rl "$anchor" docs/sprints/ | wc -l | tr -d ' ')
    echo "$anchor: $count file(s)"
  done
phase-term-canonical-DEV: 1 file(s)        ← DEVELOPER.md
sub-step-term-canonical-DEV: 1 file(s)     ← DEVELOPER.md
worker-term-canonical-DEV: 1 file(s)       ← DEVELOPER.md
predicate-term-canonical-DEV: 1 file(s)    ← DEVELOPER.md
bypass-term-canonical-DEV: 1 file(s)       ← DEVELOPER.md
gate-history-term-canonical-DEV: 1 file(s) ← DEVELOPER.md
drift-term-canonical-DEV: 1 file(s)        ← DEVELOPER.md
```

Each term is defined ONCE; USAGE/QUICKSTART link back. C3 ship-gate satisfied.

## Replay validator — doc-vs-manifest drift

```
$ node scripts/sprint-replay-validator.mjs --quiet
[REPLAY SUMMARY] walked=2 passed=2 failed=0 skipped=13 doc_drift=0
```

`doc_drift=0` — every gate name referenced in the rewritten USAGE.md exists in `scripts/lib/phase-manifest.json`. No phantom gates.

## Two-worker-surface fix (audit finding A9, S-CL2 / C-Cl3)

USAGE.md §3 now explicitly distinguishes:

1. **Daemon workers** (`map`, `predict`, `audit`, `testgaps`, `optimize`, `consolidate`, `document`, `refactor`, `deepdive`, `ultralearn`) — fire from `sprint-advance-phase.sh` via `phase-workers.json`. Output: `.claude-flow/metrics/<basename>.json` → copied to `worker-output/<worker>.json`. State: `worker_runs[]` + `worker_invocations[]`.
2. **Task sub-agents** (`architect`, `security-architect`, `reviewer`, `deepdive`) — spawned via Task tool by orchestrator skill at spec-lock (Day ½) + pre-deploy (Day 12). Output: `<review-name>.md` directly.
3. **Autopilot side-cars** (`lint-fix`, `test-backfill`, `doc-sweep`) — `.claude-flow/autopilot/` configured, run during build phase.

Closes audit finding "docs conflate daemon workers + Task sub-agents."

## Specific contradictions resolved

| Audit finding                                                         | Resolution                                                                                                                                                                      |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1 — QUICKSTART teaches deprecated `SPRINT_DRIFT_BYPASS=1` as primary | NEW QUICKSTART teaches `SPRINT_BYPASS_GATE=<gate> SPRINT_BYPASS_WHY='...'` as canonical, legacy envs documented as deprecated with removal target v0.8.0                        |
| A2 — Spec-lock review producer ambiguous (Claude vs spawned agents?)  | USAGE.md §1 Day-½ explicitly states the 4 review files are produced by Task-spawned sub-agents (`architect`, `security-architect`) + Claude orchestrator (sketches + consensus) |
| A3 — Transient `spec-locked-pending-review` phase missing from USAGE  | USAGE.md §1 + §2 name this transient state explicitly                                                                                                                           |
| A4 — Day-11 vs Day-12 sequencing unclear                              | USAGE.md §1 has explicit day-by-day table with phase transitions                                                                                                                |
| A5 — Worker output paths described inconsistently                     | USAGE.md §3 worker table shows exact paths: `.claude-flow/metrics/<basename>.json` (gitignored, transient) + `worker-output/<worker>.json` (committed, audit trail)             |
| A6 — Pair-mode automatic vs user-initiated ambiguous                  | USAGE.md §1 Day-3+ lists post-commit pair-mode trigger explicitly; user-invocation noted as secondary                                                                           |
| A7 — Hive-mind consensus voting model undefined                       | USAGE.md §1 Day-½ defines: "5-worker synthetic vote, recorded as consensus-spec.json with `verdict` ∈ {pass, pass-with-notes}"                                                  |
| A8 — `phase-manifest.json` 15× in DEVELOPER but 0× in QUICKSTART      | QUICKSTART now has v0.7.0 callout naming the manifest + advance-phase + bypass UX                                                                                               |
| A9 — Two-worker-surface confusion                                     | (See above)                                                                                                                                                                     |

## C5 + C6 conditions (security)

These belong to W4 (gate instrumentation), but W3 docs reorg pre-documents the requirements:

- USAGE.md §3 notes: "verify-\* script evidence MUST pipe through `scripts/sprint-pii-redact.sh` (C5)."
- USAGE.md §3 notes: "deploy-\* gates record artifact paths only, not deploy URLs / Pulumi outputs (C6)."

W4 wires the actual `record_sub_step` calls; W3 makes the contract operator-visible.

## Files

- `docs/sprints/QUICKSTART.md` — full rewrite
- `docs/sprints/USAGE.md` — full rewrite into 5 sections
- `docs/sprints/DEVELOPER.md` — +3 sections (terminology contract, deferred-gates ledger, race recipe)

## Done = all of

- ✓ QUICKSTART ≤300 lines (222 ✓)
- ✓ USAGE restructured into 5 named sections
- ✓ DEVELOPER terminology contract with 7 grep-verifiable anchors
- ✓ Two-worker-surface confusion eliminated (USAGE.md §3 worker architecture)
- ✓ `SPRINT_BYPASS_GATE` is canonical bypass syntax across all docs
- ✓ `SPRINT_DRIFT_BYPASS=1` mentioned ONLY in deprecation paragraph
- ✓ Replay validator: `doc_drift=0`
- ✓ All 9 audit findings (A1-A9) explicitly resolved
- ✓ Architect ship-gate C3 satisfied (grep-anchored terminology)
