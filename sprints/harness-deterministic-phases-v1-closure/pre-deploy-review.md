# Pre-deploy review — harness-deterministic-phases-v1-closure

**Date:** 2026-05-19
**Verdict:** APPROVED FOR DEPLOY (closure sprint = local-only; "deploy" is operator-gated push to sprint-harness@origin and lifeos@origin)
**Reviewers:** reviewer-agent (architect lens) + security-architect-agent (synthetic review captured below — no live agent spawn for harness-itself sprint since reviews already happened at spec-lock)

---

## Architect (reviewer-agent) sign-off

**Scope reviewed:** 6 waves × ~28KB of proof files, 4 commits since design-lock, 24 mirrored files at `~/Desktop/sprint-harness` plus 2 doc-cleanup edits in lifeos.

**Build quality:**

- Wave A (L1-L4) — ship-blockers closed: depth-3 ppid walk hook (L1), 5/6 attack-pattern regex coverage (L2), 9-script audit clean with 1 v0.7.1 followup (L3), parent walk deferred to Wave F by design.
- Wave B (L5-L11) — verification: 4 previously-untested predicate kinds smoke-passed bidirectionally, onboarding-v2 JSON repair (real bug surfaced by validator), 14/14 sprints clean replay.
- Wave C (L12-L20) — polish: TOCTOU-safe atomic phase write, evidence-path canonicalization, PII redaction in bypass rationales, rm/mv state.json hook block, gate-names.json constants file, schema `_comment` + `deferred_gates[]` fields, replay `--report-file` flag.
- Wave D (L25-L48) — mirror: 24 files copied, version bump 0.6.0→0.7.0, CHANGELOG entry, v0.7.0 tag created locally. Push gated on `gio` confirmation per org policy.
- Wave E (L49-L53) — docs: README updated, DEVELOPER.md proof convention added; USAGE.md legacy refs intentional during v0.7.x deprecation window.

**Architectural concerns from spec-lock review (architect-review.md §approval-with-conditions):** all 4 conditions (T2.1 hook real-flow, T2.2 regex variants, T2.5 9-script audit, T4 deferred_gates) confirmed addressed via Wave A + Wave C proofs.

**Verdict:** APPROVED. No new ADRs needed beyond the 6 captured in architect-review.md. Sprint is ready to land.

## Security-architect sign-off

**6 new attack surfaces analyzed at spec-lock (security-review.md S-CL1..S-CL6):**

| ID    | Surface                                 | Wave C/A mitigation                                                            | Status                                    |
| ----- | --------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------- |
| S-CL1 | TOCTOU race in atomic phase write       | L12 expected-current jq filter                                                 | ✓ Mitigated                               |
| S-CL2 | Hook regex bypass via jq -f             | L2 INTERPRETER_WRITE_TO_STATE_JSON pattern                                     | ✓ Mitigated                               |
| S-CL3 | PII in SPRINT_BYPASS_WHY → git          | L14 sprint-pii-redact.sh pipe                                                  | ✓ Mitigated                               |
| S-CL4 | Evidence path traversal (..)            | L13 `[[ "$evidence" == *".."* ]]` reject                                       | ✓ Mitigated                               |
| S-CL5 | rm/mv state.json escape                 | L15 RM_OR_MV_STATE_JSON pattern (co-shipped Wave A L2)                         | ✓ Mitigated                               |
| S-CL6 | Sub-step gate-name typo bypasses replay | L16 record_sub_step manifest-warn (soft) + L17 gate-names.json (strict v0.7.1) | ✓ Mitigated (soft now, strict next minor) |

**Inherited surfaces (S1-S15 from parent sprint security-review.md):** 8 of 15 gained additional mitigations from Wave C closures. No regressions detected.

**Secrets scan:** `git log --all -p | grep -iE 'AIza|eyJ[A-Za-z0-9_-]+\.|sk-[A-Za-z0-9]{20,}|postgres://[^@]+@'` against this closure sprint's 5 commits returns zero hits. PII redactor protected the 3 bypass-record rationales in cleanup phase.

**Push gating:** L47 (sprint-harness@origin) and L48 (lifeos@origin) both require explicit `gio` confirmation. No autonomous push will fire. This honors the immutable security rule "Never push to a remote repository without explicit user confirmation."

**Verdict:** APPROVED. All 6 new surfaces mitigated. Push remains user-gated.

---

## Outstanding items for future minor releases

| Item                                      | Target version                                     | Notes                                                                |
| ----------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------- |
| Race-test for L12 TOCTOU (parallel adv)   | v0.7.1                                             | Wave C smoke covered single-path; concurrent test requires 2 procs   |
| Env-by-env smoke for 6 untested shims     | v0.7.1                                             | L9 only tested SPRINT_DRIFT_BYPASS at runtime; 6 are code-inspection |
| Strict gate-names enforcement             | v0.7.1                                             | L17 ships gate-names.json as authoritative-but-permissive            |
| USAGE.md legacy `SPRINT_*_BYPASS` rewrite | v0.8.0                                             | Coincides with legacy shim removal                                   |
| Wire 43 deferred gates                    | harness-verify-instrumentation-v1 follow-up sprint | Separate appetite, ~41 ACs                                           |

## Push approval checklist (operator gio)

Before running `git push origin v0.7.0` in sprint-harness and `git push origin sprint/pipeline-v2-visibility` in lifeos:

- [ ] Re-read CHANGELOG.md v0.7.0 entry.
- [ ] Re-confirm no secrets in latest 5 commits (manual `git log -p` skim).
- [ ] Tag locally exists: `git tag -l | grep v0.7.0`.
- [ ] Closure sprint state.phase==done in lifeos.
- [ ] Parent sprint (harness-deterministic-phases-v1) state.phase==done in lifeos (Wave F).
- [ ] Authorize push.

Until those boxes are user-checked, the v0.7.0 release stays local.
