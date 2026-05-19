# Day-5 Check-in — harness-deterministic-phases-v1

**Date:** 2026-05-19 (compressed timeline — sprint was built in a single autonomous session, so "Day 5" is mid-Wave-3 reality).

## Hill chart status (per AC)

| AC    | Title                                     | Hill position             | Notes                                                                                                                                                                                                   |
| ----- | ----------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AC-1  | phase-manifest.json + schema              | Downhill ✓ closed         | Manifest + schema + validator shipped. 68 gates declared.                                                                                                                                               |
| AC-2  | phase-predicates.sh                       | Downhill ✓ closed         | 9 predicate kinds + bypass-aware. Set -x leakage debugged.                                                                                                                                              |
| AC-3  | sub-step.sh::record_sub_step              | Downhill ✓ closed         | Idempotent dual-write working. Legacy bare-string upgrade verified.                                                                                                                                     |
| AC-4  | sprint-advance-phase.sh canonical mutator | Downhill ⚠️ closed-broken | **Bug**: bypass records BEFORE manifest gate-name validation. Typo'd gates silently recorded. Follow-up T2.1 required before v0.7.0 ship.                                                               |
| AC-5  | sprint-hook.cjs jq + state.json blockers  | Downhill ⚠️ closed-broken | Hook works in synthetic test. **Not verified in real Claude Code flow.** Plus 2 known regex gaps (T2.6 jq bracket syntax, T2.7 sed/redirect). Follow-up T2.5+T2.6+T2.7 required.                        |
| AC-6  | bypass.sh check_bypass                    | Downhill ✓ closed         | Single-bypass UX working. Legacy shim emits deprecation.                                                                                                                                                |
| AC-7  | Migrate 11 phase-writers to delegate      | Downhill ✓ closed         | 9 scripts migrated (plan over-counted "11" — actual is 9; 2 were read-only).                                                                                                                            |
| AC-8  | Sub-step instrumentation (50+ gates)      | **Under-the-hill ⚠️**     | Only 15 of 68 (22%) sub-step gates instrumented. The other 53 require bypass per sprint. Biggest gap. T4 follow-up sprint required.                                                                     |
| AC-9  | Schema unification gates/gates_passed     | Downhill ✓ closed         | Dual-write verified. Union-read in predicate engine + replay validator.                                                                                                                                 |
| AC-10 | Wizard §J worker_rigor question           | Downhill ⚠️ closed-broken | §J5 question in skill doc + amend-spec writes state. **sprint-spec-wizard.mjs at answer-time does NOT write state.worker_rigor**. If operator skips amend-spec --lock, field stays null. T2.2 required. |
| AC-11 | Day-5 sentinel headings                   | Downhill ✓ closed         | --validate mode + 3 H3 sentinels enforced. Bash 3.2 + pipefail gotchas surfaced.                                                                                                                        |
| AC-12 | Retro completeness in sprint-end.sh       | Downhill ✓ closed         | 6 H2 sections + 3+ patterns enforced. Dashboard regenerated pre-advance.                                                                                                                                |
| AC-13 | --replay-gate-history validator + CI wire | Downhill ✓ closed         | 235-line validator. Catches a real corrupt state.json in onboarding-flow-v2/.                                                                                                                           |
| AC-14 | Documentation rewrite                     | **Under-the-hill ⚠️**     | Only USAGE.md "## Phase enforcement" + sub-step-coverage.md shipped. **DEVELOPER.md, bypass-cheatsheet.md, SKILL.md rewrites deferred** (T3.1, T3.2, T3.3).                                             |

## Three questions

### Cut

**No ACs to cut**, but **4 ACs should be re-graded from Production to Broken-with-followup**:

- **AC-4 (T2.1)** — bypass-pre-validation order bug. Typo'd `SPRINT_BYPASS_GATE=desgin-locked` silently records meaningless bypass. Must validate against manifest gate names BEFORE recording. ~15-minute fix.
- **AC-5 (T2.5, T2.6, T2.7)** — hook unverified in real Claude Code flow + 2 known regex bypass paths (`jq '["phase"]=…'` bracket syntax; `sed -i` + Bash redirect). Two ~15-min regex fixes plus one ~30-min Claude Code flow smoke test.
- **AC-10 (T2.2)** — wizard §J5 doesn't write state.worker_rigor at answer-time. ~15-minute fix in `sprint-spec-wizard.mjs`.
- **AC-14 (T3.1, T3.2, T3.3)** — 3 of 4 promised doc rewrites deferred. ~2 hours total.

Re-grading is honesty, not scope-cutting. Total reality: **9/14 Production + 5/14 Broken-with-followup-AC**. The 5 broken ones have follow-up ACs tracked.

### Push

**Push to ship v0.7.0 if and only if T2.1 + T2.2 + T2.5 + T2.6 + T2.7 land first** (5 small fixes, ~2 hours work). These are the architect+security review ship-blockers from `architect-review.md` + `security-review.md`. Without them, v0.7.0 has known attack paths and known broken operator flows.

T4 (AC-8 instrumentation gap — 53 unwired gates) is **NOT a ship blocker** because:

- Manifest still declares correct enforcement
- Operators bypass with rationale (audit-trail intact)
- Follow-up sprint `harness-verify-instrumentation-v1` wires the rest
- BUT operator UX will be bad on first real sprint until that follow-up lands

T3.1 + T3.2 + T3.3 (the deferred doc rewrites) **ARE recommended pre-ship** because v0.7.0 changes operator workflow significantly. Without the rewrites, operators read stale prose in DEVELOPER.md + SKILL.md.

### Pivot

**No pivot needed** on the core architecture. Sketch 3 (manifest + canonical mutator + chokepoint) survives architect + security review with conditions. The 6-dimensional comparison in `solution-sketches.md` validates the choice.

**Pivot on retrospective honesty**: the original retro.md claimed 14/14 Production. That was wrong. Updated retro.md (T1.7) will record honest verdicts + explicitly call out the architectural pattern "build the chokepoint, then dogfood it through ITS OWN gates" as a tooling-bootstrap exercise where corner-cutting happens because the operator (me) is both auditor and audited. New retro pattern to capture: **"meta-dogfood paradox"** — building the gates that would have caught your own corner-cutting is a perfect setup for corner-cutting.

## Sub-step gates recorded (this check-in)

After running `sprint-checkin.sh harness-deterministic-phases-v1 --validate`:

- `day-5-question-cut` ✓ (≥30 chars)
- `day-5-question-push` ✓ (≥30 chars)
- `day-5-question-pivot` ✓ (≥30 chars)
- `day-5-hill-chart-refreshed` ✓ (recorded at template generation)

These 4 sub-step gates satisfy the day-5-checkin phase's `required_sub_step_gates[]` per `phase-manifest.json`. Confirmed via `jq '.gates_passed[] | select(type=="object" and (.gate | startswith("day-5-"))) | .gate'`.
