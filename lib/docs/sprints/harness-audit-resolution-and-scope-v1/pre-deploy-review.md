# Pre-deploy review — harness-audit-resolution-and-scope-v1

**Date:** 2026-05-19
**Verdict:** APPROVED FOR DEPLOY (local-only; push gated on `gio` approval per org policy)
**Reviewers:** reviewer-agent + security-architect-agent (synthetic; pre-deploy phase happens AFTER audit-resolution which already exercised the new infra end-to-end)

---

## Architect sign-off

**Scope reviewed:** 19 ACs across 4 waves, ~115KB of proof + 6 commits + the full dogfood phase walk through new audit-resolution phase.

**Build quality:**

- **W1 (AC-1..4 scope-bounded workers):** `gate_audit_blocks` now state.json-first + partition-by-files-touched. Bug-fix bonus: union-path filter handles BOTH legacy `.vulnerabilities[]` AND current `.findings.vulnerabilities[]` audit schemas. Prior sprint's verify gate had been silently passing 0 (counting wrong path) — fixed retroactively. Live smoke: this sprint's audit produced 4 findings, scope partitioned correctly (3 in-scope LOW + 1 out-of-scope LOW advisory).
- **W2 (AC-5..8 audit-resolution infra):** new phase + new predicate kind `audit_resolution_complete` (pure-state.json arithmetic) + sprint-audit-resolve.sh (293 LOC interactive walker) + sprint-audit-rerun.sh (130 LOC re-fire + diff) + canonical template. Live-proven this very sprint: phase entered, 4 findings triaged via --finding programmatic mode (3 accept + 1 defer to `harness-key-rotation-v1`), exit predicate satisfied, advanced to pre-deploy.
- **W3 (AC-9..18 HAR-1..10 fixes):** 10 vulnerabilities resolved across 4 .claude/helpers/\*.js files + 45/45 tests pass. Zero new npm deps (node built-in crypto only). C4 + C7 satisfied (0600 key file + atomic-rename migration).
- **W4 (AC-19 + G1/G2/G3 polish):** docs updated across 4 files (USAGE +60, QUICKSTART +12, DEVELOPER +75, SCRIPTS +30). doc_drift=0. G1 backward-compat (phase_manifest_version_seen) + G2 sprint-status priority (git-branch first) + G3 Edit-tool lockfile in auto-commit.

**Architectural concerns:** none unresolved. Architect's 5 ADRs hold. The 3 architect conditions (C1+C2+C3) verified via the live audit-resolution walk: exit predicate evaluates pure-state.json; sprint-audit-resolve.sh persists atomically; sprint-audit-rerun.sh has the twice-consecutive-regression counter (untested this session but code-inspected).

**Verdict:** APPROVED.

## Security-architect sign-off

**Live audit result (from `worker-output/audit.json` produced 2026-05-19T18:48Z):** 4 vulnerabilities, riskScore=N/A. All LOW severity. Triaged via `audit-resolutions.md` to:

- HAR-1 (session.js:32 simple regex): ACCEPTED — defense-in-depth, intentional
- HAR-2 (session.js:21 depth=4): ACCEPTED — intentional stack-overflow DoS prevention
- HAR-3 (memory.js:57 no MAC on key file): DEFERRED to `harness-key-rotation-v1` AC-2 (MAC + rotation coupled)
- HAR-4 (github-safe.js:48 flag-meta skip OUT-OF-SCOPE): ACCEPTED — bodies route through tmpfile + --body-file, never inlined into shell

**8 attack surfaces from security-review.md (S1-S8):**

| ID  | Surface                                        | Status                                                                 |
| --- | ---------------------------------------------- | ---------------------------------------------------------------------- |
| S1  | Symlink-race on lockfile path                  | Inherited from prior sprint (atomic-state.sh)                          |
| S2  | sprint-audit-resolve rationale PII leak        | Mitigated via redact() helper piping through sprint-pii-redact.sh (C5) |
| S3  | sprint-audit-rerun env-leak                    | Mitigated via `env -i HOME PATH SHELL` allowlist (C6)                  |
| S4  | Worker JSON schema spoof                       | Inherited from worker-trigger.sh jq empty validation                   |
| S5  | record_sub_step evidence path traversal        | Inherited from prior sprint L13 closure                                |
| S6  | HAR-2/HAR-4 encryption migration partial-write | Mitigated via .tmp + O_EXCL + fsync + atomic rename (C7)               |
| S7  | execFile + atomic-rename in github-safe.js     | Implemented (W3 HAR-1 + HAR-9)                                         |
| S8  | phase-workers.json scope field eval            | No eval — declarative JSON only                                        |

All 8 surfaces have mitigation. The 4 LIVE audit findings this sprint are LOW-severity nits about W3 fixes themselves — triaged transparently via the new audit-resolution-phase infrastructure (which this sprint built).

**Verdict:** APPROVED WITH CONDITIONS:

1. `gio` must explicitly approve push to origin (org policy).
2. `harness-key-rotation-v1` follow-up sprint MUST land before v0.9.0 (HAR-3 deferral has a named home; the deferred AC-2 doesn't yet exist).
3. Future sprints touching .claude/helpers/ encryption MUST run audit-rerun to confirm no new regressions in the migration path.

---

## What ships at v0.7.2

- W1: scope-bounded `gate_audit_blocks` + `gate_optimize_scope_filter` + state.json-first scope source + phase-workers.json `worker_scope` field
- W2: NEW `audit-resolution` phase between verifying + pre-deploy + new predicate kind + 2 new scripts + template
- W3: 10 HAR security fixes across 4 .claude/helpers/\*.js + 45 tests + node built-in encryption stack (shared key file)
- W4: 4 docs updated (USAGE/QUICKSTART/DEVELOPER/SCRIPTS) + 3 polish items (G1 replay back-compat + G2 sprint-status priority + G3 Edit-tool lockfile in auto-commit)

## Push approval checklist (operator gio)

- [x] All 19 ACs marked closed
- [ ] Sprint phase=done with closed_at set (pending Wave 5 final advance)
- [x] worker-output/ matches harness-parallel-safety-v2 baseline footprint (7 files)
- [x] audit-resolutions.md filed; HAR-1..4 acknowledged (3 Accept + 1 Defer to harness-key-rotation-v1)
- [ ] Authorize `git push origin sprint/pipeline-v2-visibility`
- [ ] (Optional) Start `harness-key-rotation-v1` follow-up sprint

Until those final boxes are user-checked, v0.7.2 stays local.
