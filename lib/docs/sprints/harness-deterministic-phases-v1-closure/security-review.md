# Security Review — harness-deterministic-phases-v1-closure

> **Threat model.** This closure sprint extends + hardens existing surfaces from parent. New surfaces introduced: gate-names.json constants file, broader hook regex, evidence canonicalization, PII redaction at bypass write. Same actors as parent: (a) AI model under token pressure, (b) misconfigured operator.

---

## New attack surfaces introduced by this sprint

### S-CL1 — `gate-names.json` tampering

**Attack.** Model edits `scripts/lib/gate-names.json` to remove a gate name. Validator now permits any record_sub_step against the removed name.

**Likelihood.** Medium — model treats it as another file.

**Impact.** High — removes a gate from enforcement chain.

**Mitigation.** Scope hook blocks the edit unless sprint's `## Files touched` lists it. Validator runs at advance-phase invocation. CI runs validator on every PR.

**Residual risk.** Same as parent S6 (manifest tampering). PR review is the human gate.

---

### S-CL2 — `--report-file` path traversal (L19)

**Attack.** `node scripts/sprint-replay-validator.mjs --report-file /etc/passwd` writes report to arbitrary location.

**Likelihood.** Low — requires shell access (already trusted at that level).

**Impact.** Low — write-only, doesn't read user files. Worst case: corrupt root-owned files (sudo needed).

**Mitigation.** Document that `--report-file` writes wherever the user has permission. Don't add path validation (operator's responsibility).

**Residual risk.** Acceptable. Standard CLI tool behavior.

---

### S-CL3 — PII redaction over-redaction (L14)

**Attack.** Legitimate rationale `"Used SPRINT_DRIFT_BYPASS=1 because the JWT-rotation flow was being tested"` gets the literal string `JWT` redacted, corrupting the audit trail.

**Likelihood.** Medium — sprint-pii-redact.sh is regex-based.

**Impact.** Medium — audit trail less useful but not data-leaking.

**Mitigation.** Test redactor against 10 common rationale patterns; if any false-positive, refine regex. Store the ORIGINAL hash (sha256 of raw why) alongside redacted version so reviewers can verify legitimacy.

**Residual risk.** Acceptable if test passes; documented in bypass-cheatsheet.

---

### S-CL4 — TOCTOU-safe filter break under flock contention (L12)

**Attack.** Two concurrent advance-phase invocations under high lock contention; flock timeouts queue up; expected_phase check fires after lock acquired but state has changed.

**Likelihood.** Very low — requires real parallel sprints + tight timing.

**Impact.** Low — second invocation exits with error (which is the desired behavior); first invocation completes normally.

**Mitigation.** L12's jq filter assertion fires under the same lock that wraps the write. Read + check + write are atomic. **Correctly fails** the second invocation.

**Residual risk.** None.

---

### S-CL5 — `gate-names.json` bootstrap-mode false-pass

**Attack.** During bootstrap (v0.7.0), validator runs in "permissive" mode allowing manifest names not yet in gate-names.json. Model could add a fake gate to manifest, bootstrap, then advance-phase silently passes.

**Likelihood.** Low — bootstrap runs once per repo lifetime.

**Impact.** Medium — could silently weaken enforcement.

**Mitigation.** Bootstrap requires `--bootstrap-gate-names` explicit flag (not default). Logged + git-committed. Reviewer sees the file's first creation in the PR.

**Residual risk.** Acceptable with PR review discipline.

---

### S-CL6 — `pgrep` parent-walk DoS in L1 fallback

**Attack.** If L1 falls back to `pgrep -af sprint-advance-phase.sh` walking process tree, attacker could spawn many processes matching the pattern to slow down hook invocation.

**Likelihood.** Very low — requires local fork-bomb-like attack.

**Impact.** Low — hook slower; ultimate operation still gated by atomic_update_state.

**Mitigation.** Cap pgrep walk depth to 3 parent generations. If no match within depth, fall back to env-only check + log.

**Residual risk.** Acceptable.

---

## Inherited surfaces re-reviewed (from parent's S1-S15)

| Parent surface             | Status after closure work                                                              |
| -------------------------- | -------------------------------------------------------------------------------------- |
| S1 env spoof               | Mitigation unchanged. L1 verifies in real flow.                                        |
| S2 state.json edit         | Mitigation unchanged. L15 adds rm/mv block.                                            |
| S3 inline jq               | L2 closes the bracket-syntax + sed/python/awk/perl + redirect gaps.                    |
| S4 bypass abuse            | L9 verifies legacy shims; existing audit trail unchanged.                              |
| S5 gate_bypasses unbounded | L17 (gate-names constants) caps namespace; bypass.sh records idempotent.               |
| S6 manifest tampering      | Same — PR review + scope hook + AC-13d drift. L20 fixes false-positive scope.          |
| S7 atomic-state TOCTOU     | **L12 closes** with expected_phase assertion.                                          |
| S8 sub-step concurrent     | Mitigation unchanged.                                                                  |
| S9 evidence traversal      | **L13 closes** with canonicalize + ".." reject.                                        |
| S10 lock-dir umask race    | Mitigation unchanged.                                                                  |
| S11 WHY plaintext PII      | **L14 closes** via sprint-pii-redact.sh.                                               |
| S12 hook fail-open         | Documented behavior unchanged.                                                         |
| S13 absolute path leak     | **L13 also closes** via repo-relative canonicalization.                                |
| S14 state.json deletion    | **L15 closes** with rm/mv hook block.                                                  |
| S15 strict unwireable      | **Wave A L4 + AC-8 deferred_gates[]** mean strict mode no longer requires 50 bypasses. |

**Net effect of closure work**: 8 of 15 parent surfaces gain new mitigations. Residual risk reduced across the board.

---

## Required for closure sprint to be ship-ready

1. **L14 redactor test corpus** — 10 sample rationales pre/post redaction. Any over-redaction = block until regex refined.
2. **L1 real-flow proof file** — must show legitimate advance-phase invocation passes hook (RC=0) AND attack jq blocks (RC=2). Both required.
3. **L2 4 attack patterns proven blocked** — `jq -f`, `python -c`, `awk` redirect, `perl -i`. All inject-violation-catch-restore.
4. **L15 inject proof** — `rm docs/sprints/X/state.json` blocks; `mv state.json /tmp/...` blocks.
5. **L17 bootstrap proof** — generate gate-names.json from manifest, validator strict mode passes.

Without all 5, the closure sprint repeats the parent's audit failure pattern.

---

## Verdict

**APPROVED WITH CONDITIONS.** All 6 new attack surfaces have acceptable mitigations. 8 of 15 inherited surfaces gain new mitigations. Net security posture improves significantly. The 5 closure-specific proof requirements above are tracked as Wave A/C verification artifacts.

Out of scope (acknowledged):

- Kernel-level FS monitoring (would close S3 / S14 fully); too heavy for our threat model.
- Cryptographic signing of state.json (would close S6 manifest tampering definitively); also too heavy.
- Multi-operator review-required-before-bypass (S4 abuse); operator discipline + audit-trail visibility is sufficient for solo-operator harness.
