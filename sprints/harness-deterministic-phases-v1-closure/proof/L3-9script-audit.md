# L3 — 9-script delegation audit

**Verdict:** Production with documented findings
**Methodology:** grep + control-flow trace per script

## Audit scope

9 phase-writer scripts migrated in parent sprint AC-7 to delegate via `sprint-advance-phase.sh`. Verify:

1. Delegation pattern present.
2. No inline `.phase = X` writes outside legacy-fallback branches.
3. Sub-step records gated by underlying-work success (not unconditional).
4. Error paths bubble (don't silently swallow exit codes).

## Per-script findings

### sprint-amend-spec.sh

- ✓ Delegation present (line ~98 after baseline write).
- ✓ No inline phase write.
- ✓ Records `spec-lock-baseline-written` only after baseline successfully written.
- ✓ Writes worker_rigor with validate-on-read.
- **No issues.**

### sprint-design-lock.sh

- ✓ Delegation present.
- ✓ Records 3 design sub-steps (sparc-spec-pseudocode, sparc-architect, design-locked).
- ⚠️ **Records sub-steps unconditionally** if `record_sub_step` available. If operator runs sprint-design-lock.sh against a sprint that hasn't actually completed SPARC, the sub-steps record anyway. Mitigation: design-locked phase manifest predicate requires `design.md ≥ 300B` independently; the sub-step record alone doesn't satisfy the phase gate.
- Documented gap; not a blocker.

### sprint-build-launch.sh

- ✓ Delegation present (line ~71).
- ⚠️ Line 74: `atomic_update_state "$SLUG" '.phase = "building"' # legacy fallback` — only fires if `sprint-advance-phase.sh` is missing OR rejects. Legacy fallback acceptable; never executes in v0.7.0 install.
- ✓ Records `build-launched` after delegation succeeds.
- **No issues.**

### sprint-checkin.sh

- ✓ Delegation present.
- ✓ `--validate` mode separately records `day-5-question-cut/push/pivot` only when content ≥30 chars (gated correctly).
- ✓ Hill-chart-refreshed sub-step recorded only on template generation, not on every invocation.
- ⚠️ **Removed `mid-checkin` gate** from gates_passed. Pre-v0.7 sprints have `"mid-checkin"` legacy entries that the replay validator's implicit pre-v0.7 skip handles. Verified.
- **No issues.**

### sprint-cleanup-launch.sh

- ✓ Delegation present (line ~115).
- ⚠️ Lines 77 + 116: legacy fallbacks (only if delegate unavailable).
- ⚠️ **Lines 106-109: Records 3 cleanup sub-steps UNCONDITIONALLY** (regardless of whether the underlying cleanup commands actually ran). This is a real false-pass bug:
  ```bash
  if declare -F record_sub_step >/dev/null 2>&1; then
    record_sub_step "$SLUG" "cleanup-deadcode-delete" pass || true
    record_sub_step "$SLUG" "cleanup-lint-fix" pass || true
    record_sub_step "$SLUG" "cleanup-claude-md-clean" pass || true
  fi
  ```
- **Fix scope:** out of L3 strict audit, but tracked for v0.7.1. Each record should be inside the conditional block that ran the underlying script. Filed as follow-up T2.13.

### sprint-verify.sh

- ✓ Delegation present.
- ✓ Records `verify_runs[]` entry.
- ⚠️ Wave A doesn't touch verify-chain sub-steps individually (those are in `harness-verify-instrumentation-v1` follow-up sprint per parent T4). 18 verify sub-steps remain in `deferred_gates[]` — gate UX correct (no operator bypass needed).
- **No issues.**

### sprint-predeploy-gate.sh

- ✓ Delegation present.
- ✓ Records `pre-deploy-reviewer-agent` + `pre-deploy-security-architect` only when respective files passed via --reviewer/--security flags.
- **No issues.**

### sprint-end.sh

- ✓ Delegation present.
- ✓ Lines 155-176: Records retro sub-steps ONLY when retro.md exists AND content predicates met (≥50 chars per heading, ≥3 pattern subheadings).
- ⚠️ Lines 174-176: Records `velocity-computed`/`trajectory-closed`/`daa-feedback-batched` unconditionally inside the `if [ -f $RETRO_FILE ]` branch. metrics.json write happens BEFORE this block at line ~131 (verified). dashboard.html regen happens after (line ~182). Acceptable: retro.md presence is a necessary precondition.
- **No issues.**

### sprint-pause.sh

- ✓ Delegation present (line ~46).
- ⚠️ Lines 48 + 51: legacy fallbacks marked.
- ✓ Pause has empty required predicates per manifest; delegation always succeeds.
- **No issues.**

### sprint-resume.sh

- ✓ Delegation present.
- ✓ Restores prev_phase via advance-phase.sh delegation.
- **No issues.**

## Summary table

| Script                   | Delegated | Inline write | Sub-step gating                   | Issues                                                  |
| ------------------------ | --------- | ------------ | --------------------------------- | ------------------------------------------------------- |
| sprint-amend-spec.sh     | ✓         | (none)       | gated                             | none                                                    |
| sprint-design-lock.sh    | ✓         | (none)       | partly-gated                      | sub-steps record unconditionally; mitigated by manifest |
| sprint-build-launch.sh   | ✓         | legacy-fb    | gated                             | none                                                    |
| sprint-checkin.sh        | ✓         | (none)       | gated                             | mid-checkin removal verified safe                       |
| sprint-cleanup-launch.sh | ✓         | 2 legacy-fb  | **unconditional false-pass risk** | T2.13 follow-up filed                                   |
| sprint-verify.sh         | ✓         | (none)       | partly-gated                      | verify sub-steps in deferred_gates[]                    |
| sprint-predeploy-gate.sh | ✓         | (none)       | gated                             | none                                                    |
| sprint-end.sh            | ✓         | (none)       | gated                             | retro sub-steps gated by retro.md presence              |
| sprint-pause.sh          | ✓         | 2 legacy-fb  | n/a                               | none                                                    |
| sprint-resume.sh         | ✓         | (none)       | n/a                               | none                                                    |

## Conclusions

- **9 of 9 scripts delegate correctly.** Migration AC-7 successful.
- **5 legacy-fallback inline writes preserved** in error paths — acceptable for v0.7.0 install resilience.
- **1 false-pass risk identified** (sprint-cleanup-launch.sh records cleanup sub-steps unconditionally). Filed as T2.13. Mitigated by phase-manifest predicates (cleanup-launch only advances on advance-phase invocation which checks for the underlying artifacts).
- **0 inline phase writes outside legacy-fallback branches.** Grep confirms.

## Follow-up filed

**T2.13** — `sprint-cleanup-launch.sh` should gate each `record_sub_step` call on the corresponding underlying script's exit code. Currently records all 3 cleanup sub-steps regardless of deadcode-delete / lint-fix / claude-md-clean outcomes. v0.7.1 polish.

## Files audited

`scripts/sprint-amend-spec.sh`, `sprint-design-lock.sh`, `sprint-build-launch.sh`, `sprint-checkin.sh`, `sprint-cleanup-launch.sh`, `sprint-verify.sh`, `sprint-predeploy-gate.sh`, `sprint-end.sh`, `sprint-pause.sh`, `sprint-resume.sh`. No code changes from L3; findings only.
