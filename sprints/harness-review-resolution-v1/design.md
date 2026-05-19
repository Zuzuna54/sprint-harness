# SPARC Design — harness-review-resolution-v1

> Generated: 2026-05-19. Inputs: spec.md (7 ACs), solution-sketches.md (Sketch A superset), architect-review.md (5 ADRs + 3 conditions), security-review.md (6 new + 8 inherited surfaces), consensus-spec.json (8 ship-gate conditions C1-C8).

## Specification recap

7 ACs generalize the audit-resolution infrastructure (v0.7.2) to handle 3 producer streams under a unified `review-resolution` phase:

- **AC-1** Phase + predicate generalization (audit-resolution stays as legacy alias; review-resolution is new superset)
- **AC-2** `sprint-review-resolve.sh` multi-producer interactive walker (+ `sprint-audit-resolve.sh` legacy alias)
- **AC-3** `sprint-review-rerun.sh` per-producer baseline diff (+ `sprint-audit-rerun.sh` legacy alias)
- **AC-4** Knip `--json` producer mode (`sprint-deadcode-delete.mjs --check --json`)
- **AC-5** Sonar `--json` producer mode (`sprint-sonar-parse.mjs --json`)
- **AC-6** `_templates/review-resolutions.md` template (per-producer section)
- **AC-7** Docs + dogfood

## Pseudocode per AC

### AC-1 — phase manifest extension

```jq
.phases.\"review-resolution\" = {
  advances_to: [\"pre-deploy\", \"verifying\", \"paused\"],
  required_artifacts: [
    {kind: \"file_min_bytes\", path: \"review-resolutions.md\", min_bytes: 1024}
  ],
  required_state_fields: [
    {kind: \"review_resolution_complete\", path: \"state.json\"}
  ],
  required_sub_step_gates: [\"review-resolution-fired\", \"review-findings-exit-predicate\"]
}
```

Add new predicate kind `review_resolution_complete` in `phase-predicates.sh`:

```bash
_pp_pred_review_resolution_complete() {
  # Total = audit + knip + sonar findings (union view)
  total=$(jq '[
    (.review_findings // []),
    (.audit_findings // [] | map(. + {producer: \"audit\"}))
  ] | flatten | length' "$STATE")
  resolved=$(jq '.review_findings_resolved_count // .audit_findings_resolved_count // 0' "$STATE")
  deferred_count=$(jq '(.review_findings_deferred // .audit_findings_deferred // []) | length' "$STATE")
  accepted_count=$(jq '(.review_findings_accepted // .audit_findings_accepted // []) | length' "$STATE")
  # Validate sum + deferred completeness
}
```

`audit-resolution` phase block stays as alias pointer to same predicate logic.

### AC-2 — sprint-review-resolve.sh

```
Read state.review_findings[] (or fall back to legacy audit_findings_*)
--status:
  Show per-producer breakdown:
    Audit:  N findings (X resolved, Y deferred, Z accepted, R remaining)
    Knip:   N findings (...)
    Sonar:  N findings (...)
--finding HAR-N action:
  Resolve any HAR-N regardless of producer.
  Same atomic_update_state + PII-redact rationale flow as audit-resolve.
Interactive: loop unique HAR-Ns sorted by (producer, severity).
```

### AC-3 — sprint-review-rerun.sh

```
For each producer in [audit, knip, sonar]:
  baseline = worker-output/<producer>-baseline.json
  if not exists: snapshot current → baseline
  rerun:
    audit  → env-i ruflo daemon trigger -w audit
    knip   → node sprint-deadcode-delete.mjs --check --json > worker-output/knip.json
    sonar  → node sprint-sonar-parse.mjs --json > worker-output/sonar.json
  diff via jq fingerprint(producer, severity, file, line)
  categorize FIXED / REGRESSION / UNCHANGED
  twice-consecutive regression threshold per producer (state.review_rerun_regression_streak.<producer>)
```

### AC-4 — Knip --json producer

`sprint-deadcode-delete.mjs --check --json` emits:

```json
{
  \"producer\": \"knip\",
  \"schema_version\": 1,
  \"timestamp\": \"<ISO>\",
  \"findings\": [
    {\"har_id\": \"HAR-<N>\", \"file\": \"path.ts\", \"symbol\": \"unusedExport\", \"reason\": \"unused_export\", \"severity\": \"medium\"}
  ]
}
```

`sprint-verify.sh` reads + appends to `state.review_findings[]` after knip runs.

### AC-5 — Sonar --json producer

`sprint-sonar-parse.mjs --json` same shape. Severity map: blocker/critical → high, major → medium, minor/info → low. Vacuous PASS when no recent scan (older than 7 days).

### AC-6 — Template

`_templates/review-resolutions.md`:

```markdown
# Review Resolutions — <slug>

## Triage summary per producer

| Producer | Total | Fixed | Deferred | Accepted | Remaining |
| -------- | ----- | ----- | -------- | -------- | --------- |
| Audit    | 0     | 0     | 0        | 0        | 0         |
| Knip     | 0     | 0     | 0        | 0        | 0         |
| Sonar    | 0     | 0     | 0        | 0        | 0         |

## Findings

### Audit findings

### Knip findings

### Sonar findings

(per-HAR-N H3 entries seeded by sprint-review-resolve.sh)
```

### AC-7 — Docs

USAGE.md §1 Day 12-13 row updated audit-resolution → review-resolution. §3 worker arch adds knip + sonar producer pipeline diagram. QUICKSTART v0.7.3 callout. DEVELOPER.md producer-pipeline section. SCRIPTS.md rename + add review-resolve/review-rerun.

Dogfood: walk this sprint through new review-resolution phase. Should produce findings from at least audit + maybe knip (we touched scripts/.claude/helpers/), sonar pass vacuously.

## Architecture

```
verifying phase entry
├── audit worker fires → worker-output/audit.json + state.review_findings[]
├── knip --json runs → worker-output/knip.json + state.review_findings[]
└── sonar --json runs → worker-output/sonar.json + state.review_findings[]
            ↓
review-resolution phase entry
            ↓
sprint-review-resolve.sh walks state.review_findings[]
            ↓
operator Fix/Defer/Accept per finding (producer-agnostic)
            ↓
exit predicate: resolved + deferred + accepted == total ✓
            ↓
pre-deploy phase
```

## 5 ADRs

| ADR     | Decision                                 | Rationale                                                         |
| ------- | ---------------------------------------- | ----------------------------------------------------------------- |
| ADR-001 | Unified review_findings[] schema         | Single jq filter for exit predicate; producer field discriminates |
| ADR-002 | sprint-audit-resolve.sh stays as alias   | Preserves operator muscle memory; filters producer=audit only     |
| ADR-003 | Per-producer baselines in worker-output/ | Each rerun-able independently                                     |
| ADR-004 | Global har_id namespace                  | HAR-1..N across sprint, not per-producer                          |
| ADR-005 | review-resolution phase name             | Generic enough for future producer types                          |

## 5 invariants

- I-1: Every producer emits `schema_version: 1` for future migration
- I-2: har_id is globally unique within a sprint (enforced at record time)
- I-3: review_findings[] is append-only post-verifying-entry
- I-4: Exit predicate evaluates pure-state.json (no spec.md dependency)
- I-5: Legacy audit*findings*\* arrays remain valid forever (union view)

## Per-AC verification

| AC   | Verification                                                                                                |
| ---- | ----------------------------------------------------------------------------------------------------------- |
| AC-1 | `node scripts/lib/validate-phase-manifest.mjs` passes with both audit-resolution + review-resolution phases |
| AC-2 | `sprint-review-resolve.sh --status` against fixture with multi-producer findings shows breakdown            |
| AC-3 | `sprint-review-rerun.sh --dry-run` against fixture shows per-producer diff                                  |
| AC-4 | `sprint-deadcode-delete.mjs --check --json` produces schema-valid output                                    |
| AC-5 | `sprint-sonar-parse.mjs --json` produces schema-valid output (vacuous when no scan)                         |
| AC-6 | Template file >= 1KB and contains per-producer sections                                                     |
| AC-7 | doc_drift=0; this sprint walks `verifying → review-resolution → pre-deploy`                                 |

## 8 ship-gate execution map

| Condition                        | AC               | How verified                                                                      |
| -------------------------------- | ---------------- | --------------------------------------------------------------------------------- |
| C1 global har_id                 | AC-1, AC-4, AC-5 | har_id assigned at producer-record time + uniqueness check                        |
| C2 per-producer baselines        | AC-3             | `worker-output/<producer>-baseline.json` per producer                             |
| C3 audit-resolution legacy alias | AC-1             | Both phase names in manifest; predicate handles either                            |
| C4 knip --json validated         | AC-4             | jq empty + schema check before record                                             |
| C5 sonar API size-capped         | AC-5             | maxResponseSize: 1MB; SONAR_TOKEN never in state.json                             |
| C6 har_id uniqueness             | AC-1             | predicate check at record time                                                    |
| C7 defer slug regex              | AC-2             | sprint-review-resolve.sh validates deferred_to_sprint against `^[a-z0-9-]{3,64}$` |
| C8 dogfood all 3 producers       | AC-7             | Wave 5 walk produces findings from at least audit + knip                          |
