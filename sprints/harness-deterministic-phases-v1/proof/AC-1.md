# AC-1 — phase-manifest.json + schema validator

**Verdict:** Production
**Methodology:** inject-violation-catch-restore

## Artifacts shipped

- `scripts/lib/phase-manifest.json` (11 phases, 68 unique sub-step gates)
- `scripts/lib/phase-manifest.schema.json` (JSON-schema-draft-07 spec)
- `scripts/lib/validate-phase-manifest.mjs` (structural validator; no ajv dep)

## Baseline

```
$ node scripts/lib/validate-phase-manifest.mjs
[OK] manifest valid: 11 phases, 68 unique sub-step gates
$ echo $?
0
```

## Inject

Added a malformed gate name (`"invalid name with spaces"`) into `spec-wizard.required_sub_step_gates`:

```
$ jq '.phases."spec-wizard".required_sub_step_gates += ["invalid name with spaces"]' \
    scripts/lib/phase-manifest.json > /tmp/corrupt.json
$ mv /tmp/corrupt.json scripts/lib/phase-manifest.json
```

## Catch

```
$ node scripts/lib/validate-phase-manifest.mjs
[FAIL] spec-wizard.required_sub_step_gates: invalid gate name "invalid name with spaces"

1 validation failure(s) in /Users/gio/Desktop/lifeos/scripts/lib/phase-manifest.json
$ echo $?
1
```

Validator exits 1 with `[FAIL]` line identifying the exact predicate + value. Caller (sprint-advance-phase.sh, AC-4) treats non-zero exit from manifest load as fatal.

## Restore

```
$ cp /tmp/manifest.baseline.json scripts/lib/phase-manifest.json
$ node scripts/lib/validate-phase-manifest.mjs
[OK] manifest valid: 11 phases, 68 unique sub-step gates
$ echo $?
0
```

## What this proves

1. The manifest IS the source of truth — phase enum + gate names + predicate kinds all locked.
2. Corruption at file level is detected at load time, not at runtime mid-sprint.
3. Validator covers exactly the predicate kinds we ship (`file_exists`, `file_min_bytes`, `file_contains_heading`, `json_path_*`, `state_field_*`, `sub_step_recorded`), so adding a new kind to manifest without adding it to validator's allowlist will fail validation — keeps validator and manifest in sync.

## Phase coverage

| Phase           | Sub-step gate count | Notes                                                                                                                                                                                                  |
| --------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `spec-wizard`   | 14                  | 10 wizard sections + 3 coherence checks + assemble                                                                                                                                                     |
| `spec-locked`   | 5                   | solution sketches + architect + security + hive-mind consensus + baseline                                                                                                                              |
| `design-locked` | 3                   | SPARC spec-pseudocode + SPARC architect + design-locked                                                                                                                                                |
| `building`      | 1                   | build-launched (per-commit gates enforced by husky)                                                                                                                                                    |
| `day-5-checkin` | 4                   | 3 questions (cut/push/pivot) + hill-chart refreshed                                                                                                                                                    |
| `cleaning`      | 3                   | deadcode-delete + lint-fix + claude-md-clean                                                                                                                                                           |
| `verifying`     | 18                  | typecheck + lint + tests + api-contract + debug-rls + module-status + perf-profile + aidefence-scan + sonar + knip + cycle-check + audit-deps + bundle-budget + coverage-delta + migration + 3 workers |
| `pre-deploy`    | 2                   | reviewer agent + security-architect agent                                                                                                                                                              |
| `deploying`     | 5                   | pulumi preview + human gate + pulumi up + smoke + vercel                                                                                                                                               |
| `done`          | 11                  | 3 retro narrative sections + 3 patterns + claude-md + followups + DAA + trajectory + velocity                                                                                                          |
| `paused`        | 0                   | transient                                                                                                                                                                                              |

Plus `verifying.strict_only_sub_step_gates` (2): `verify-worker-map-refreshed`, `verify-worker-consolidate-refreshed`. Apply only when `state.worker_rigor == "strict"`.

**Total unique sub-step gates: 68.**
