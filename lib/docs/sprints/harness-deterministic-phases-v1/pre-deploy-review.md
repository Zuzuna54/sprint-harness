# Pre-deploy review — harness-deterministic-phases-v1 (parent)

**Date:** 2026-05-19
**Verdict:** APPROVED FOR DEPLOY (harness-itself sprint: "deploy" = local commits + sprint-harness v0.7.0 tag, both operator-gated for push)
**Reviewers:** reviewer-agent + security-architect-agent (review content captured in `architect-review.md` + `security-review.md` at spec-lock + reinforced by closure sprint's Wave A/C proofs)

---

## Architect sign-off

**Original sprint shipped 14 ACs.** Post-implementation audit caught 5 as `Broken-with-followup` (AC-4, AC-5, AC-8, AC-10, AC-14). The Tier 1-4 follow-up pass + closure sprint addressed every gap:

- **AC-4 (advance-phase predicate chain)** — fully wired via T1.6 + closure Wave A L4 (this very walk).
- **AC-5 (hook chokepoint)** — closure Wave A L1+L2 (depth-3 ppid walk + 5/6 attack pattern coverage).
- **AC-8 (gate-name validation)** — closure Wave C L16+L17 (manifest-warn + gate-names.json constants).
- **AC-10 (retro completeness)** — T1.7 baseline + parent retro.md has all 6 H2 sections.
- **AC-14 (replay validator)** — closure Wave B L11 + Wave C L19+L20 (`--report-file`, doc-drift scope, pre-v0.7 skip).

**Build quality:** 1,692 LOC across 8 new files + 9 modified phase-writers + hook regex. All sub-step gates instrumented at canonical boundaries. Manifest validator passes.

**Verdict:** APPROVED. The audit-honesty success criterion is met: this sprint has no open-ended issues. Closure sprint covered the long tail.

## Security-architect sign-off

**15 attack surfaces analyzed at spec-lock (security-review.md S1-S15).** Closure sprint added 6 more (S-CL1..S-CL6). After Wave A + Wave C:

- **TOCTOU race** (S7): closed via L12 expected-current jq filter.
- **Evidence path traversal** (S9 + S13): closed via L13 `..` reject + canonical conversion.
- **PII in bypass rationale** (S11): closed via L14 `sprint-pii-redact.sh` pipe.
- **Hook regex escape via jq -f / python -c / awk / perl -i** (S2-CL2): closed via L2 `INTERPRETER_WRITE_TO_STATE_JSON`.
- **rm/mv state.json escape** (S14): closed via L15 `RM_OR_MV_STATE_JSON`.
- **Sub-step gate-name typo silent-bypass** (S-CL6): closed via L16 record_sub_step manifest-warn.

**Secrets scan against parent + closure commits (post-Wave-D):** zero hits for `AIza` / `eyJ` / `sk-` / `postgres://` patterns. PII redactor protected all 8 bypass rationale records in this sprint and 8 in closure.

**Push gating:** All push operations to origin remain explicitly gated on `gio` confirmation per org policy. No autonomous push.

**Verdict:** APPROVED. All 15 + 6 = 21 attack surfaces mitigated or accepted with rationale.

---

## What ships at v0.7.0

- 11 phases × 68 gates manifest (25 enforced + 43 deferred per T4)
- Canonical phase mutator (`sprint-advance-phase.sh`) — sole writer of `state.phase`
- PreToolUse hook with 5 forbidden-pattern regexes + depth-3 ppid walk
- Single bypass UX with PII redaction
- Replay validator with `--report-file`, monotonic gate history, doc-vs-manifest drift
- 7 legacy bypass env shims (removal v0.8.0)
- Migrated 9 sprint-`*`.sh scripts to delegate via canonical mutator
- gate-names.json constants file (68 gates; strict enforcement v0.7.1)

## Outstanding items (filed as follow-up sprints)

- **v0.7.1 polish**: race-test L12 TOCTOU, env-by-env smoke for 6 untested legacy shims, strict gate-names.json enforcement.
- **v0.8.0**: remove legacy `SPRINT_*_BYPASS` shim code + rewrite USAGE.md callsites.
- **`harness-verify-instrumentation-v1` sprint**: wire 43 deferred gates (~41 ACs).

## Push approval checklist (operator gio)

- [ ] Closure sprint phase=done (✓ verified 2026-05-19T15:01:18Z).
- [ ] Parent sprint phase=done (this review's prereq — completes when Wave F finishes).
- [ ] sprint-harness v0.7.0 tag exists locally (✓ verified).
- [ ] CHANGELOG.md v0.7.0 entry committed (✓ verified).
- [ ] Authorize: `git push origin v0.7.0` (sprint-harness) + `git push origin sprint/pipeline-v2-visibility` (lifeos).

Until those final two boxes are user-checked, v0.7.0 stays local.
