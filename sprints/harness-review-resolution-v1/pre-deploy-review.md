# Pre-Deploy Review — harness-review-resolution-v1

> **Sprint:** unified review-resolution phase + audit/knip/sonar producer pipeline
> **Phase:** pre-deploy (entered 2026-05-19)
> **Scope:** harness-itself sprint — no Lambda routes, no DB migrations, no Vercel deploy

## Reviewer summary (sprint-orchestrator skill — solo-author per harness-itself convention)

All 7 ACs landed against scope. Implementation:

- AC-1 — manifest + predicate: `_pp_pred_review_resolution_complete` correctly unions audit + knip + sonar findings AND falls back to legacy `audit_findings_*` for back-compat (verified by predicate inspection + jq dry-run on this sprint's `state.json` which has `review_findings_total: 0`).
- AC-2 — `sprint-review-resolve.sh`: programmatic `--finding HAR-N {fix|defer|accept}` paths preserve atomic per-decision persistence + C5 PII-redact + C7 slug-regex validation. Vacuous-PASS path tested live: `state.review_findings_total == 0` short-circuits at line ~210 without prompting.
- AC-3 — `sprint-review-rerun.sh`: per-producer `state.review_rerun_regression_streak.<producer>` correctly increments per producer (jq `(.review_rerun_regression_streak // {}) | .[$p] = $s`); twice-consecutive on any producer records a producer-specific block gate.
- AC-4 / AC-5 — knip + sonar `--json` modes: both emit `producer / schema_version / timestamp / findings[]` with HAR-N namespace. Sonar vacuous-PASS path verified for token-absent case (returns `findings: []`, exit 0).
- AC-6 — `_templates/review-resolutions.md`: 4284 bytes, satisfies `file_min_bytes: 1024`. Per-producer H3 sections + protocol description + verification predicate explanation.
- AC-7 — docs: USAGE/QUICKSTART/DEVELOPER/SCRIPTS reflect v0.7.3 + retain legacy alias. Dogfood walk produced 4 advisory `.claude/helpers/github-safe.js` audit findings (all out-of-scope per scope-bounding); knip + sonar vacuously PASSed; review_findings_total = 0 → vacuous review-resolution exit predicate.

**Verdict:** ship. No new code in app paths. Manifest version bumped to 1.2.0 implicitly via 13-phase / 72-gate count change documented in USAGE.md §2.

## Security-architect review

- C5 (PII redaction): `sprint-review-resolve.sh::redact()` pipes operator rationale through `scripts/sprint-pii-redact.sh` before persistence. Rationale fields in `review_findings_deferred[]` + `review_findings_accepted[]` are protected.
- C6 (env stripping): `sprint-review-rerun.sh::fire_producer audit` uses `env -i HOME PATH SHELL` for daemon worker invocation. Operator AWS keys, PROD URLs, SUPABASE_SERVICE_ROLE_KEY cannot leak into worker context.
- C7 (slug regex): defer `--to-sprint` validates against `^[a-z0-9-]{3,64}$` before persisting — prevents path-traversal in deferred-sprint slug.
- No new attack surfaces: knip + sonar `--json` modes are pure-CLI readers; no auth bypass, no new RLS policies, no service-role key usage.
- Daemon worker fire-path unchanged from v0.7.2 — same auth model (operator OAuth via `claude --print`), same scope-bounding (`gate_audit_blocks` files-touched post-filter).

**Verdict:** ship. No new attack surfaces; existing C5/C6/C7 conditions inherited cleanly from v0.7.2 audit-resolution.

## Open carry-forwards (filed in retro `## Followups`)

1. `harness-wizard-state-and-gate-wiring-v1` — wizard CLI doesn't sync to `state.wizard_state.sections_status` + coherence-after-C/F/I gate-record never appends to `gates_passed[]`. ~60 LOC total in `scripts/sprint-spec-wizard.mjs`.
2. `harness-consensus-replacement-v1` — replace `ruflo consensus status` (broken upstream per `feedback_hive_mind_consensus_decorative`) with deterministic 5-vote tally. ~50 LOC.
3. `harness-mirror-and-cleanup-v1` — mirror v0.7.3 to `~/Desktop/sprint-harness/lib/`, inventory + relocate harness-\* sprints out of `docs/sprints/`, sprint-harness CHANGELOG v0.7.3, tag, push gated on `gio`.

Deploy path: N/A. No Lambda, no Vercel, no Pulumi. 5 deploy sub-step gates will be bypassed in `pre-deploy → deploying` with rationale "harness-itself sprint; no actual deploy".
