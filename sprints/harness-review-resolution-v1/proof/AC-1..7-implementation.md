# Proof — AC-1..AC-7 implementation (harness-review-resolution-v1)

> **Generated:** 2026-05-19
> **Commit:** `3a11d22e` (AC-1..AC-7 implementation) + `1d1abd51` (merge-conflict resolution from lint-staged stash restore)

## AC-1 — phase manifest + predicate extension

- `scripts/lib/phase-manifest.json`: new `review-resolution` phase block with `review-resolution-fired` + `review-findings-exit-predicate` gates, `review-resolutions.md ≥ 1024B` artifact, `review_resolution_complete` predicate.
- `scripts/lib/phase-manifest.schema.json`: added `"review-resolution"` to phase enum + `"review_resolution_complete"` to predicate kind enum.
- `scripts/lib/validate-phase-manifest.mjs`: added the same to the JS validator's allow-lists.
- `scripts/lib/phase-predicates.sh`: added `_pp_pred_review_resolution_complete` that sums findings across producers (audit + knip + sonar) and falls back to legacy `audit_findings_*` for back-compat.
- Validator output: `[OK] manifest valid: 13 phases, 72 unique sub-step gates (72 enforced, 0 deferred per T4)`.
- Legacy `audit-resolution` phase + `audit_resolution_complete` predicate retained — both audit-only and review-unified flows are supported.

## AC-2 — `sprint-review-resolve.sh` (multi-producer walker)

- `scripts/sprint-review-resolve.sh` — 250-line interactive walker that:
  - Reads `worker-output/{audit,knip,sonar}.json` on first invocation.
  - Aggregates entries into `state.review_findings[]` with global `HAR-N` namespace and per-entry `producer` field.
  - `--status`: per-producer breakdown table.
  - `--finding HAR-N {fix|defer|accept}`: programmatic single-finding mutation. Defer requires `--to-sprint` (validated against `^[a-z0-9-]{3,64}$` per C7) + `--ac-id`. Accept requires `--risk-owner` + `--rationale`.
  - C5: rationale piped through `scripts/sprint-pii-redact.sh` before persistence.
  - Vacuous-PASS short-circuit when total = 0.

## AC-3 — `sprint-review-rerun.sh` (per-producer baseline diff)

- `scripts/sprint-review-rerun.sh` — replaces the audit-only `sprint-audit-rerun.sh`. For each producer:
  - Snapshots `worker-output/<producer>-baseline.json` on first run.
  - Fires the producer (audit via `trigger_worker` env-stripped per C6, knip via `sprint-deadcode-delete.mjs --check --json`, sonar via `sprint-sonar-parse.mjs --json`).
  - Diffs current vs baseline by `(severity, file, line)` fingerprint.
  - Classifies into FIXED / REGRESSION / UNCHANGED.
  - Tracks `state.review_rerun_regression_streak.<producer>` per producer — twice-consecutive regression on any producer records a `review-rerun-regression-blocked-<producer>` failure gate.

## AC-4 — knip `--check --json` producer mode

- `scripts/sprint-deadcode-delete.mjs` — added `--check` flag (combined with `--json`). Short-circuits after `knip --reporter json` parse + sprint-scope filter, emitting the unified `review_findings` producer schema to stdout (`producer: "knip"`, `schema_version: 1`, `timestamp`, `findings[]`). Each finding gets a `KNIP-N` har_id, `unused_file` reason, `medium` severity. Files in `state.files_touched[]` are excluded.

## AC-5 — sonar `--json` producer mode

- `scripts/sprint-sonar-parse.mjs` — added `--json` flag. Emits the unified schema with `producer: "sonar"`, flattens findings across all 18 LifeOS Sonar projects. Severity remap: `BLOCKER+CRITICAL → high`, `MAJOR → medium`, `MINOR+INFO → low`. Vacuous-PASS when `SONAR_TOKEN` absent (returns empty `findings: []` with exit 0).

## AC-6 — `_templates/review-resolutions.md`

- `docs/sprints/_templates/review-resolutions.md` — 4284-byte template with:
  - Triage summary table per producer (Audit / Knip / Sonar / All).
  - Per-producer H3 finding sections.
  - Per-finding triage protocol description (Fix / Defer / Accept).
  - Programmatic invocation examples.
  - Verification predicate explanation.
- Predicate satisfies the `file_min_bytes: 1024` requirement.

## AC-7 — docs + dogfood

- `docs/sprints/USAGE.md` §1 Day 12–13: row replaced with the v0.7.3 review-resolution form; phase count bumped to 13; gate count bumped to 72.
- `docs/sprints/QUICKSTART.md` v0.7.0 callout: added v0.7.3 addition block; 7-step table row 6.5 updated; Step 6.5 example block updated.
- `docs/sprints/DEVELOPER.md` Terminology Contract: Phase definition updated to 13-step state machine; Predicate definition updated to mention `review_resolution_complete`.
- `docs/sprints/SCRIPTS.md`: marked `sprint-audit-resolve.sh` + `sprint-audit-rerun.sh` as legacy aliases; added rows for `sprint-review-resolve.sh` + `sprint-review-rerun.sh`.

## Dogfood walk

- Sprint walked spec-wizard → spec-locked → design-locked → building → cleaning → verifying — all advances passed manifest predicate checks.
- Verifying phase fired the `audit` daemon worker (79s, produced `worker-output/audit.json` with 4 advisory findings: 3 low + 1 informational, all in `.claude/helpers/github-safe.js`, all out-of-scope per the sprint's `## Files touched`).
- Per scope-bounding (v0.7.2 AC-1, retained in v0.7.3): out-of-scope findings logged as advisory, do not block phase advance.
- Worker scope: `audit` set to `files-touched / post-filter`.

## Back-compat verification

The `review_resolution_complete` predicate handles three call shapes:

1. v0.7.3 sprints — reads `review_findings_*` fields (canonical).
2. v0.7.2 sprints — reads `audit_findings_*` fields (legacy union view).
3. Pre-v0.7.2 sprints — vacuous PASS (both totals = 0).

`audit-resolution` phase + `audit_resolution_complete` predicate remain in the manifest. The legacy `sprint-audit-resolve.sh` and `sprint-audit-rerun.sh` scripts are untouched and continue to work.
