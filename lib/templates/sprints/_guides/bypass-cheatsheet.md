# Bypass cheatsheet (v0.7.0+)

Every escape-hatch env var, when to use, and where it audit-logs.

> **All bypasses are LOGGED** — to `state.gate_bypasses[]`, `state.gate_history[]`, or `state.scope_amendments[]`. Retro surfaces them. Velocity script flags sprints with >3 bypasses as `high-bypass`. Operate accordingly.

---

## v0.7.0+ canonical bypass interface (preferred)

Since `harness-deterministic-phases-v1`, **one env-pair replaces all the legacy per-script `SPRINT_*_BYPASS=1` envs**:

```bash
SPRINT_BYPASS_GATE=<gate-name>     # required — manifest gate name OR path-shaped (e.g. "design.md")
SPRINT_BYPASS_WHY="<reason>"        # required, ≥10 chars
```

Usage examples:

```bash
# Single gate
SPRINT_BYPASS_GATE=verify-sonar \
SPRINT_BYPASS_WHY='Sonar container down — escalated to infra; rerun scheduled within 24h' \
  bash scripts/sprint-advance-phase.sh pre-deploy

# Multi-gate (comma-separated)
SPRINT_BYPASS_GATE='verify-typecheck,verify-tests' \
SPRINT_BYPASS_WHY='Pre-existing @lifeos/db failure unrelated to this sprint; tracked separately' \
  bash scripts/sprint-advance-phase.sh pre-deploy

# Path-shaped bypass (artifact predicate)
SPRINT_BYPASS_GATE=design.md \
SPRINT_BYPASS_WHY='Design rationale captured inline in spec.md §B + §D; design.md not separately required for this sprint shape' \
  bash scripts/sprint-advance-phase.sh building
```

### What gets recorded

Every accepted bypass appends to `state.gate_bypasses[]`:

```json
{
  "gate": "verify-sonar",
  "why": "Sonar container down — escalated to infra; rerun scheduled within 24h",
  "at": "2026-05-19T12:00:00Z",
  "caller": "sprint-advance-phase.sh"
}
```

### Rules + safeguards

| Rule                                         | Mechanism                                                                                                            |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `SPRINT_BYPASS_WHY` ≥10 chars                | `bypass.sh::check_bypass` exits 1 if missing or too short                                                            |
| Gate name validated against manifest         | T2.1 fix in sprint-advance-phase.sh — typo'd names rejected before recording                                         |
| Idempotent on `(gate)`                       | re-bypassing same gate updates timestamp, doesn't duplicate                                                          |
| Audit-trail surfaced in retro                | sprint-end.sh retro auto-fill lists every bypass with rationale                                                      |
| `high-bypass` flag on >3 bypasses/sprint     | `sprint-velocity.mjs` sets `metrics.json.flags.high_bypass = true`                                                   |
| Replay validator checks well-formed bypasses | `sprint-system-test.sh --replay-gate-history` (AC-13c) — rejects bypasses with `why` <10 chars or unknown gate names |

### When NOT to bypass

- **Drift detection.** Real drift means the work doesn't match the spec. Amend spec instead (`bash scripts/sprint-amend-spec.sh --add-file <path>`) — that records `scope_amendments[]`, not `gate_bypasses[]`. Different signal.
- **Failing tests.** Tests are part of the work. Bypassing them means shipping known-broken code. Always fix or remove the test.
- **Missing retro patterns.** Three patterns is a small ask. If you can't extract three, the sprint probably had drift you weren't seeing.

### When bypass IS appropriate

- **External service down** (Sonar container, ruflo daemon, GitHub API rate-limit).
- **Pre-existing failure unrelated to this sprint** (typecheck error in `@lifeos/db/seed/` predating sprint-start).
- **Not-applicable predicate** (harness-itself sprint that adds no Lambdas needs no `verify-debug-rls`).
- **Operator judgment override** with rationale + scheduled follow-up.

### Security: don't put secrets in SPRINT_BYPASS_WHY

state.json is git-committed. The `why` string lives in git history forever. Do NOT include:

- Passwords, API keys, tokens
- PII (emails, names, customer data)
- Internal hostnames / IP addresses
- Anything you'd revoke from a paste site

Future enhancement (T2.10 follow-up): `bypass.sh` will run `SPRINT_BYPASS_WHY` through `sprint-pii-redact.sh` before recording. Until then, operator discipline.

---

## Legacy `SPRINT_*_BYPASS=1` envs (v0.6.x compat — deprecated)

These envs **still work in v0.7.x** via auto-shim. They emit a deprecation warning + auto-synthesize `SPRINT_BYPASS_GATE` + `SPRINT_BYPASS_WHY`. **Scheduled for removal in v0.8.0** — migrate now.

### Commit-path gates

| Legacy env                  | New equivalent (v0.7.0+)                                                  | When to use                                                                                        |
| --------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `SPRINT_DRIFT_BYPASS=1`     | `SPRINT_BYPASS_GATE=drift-check SPRINT_BYPASS_WHY='<reason>'`             | Legitimate amendment-class commit not yet in scope (e.g., emergency fix to drift detection itself) |
| `SPRINT_DUP_BYPASS=1`       | `SPRINT_BYPASS_GATE=dup-check SPRINT_BYPASS_WHY='<reason>'`               | Refactor introducing parallel structures (template copy); cleanup phase will dedupe                |
| `SPRINT_SKIP_REUSE_AUDIT=1` | `SPRINT_BYPASS_GATE=post-commit-reuse-audit SPRINT_BYPASS_WHY='<reason>'` | Cold-start where slow `pnpm dlx jscpd` is intolerable                                              |
| `SPRINT_NO_REVIEW_GATE=1`   | `SPRINT_BYPASS_GATE=pre-merge-review SPRINT_BYPASS_WHY='<reason>'`        | Trivial hotfix (e.g., typo in comment) where spawning review agents is overkill                    |

### Phase-transition gates

| Legacy env                    | New equivalent (v0.7.0+)                                                 | When to use                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `SPRINT_DESIGN_LOCK_BYPASS=1` | `SPRINT_BYPASS_GATE=design-locked SPRINT_BYPASS_WHY='<reason>'`          | Design captured inline in spec.md, separate design.md not needed                            |
| `SPRINT_PREDEPLOY_BYPASS=1`   | `SPRINT_BYPASS_GATE=pre-deploy SPRINT_BYPASS_WHY='<reason>'`             | Reviewer/security agents already ran out-of-band; deploy proceeds without re-spawning       |
| `SPRINT_PRECHECK_BYPASS=1`    | `SPRINT_BYPASS_GATE=precheck SPRINT_BYPASS_WHY='<reason>'`               | Systems-health check fails for a non-blocking reason (e.g., ruflo daemon down for a minute) |
| `SPRINT_HIVE_MIND_BYPASS=1`   | `SPRINT_BYPASS_GATE=spec-lock-hive-mind-consensus SPRINT_BYPASS_WHY='…'` | Solo-operator sprint; no second reviewer to run hive-mind vote                              |
| `SPRINT_GH_BYPASS=1`          | `SPRINT_BYPASS_GATE=gh-mirror SPRINT_BYPASS_WHY='<reason>'`              | Offline; no GitHub remote configured                                                        |
| `SPRINT_SKIP_GRAPHIFY=1`      | (legacy only — sprint-start.sh option, not a gate)                       | Graphify rebuild is slow + already fresh                                                    |
| `SPRINT_DEADCODE_COMMIT=1`    | (legacy only — cleanup-launch.sh flag, not a gate)                       | Actually delete dead code (vs dry-run)                                                      |

### Amendment gates (sprint-amend-spec.sh)

| Env var                                                                                 | Required / optional | Effect                                                               |
| --------------------------------------------------------------------------------------- | ------------------- | -------------------------------------------------------------------- |
| `AMEND_WHY` / `AMEND_INTENT`                                                            | REQUIRED            | AC-31 strict mode — empty values exit 1 unless `AMEND_ALLOW_EMPTY=1` |
| `AMEND_ALLOW_EMPTY=1`                                                                   | optional            | Bypass AC-31; recorded in `state.scope_amendments[]`                 |
| `AMEND_NONINTERACTIVE=1`                                                                | optional            | Skip TTY prompts in amend script                                     |
| `AMEND_SCOPE_IMPACT` / `AMEND_ACS_AFFECTED` / `AMEND_ALTERNATIVES` / `AMEND_DECIDED_BY` | optional            | Structured amendment fields recorded in retro                        |

### Wizard mode

| Env var                        | Default       | Effect                                                                         |
| ------------------------------ | ------------- | ------------------------------------------------------------------------------ |
| `SPRINT_WIZARD_MODE=autopilot` | `interactive` | Allows wizard `answer` calls without `--user-confirmed`. Logged in transcript. |

---

## State / context envs (not bypasses — operator control)

| Env var                       | Default  | Effect                                                                 |
| ----------------------------- | -------- | ---------------------------------------------------------------------- |
| `SPRINT_SLUG_OVERRIDE=<slug>` | unset    | Force-resolve the active sprint to `<slug>` regardless of session-file |
| `SPRINT_DRIFT_THRESHOLD=0.75` | `0.75`   | Cosine similarity threshold for pre-commit drift block                 |
| `SPRINT_DUP_THRESHOLD=50`     | `50`     | jscpd similarity % that blocks                                         |
| `SPRINT_DUP_REPO_SCAN`        | unset    | Single-file commits also trigger repo-wide jscpd                       |
| `SPRINT_BASE_BRANCH=main`     | `main`   | Coverage-delta + merge-base reference                                  |
| `REPO_ROOT=<path>`            | computed | Launchd-safe override for `sprint-memory-decay.mjs`                    |

---

## Honesty principle

**Bypasses are a tool, not a crutch.** Each one says: "I am consciously moving past a check that the harness wanted me to satisfy, for the recorded reason, and I'm OK with the audit trail showing it." That's fine. What's NOT fine is:

- Bypassing because the predicate looks hard.
- Bypassing with a vague rationale ("OK", "WIP", "lol").
- Bypassing >3 times in a sprint without reflecting on whether the gates are mis-calibrated.

If you find yourself bypassing the same gate repeatedly across sprints: that's signal. Either the gate is wrong for your workflow (raise an issue) or your workflow has a recurring gap (file a follow-up sprint to address it).

The harness was built so the model can't lie to you about what it skipped. The bypass record is the operator-honest version of the same.

---

## Replay validator's view of bypasses

`bash scripts/sprint-system-test.sh --replay-gate-history` (AC-13) walks closed sprints and enforces:

| Check                                                                                               | Failure mode                                                              |
| --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Every `gate_bypasses[].why` ≥10 chars                                                               | `[FAIL] gate_bypass 'X' has why='Y' (N chars, need ≥10)`                  |
| Every `gate_bypasses[].gate` matches a manifest gate name (when sub-step shaped)                    | `[FAIL] gate_bypass 'X' looks like a sub-step name but isn't in manifest` |
| `gate_history[]` is monotonic by `at` timestamp                                                     | `[FAIL] gate_history not monotonic: T2 < T1`                              |
| Every required sub-step gate per walked phase has a record in `gates_passed[]` OR `gate_bypasses[]` | `[FAIL] phase 'X' missing sub-step 'Y'`                                   |
| Every gate name in USAGE.md "Phase enforcement" exists in manifest                                  | `[DOC DRIFT] USAGE.md mentions 'X' but it's not in manifest`              |

CI failure = bypass-cheatsheet drift OR sprint closed with sloppy bypass. PR review catches the rest.
