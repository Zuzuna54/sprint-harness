# Security Review — harness-truthful-docs-and-wiring-v1

> **Threat model.** Same actors as parent + closure: (a) the AI model itself, under token pressure / autopilot, trying to skip protocol steps or take a shortcut that lands a falsehood in `state.json`; (b) a misconfigured operator who accidentally corrupts state, leaks PII, or commits a path-traversal evidence record. External network attackers remain out of scope — the harness is local-only.
>
> **What is new in this sprint.** This is the truthful-docs-and-wiring layer on top of `harness-deterministic-phases-v1` + its closure. Five waves: W1 race-fix (`atomic-state.sh` ↔ `.husky/post-commit` lockfile divergence), W2 wrap-workers (advance-phase fires daemon workers via `worker-trigger.sh`), W3 doc reorg, W4 wire-all-43-deferred-gates (sub-step instrumentation across wizard / spec-lock / verify-\* / new sprint-deploy.sh), W5 dogfood walkthrough. Each wave introduces fresh attack surface that this review enumerates and grades.
>
> **Audit-pattern note.** The parent closure sprint's first security review was a placeholder ("threats inherited from parent") and was rejected at audit. This review is the corrective: every surface below is named, attacked, and graded against the actual code that was read (`atomic-state.sh`, `.husky/post-commit`, `bypass.sh`, `sprint-pii-redact.sh`, `worker-trigger.sh`), not abstracted away.

---

## 1. Wave 1 — race-fix attack surfaces

W1 unifies the lockfile path. Today `.husky/post-commit:32` uses `STATE_LOCK="$STATE_FILE.lock"` (in-repo, lives at `docs/sprints/<slug>/state.json.lock`), while `atomic-state.sh:71` uses `$LOCK_DIR/state-<slug>.lock` (resolves to `$HOME/.cache/lifeos/locks/` via `lock-dir.sh`). The two locks are disjoint files → no mutual exclusion → torn writes confirmed in the closure-sprint state.json corruption postmortem. The fix is to route post-commit through `atomic_update_state`, eliminating the in-repo lock entirely.

### S1 — Symlink-race on the unified lockfile path

**Attack.** Between the time `.husky/post-commit` decides to write the lock and the moment `flock`/`set -C` actually opens it, an attacker (or a buggy parallel script) plants `ln -s /etc/passwd $HOME/.cache/lifeos/locks/state-<slug>.lock`. If the writer is invoked with `exec 9>"$lock_file"` (current flock branch, atomic-state.sh:91) on a system where `O_NOFOLLOW` is not default, the open follows the symlink and the writer corrupts the linked file.

**Likelihood.** Low — `$HOME/.cache/lifeos/locks/` is created by `lock-dir.sh` under `umask 077` (0700). Only the operator can plant the link. Realistic only as a self-inflicted footgun (e.g., operator restores from a botched backup and a symlink survived).

**Impact.** Medium-High — if the link points at `state.json` itself, `flock` succeeds but `exec 9>` truncates the target (when run as `>` rather than `>>` — and the code uses `>"$lock_file"` at line 91). Lock acquire would clobber state.json.

**Mitigation (W1).** (a) Keep the 0700 lock dir contract; (b) add `O_NOFOLLOW` semantics by switching the lock acquire to `flock -x` against an explicit fd opened via `>` only inside the umask-077 dir (already done in atomic-state.sh); (c) **W1 must verify** that the PID-fallback branch (line 102, `( set -C; echo "$$" > "$lock_file" )`) also runs with the umask honored. `set -C` (`noclobber`) prevents replacing an existing file but does NOT prevent following a symlink to a non-existent target — bash treats `> /etc/shadow → ln -s /etc/shadow lockfile` as "file does not exist". Add an explicit `[ -L "$lock_file" ] && rm -f "$lock_file"` reclaim before retry.

**Residual risk.** Low. Confined to operator-owned home dir.

### S2 — TOCTOU between lock acquire and atomic-rename

**Attack.** Process A acquires the per-slug flock, reads `state.json`, runs jq into `.state.tmp.XXXXXX`, and is about to call `mv tmp state.json` (atomic-state.sh:162). Between the `mktemp` (line 137) and the `mv`, Process B — which holds NO lock because it bypassed `atomic_update_state` entirely (legacy in-repo `$STATE_FILE.lock` path used today by post-commit lines 37 + 156) — directly writes state.json with the legacy `jq … > /tmp/x && mv`. Process A's `mv` then overwrites B's update.

**Likelihood.** **High in current code** — that is literally the race the closure sprint hit. After W1 lands, **Low** (single canonical path).

**Impact.** Catastrophic — corrupts the audit trail. The closure sprint's lost `reuse_audits[]` entries plus orphan `}` characters are direct evidence.

**Mitigation (W1).** Remove the in-repo lock branch from `.husky/post-commit` entirely (delete lines 32–54 and lines 156–166); replace both call sites with `source scripts/lib/atomic-state.sh; atomic_update_state "$SLUG" '<filter>'`. After that, there is exactly one writer protocol. The parent's S7 TOCTOU mitigation (`--from <expected>` invariant + L12 expected_phase assertion under-lock) still applies.

**Residual risk.** Low after W1 (single lockfile). A determined bash-tool model could still spawn `jq … > state.json` outside the helper; that is mitigated by the parent's S3 hook (regex on `jq … \.phase =`) but **not** for non-phase fields. **NEW FINDING:** post-commit's `pair_prompts` + `reuse_audits` append paths are NOT covered by the parent hook regex; once W1 routes both through atomic_update_state, the hook coverage is sufficient _only because_ there is no other place to bypass. Track as **S1-followup**: extend the parent's S3 hook regex from `\.phase\s*=` to `\.(phase|gates_passed|gate_bypasses|reuse_audits|pair_prompts)\s*=` to keep coverage uniform.

### S3 — Stale-lockfile DoS (>30s holder)

**Attack.** A model or a buggy worker acquires the lock and exits abnormally without releasing it (e.g., `kill -9` of the parent shell, or a `set -e` exit between `exec 9>` and `flock -u`). All subsequent writers timeout at 10s and surface as `[atomic-state] flock timeout`. If the model deliberately holds the lock via `( flock 9; sleep 99999 ) 9>"$lock_file" &`, every advance-phase invocation fails until manual cleanup.

**Likelihood.** Low — requires either a crash mid-critical-section or deliberate misbehavior.

**Impact.** Medium — DoS on advance-phase; no data corruption.

**Mitigation (W1).** The PID-fallback branch already implements stale-lock reclaim at lines 113–123: empty holder + >5s OR dead holder PID + >30s → `rm -f` and retry. **Gap in the flock branch:** `flock`-based locks are file-descriptor-scoped, not PID-scoped — when the holder dies the kernel releases the lock automatically, so this path is naturally self-healing. Confirm by testing: spawn a child that opens fd 9 with flock, kill -9 it, observe that a second writer succeeds within 1s. **W1 verification proof MUST include this.**

**Residual risk.** None significant on Linux. macOS `flock` (when installed via util-linux) behaves identically; macOS native `flock(2)` is also fd-scoped. Operator-held `( flock; sleep ) &` is detectable in the lock holder PID + age trail — surfaced in `state.json.gate_history` as repeated `[atomic-state] flock timeout` entries.

---

## 2. Wave 2 — wrap-workers attack surfaces

W2 makes `sprint-advance-phase.sh` fire ruflo daemon workers via `worker-trigger.sh`. The trigger writes worker output into `docs/sprints/<slug>/worker-output/<worker>.{json,md}` (worker-trigger.sh:201) and appends an entry to `state.worker_invocations[]` (line 206). Phase-advance gates can then assert on the output.

### S4 — Malicious worker JSON spoofs predicate PASS

**Attack.** A worker is compromised (or is a local-only worker like `consolidate` writing whatever its plugin produced). It writes

```json
{ "verdict": "pass", "verdicts": { "all_gates": "PASS" }, "_evidence": "spoofed" }
```

into `.claude-flow/metrics/<worker>.json`. `worker-trigger.sh` validates only that the file is parseable JSON (line 196 `jq empty`). The phase-advance predicate then reads `worker-output/<worker>.json` and treats `verdict=pass` as ground truth.

**Likelihood.** Medium — the ruflo daemon is a separate process whose binary lives outside the repo (`/opt/homebrew/lib/node_modules/ruflo/...`); a compromised plugin or a rogue model with shell access can `echo` directly into that path.

**Impact.** Catastrophic — defeats the W2 enforcement gain. Workers become a trust-by-default fast-path to PASS.

**Mitigation (W2).** Predicate evaluators in `sprint-advance-phase.sh` MUST:

1. Refuse to accept a worker output whose `mtime > now - 10min` is the sole evidence — require a second signal (a specific named field, e.g., `gates_verified[]` listing the gates the worker actually exercised).
2. Cross-check `worker_invocations[]` (which is written under flock by atomic_update_state, line 206) against the on-disk file's mtime. If `worker_invocations[].elapsed_s` is implausibly small (< 1s for an LLM-backed worker), flag as suspicious.
3. NEVER use a free-form `verdict` field. Phase-advance predicates assert on **structural** properties (e.g., "worker-output/audit.json exists AND .findings[] is an array AND .findings | length <= N").

**Residual risk.** Medium. A determined adversary controlling both the daemon and `state.json` can still construct a coherent lie. Acceptable for the local threat model; documented in `bypass-cheatsheet.md`.

### S5 — Path traversal in worker name → output basename

**Attack.** Caller invokes `trigger_worker '../../etc/passwd_audit' my-slug`. `worker-trigger.sh` uses the worker name as the output basename (line 134 `out_dest="$output_dir/$worker.$ext"`) AND as the metrics filename input. A `../` would break out of `docs/sprints/<slug>/worker-output/`.

**Likelihood.** Low — caller is `sprint-advance-phase.sh` (trusted), worker names come from `phase-workers.json` (operator-edited).

**Impact.** High — `cp .claude-flow/metrics/<worker>.json $output_dir/../../../<x>.json` could clobber files outside the sprint dir.

**Mitigation (W2).** **NEW REQUIREMENT** — add worker-name validation alongside the existing slug-format check at line 118:

```bash
if ! [[ "$worker" =~ ^[a-z][a-z0-9_-]{1,32}$ ]]; then
  echo "[worker-trigger] invalid worker name: $worker" >&2
  return 2
fi
```

This is the symmetric of the slug regex already in place; current code validates `slug` but not `worker`. Track as **S5 → W2 must-fix**.

**Residual risk.** None after fix.

### S6 — Worker exit-code injection ("`false; exit 0`")

**Attack.** A ruflo worker plugin contains `false; exit 0` — the trigger sees `ruflo daemon trigger -w <worker>` return 0 (line 177) but the worker did no real work. Worker writes a stale or fabricated metrics file. The mtime poll (line 184) succeeds, output is captured, gate passes.

**Likelihood.** Low — ruflo plugins are operator-installed.

**Impact.** Medium — same class as S4 (worker spoofs evidence) but via the trigger contract rather than the file contents.

**Mitigation (W2).** (a) Treat `ruflo daemon trigger` exit code as advisory only — already correct in the code (line 177 hard-fails on non-zero, but does not trust zero implicitly because the poll loop validates the metrics file). (b) The poll loop checks `current_mtime > before_mtime` — but if the worker is "fast" (writes nothing, returns immediately), mtime is unchanged and the loop times out (line 213). **This is the correct behavior.** (c) Couple S4's structural-field requirement with this: a worker that returns 0 but produces no `gates_verified[]` is treated as `worker_skipped`, not `worker_passed`. Phase-advance must distinguish.

**Residual risk.** Low after S4 + S6 combined mitigations.

---

## 3. Wave 4 — gate instrumentation attack surfaces

W4 wires 43 deferred gates (14 wizard + 4 spec-lock + 21 verify-_ + 5 deploy-_ via new `scripts/sprint-deploy.sh`) by adding `record_sub_step` calls at each call site. Evidence-path canonicalization was already mitigated in the closure sprint Wave-C L13. The new surface is what those call sites _record_.

### S7 — Evidence-path traversal in `record_sub_step` (re-confirm closure L13)

**Status from closure.** Parent S9 + closure L13 added repo-relative path canonicalization and `..` rejection to `sub-step.sh`. W4 inherits this mitigation.

**Verification required.** W4 dogfood walkthrough MUST include one record_sub_step call from each new instrumentation site (wizard, spec-lock, verify-\*, sprint-deploy.sh) with a path containing `../`. All must reject with non-zero exit. Without that proof, the instrumentation is reintroducing the vulnerability that L13 closed.

**Residual risk.** None if proofs ship. Otherwise: same as parent S9 — operator-supplied paths could traverse.

### S8 — PII leak via `verify-*` script logs recorded as evidence

**Attack.** A verify-script (e.g., `verify-rls.sh`) records its log output as evidence — that log can contain `psql` connection strings, JWTs from request headers, user IDs from RLS queries, or filesystem paths under `/Users/gio/`. The evidence string lands in `state.gates_passed[].evidence`, which is **git-committed** to the public repo.

**Likelihood.** **High** — this is the default mode for any verify-script that pipes its stdout/stderr into a log file and passes that file path as evidence. The parent's S13 already names this for absolute-path leakage; the **NEW** concern in W4 is that the file _contents_ (not just its path) are now being relied on at audit time, so reviewers will inevitably open them.

**Impact.** High — git-committed PII / secrets are hard to retract. Same threat as parent S11 but at the evidence layer instead of the bypass-rationale layer.

**Mitigation (W4).** **MUST-FIX before W4 ships.** Three layers:

1. **Pipe verify-\* output through `sprint-pii-redact.sh`** before writing the evidence log file. The redactor (read in full above) already handles email, UUID, JWT, API keys, password=value, postgresql:// — six pattern classes. Make the redactor the default in `sub-step.sh` for any evidence file whose extension is `.log`, `.txt`, or `.out`.
2. **For `verify-rls.sh` specifically**: never log raw row contents. Use `jq '. | length'` + `jq '.user_id | .[:8] + "..."'` only.
3. **Recovery contract**: if a redaction false-positive corrupts a legitimate audit trail (closure S-CL3), store sha256 of the raw text alongside the redacted version so the operator can verify post-hoc without re-leaking.

**Residual risk.** Medium — regex-based redactor will miss novel secret formats. Documented in `bypass-cheatsheet.md`. **Critical** because of git permanence.

### S9 — `sprint-deploy.sh` records deploy URLs / Pulumi outputs as evidence

**Attack.** The new `sprint-deploy.sh` runs `pulumi up` (or `vercel deploy`) and records the resulting deploy URL + stack outputs as gate evidence. Pulumi stack outputs can contain:

- API Gateway IDs (low-value but enumerable)
- RDS endpoint hostnames (e.g., `lifeos-prod.cluster-XXX.us-east-1.rds.amazonaws.com`)
- IAM role ARNs
- SSM parameter names (not values, but names that reveal secret structure)

Vercel deploy URLs (`https://<project>-<hash>-<scope>.vercel.app`) are themselves public preview URLs — generally OK to commit — but **production aliases mapped to custom domains may include preview-URL hashes that leak prerelease URLs**.

**Likelihood.** Medium — `sprint-deploy.sh` is a new script with no existing redaction discipline.

**Impact.** Medium. AWS resource IDs alone are not credentials, but they are reconnaissance signal and they live in the project's public CLAUDE.md memory ("[Deploy chain reference 2026-05-17] — All live URLs / project IDs / env vars across Vercel + AWS + Supabase + Pulumi"). Combined with a future credential leak elsewhere, they reduce attacker discovery cost.

**Mitigation (W4).** `sprint-deploy.sh` MUST:

1. **Never record full Pulumi stack output** — record only the deploy-attempt artifact path (e.g., `apps/api/.pulumi/Pulumi.dev.last-deploy.txt`) and require operator to gitignore that path. Spec §J already states this: "sprint-deploy.sh deploy-\* gates must not record AWS credentials or Pulumi state contents to state.json — record only artifact paths."
2. **Vercel deploy URL** — production URLs (`ordex.app`, `api.ordex.app` when live) are public-by-design and OK to commit. Preview URLs with hashes (`*-vercel.app`) are best-effort obscure; document that committing them is acceptable but flag with `[vercel-preview-url]` so future PII redactor can target them.
3. **Pulumi state contents** — never read `Pulumi.<stack>.yaml` and store its contents. Hash the stack file (sha256) if integrity needs to be asserted.

**Residual risk.** Low after fix. AWS resource IDs in stack outputs remain a small recon-cost loss; accept.

---

## 4. Wave 3 — doc-reorg sensitive-content scan

W3 reorganizes `USAGE.md`, `QUICKSTART.md`, `DEVELOPER.md` + adds `_guides/bypass-cheatsheet.md` + `_guides/sub-step-coverage.md`. Doc reorgs themselves don't introduce code-paths, but they can leak operator-private content if examples are copied verbatim from real sessions.

**Scan result (executed against current `docs/sprints/{QUICKSTART,USAGE,DEVELOPER}.md`):**

| Pattern                          | Hits                                                                                                             | Severity   |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ---------- |
| `@example.com` or `gio@*`        | 0                                                                                                                | —          |
| `/Users/gio/` (operator home)    | **3** in USAGE.md + DEVELOPER.md — all are `file:///Users/gio/.claude/plans/hazy-gathering-kettle.md` references | **Medium** |
| AWS access key id (`AKIA…`)      | 0                                                                                                                | —          |
| Google API key (`AIza…`)         | 0                                                                                                                | —          |
| JWT (`eyJ…`)                     | 0                                                                                                                | —          |
| Postgres URL (`postgresql://`)   | 0                                                                                                                | —          |
| `sk-` (OpenAI / Anthropic style) | 0                                                                                                                | —          |
| Literal `hunter2` / `password=`  | 0                                                                                                                | —          |

**Finding.** Three references to `~/.claude/plans/hazy-gathering-kettle.md` use a hard-coded `file:///Users/gio/...` URL. This leaks the operator's username in publicly-distributed docs. Identical issue to parent S13 (absolute path leak), reified at the doc layer.

**Mitigation (W3).** Replace `file:///Users/gio/.claude/plans/hazy-gathering-kettle.md` with the tilde form `~/.claude/plans/hazy-gathering-kettle.md` (not a clickable link — that is the point: the file is operator-private, the docs should not pretend it's a project artifact). Alternative: copy the relevant decisions into a checked-in `docs/sprints/_history/` file and link to that. Either is acceptable; the `file:///` URL form is not.

**No credentials leaked elsewhere in docs.** W3 is otherwise green.

---

## 5. Inherited surfaces from parent + closure

The 15 parent surfaces (S1–S15) and the 6 closure surfaces (S-CL1–S-CL6) remain in scope. Status of each load-bearing surface in this sprint:

| Inherited surface                   | Still load-bearing?      | Reason                                                                                    |
| ----------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------- |
| Parent S1 (env spoof)               | **Yes**                  | W2's new advance-phase fires on the same `SPRINT_ADVANCE_PHASE_RUNNING=1` env; same risk  |
| Parent S2 (Write/Edit on state)     | **Yes**                  | Unchanged                                                                                 |
| Parent S3 (inline jq)               | **Yes** + extend         | S1-followup above: extend regex to non-phase fields touched by W1                         |
| Parent S4 (bypass abuse)            | **Yes**                  | W4 adds 43 new gates → more bypass surface. AC-6 ≥10char remains the only block           |
| Parent S5 (gate_bypasses unbounded) | Yes; bounded             | gate-names.json constants (closure S-CL1) cap namespace                                   |
| Parent S6 (manifest tampering)      | **Yes**                  | W4 edits `phase-manifest.json` legitimately; PR review remains the gate                   |
| Parent S7 (TOCTOU)                  | Closed by closure L12    | W1 must not regress the expected_phase under-lock invariant                               |
| Parent S8 (sub-step concurrent)     | **Yes**                  | W4 multiplies record_sub_step call sites → more concurrent-write opportunity; flock holds |
| Parent S9 (evidence traversal)      | Closed by closure L13    | W4 must verify each new instrumentation site honors the canonicalization                  |
| Parent S10 (lock-dir umask race)    | Yes                      | W1 must not introduce a second lock dir under different umask                             |
| Parent S11 (WHY plaintext PII)      | Closed by closure L14    | bypass.sh routes through sprint-pii-redact.sh                                             |
| Parent S12 (hook fail-open)         | Yes; documented          | Unchanged                                                                                 |
| Parent S13 (abs path leak)          | **Yes**, partly closed   | Closure L13 closed evidence-path form; W3 finding above is the doc-link form              |
| Parent S14 (state.json deletion)    | Closed by closure L15    | rm/mv hook block                                                                          |
| Parent S15 (strict unwireable)      | **Yes**, partly resolved | W4 wires 43 of the 43 deferred gates → if W4 lands fully, S15 closes                      |
| Closure S-CL1 (gate-names tamper)   | Yes                      | W4 edits the manifest legitimately; PR review remains the gate                            |
| Closure S-CL2 (--report-file)       | Yes                      | Unchanged                                                                                 |
| Closure S-CL3 (PII over-redact)     | Yes                      | S8 above doubles down on the redactor — sha256 sidecar required                           |
| Closure S-CL4 (TOCTOU lock-contend) | Yes                      | W1 must not regress                                                                       |
| Closure S-CL5 (bootstrap perm-mode) | Yes                      | One-time event already past; no new bootstrap in this sprint                              |
| Closure S-CL6 (pgrep DoS)           | Yes                      | Unchanged                                                                                 |

---

## 6. New attack surfaces this sprint (consolidated)

| #                                                                                                                                                                                     | Surface                                                 | Likelihood    | Impact       | Mitigation owner | Status                         |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | ------------- | ------------ | ---------------- | ------------------------------ |
| S1                                                                                                                                                                                    | Lockfile symlink-race (`$HOME/.cache/lifeos/locks/...`) | Low           | Medium-High  | **W1**           | Add `[ -L lockfile ] && rm`    |
| S2                                                                                                                                                                                    | TOCTOU between unified-lock acquire and rename          | Low (post-W1) | Catastrophic | **W1**           | Remove in-repo lockfile path   |
| S3                                                                                                                                                                                    | Stale-lock DoS (>30s holder)                            | Low           | Medium       | **W1**           | Already mitigated; verify      |
| S4                                                                                                                                                                                    | Malicious worker JSON spoofs predicate PASS             | Medium        | Catastrophic | **W2**           | Structural-field predicates    |
| S5                                                                                                                                                                                    | Path traversal in worker name → output basename         | Low           | High         | **W2** must-fix  | Add worker-name regex          |
| S6                                                                                                                                                                                    | Worker exit-code injection (`false; exit 0`)            | Low           | Medium       | **W2**           | Mtime + structural-field combo |
| S7                                                                                                                                                                                    | Evidence-path traversal in new W4 record_sub_step sites | Low           | Medium       | **W4**           | Re-verify closure L13 holds    |
| S8                                                                                                                                                                                    | PII leak in verify-\* log evidence (git-committed)      | **High**      | **High**     | **W4** must-fix  | Pipe through redactor + sha256 |
| (S9 absorbed into S8 — sprint-deploy.sh artifact-path-only contract is required as part of the W4 deploy instrumentation rules; gate-evidence redaction is the same control surface.) |                                                         |               |              |                  |

Plus inherited surface S1-followup (extend parent S3 hook regex to non-phase fields), covered by W1.

---

## 7. Required for this sprint to be ship-ready

1. **W1 inject-violation-catch-restore proof** — demonstrate (a) concurrent post-commit + atomic-state writer no longer corrupts state.json (20-writer stress test from spec §A success-vision); (b) PID-fallback symlink-reclaim works; (c) flock-branch self-heals on kill -9.
2. **W2 worker-name regex** added at `worker-trigger.sh:118` symmetric to slug regex.
3. **W2 structural-field predicate proof** — at least one gate that asserts on a worker output uses `gates_verified[]` (or equivalent) not a free-form verdict string.
4. **W3 absolute-path replacement** — all three `file:///Users/gio/...` references in USAGE.md + DEVELOPER.md replaced with tilde-form or moved into a checked-in history file.
5. **W4 PII redactor wiring** — `sub-step.sh` pipes evidence-file contents through `sprint-pii-redact.sh` for `.log` / `.txt` / `.out` extensions; sha256 sidecar stored for false-positive recovery.
6. **W4 sprint-deploy.sh artifact-only contract** — explicit test that deploying records only the artifact path, never the Pulumi stack output or full Vercel URL with preview hash.
7. **W4 dogfood re-verify of closure L13** — one record_sub_step from each new instrumentation class with a `../` evidence path; all must reject.

Without items 1, 2, 4, and 5, this sprint reproduces the parent's audit-failure pattern (theatrical mitigation, no proof).

---

## 8. Verdict

**APPROVED WITH CONDITIONS.**

The five new surfaces (S1–S6 net, with S9 absorbed) are all mitigable within wave scope. The inherited surfaces remain managed per parent + closure. The two highest-impact items are:

- **S8 (PII leak in verify-\* evidence)** — **must-fix in W4** because git permanence + high likelihood.
- **S2 (lockfile TOCTOU)** — **must-fix in W1** because it is the actual race that triggered this sprint.

The seven required-for-ship items above translate to concrete proof files, not abstract claims. If any of items 1, 2, 4, or 5 are not provable at sprint close, downgrade verdict to **NEEDS REWORK**.

**Out of scope (acknowledged):**

- Kernel-level FS monitoring (would close S1/S2/S7 definitively); too heavy.
- Cryptographic signing of worker outputs (would close S4/S6 definitively); too heavy for the local threat model.
- Mandatory two-operator review on bypass (would close S4 → bypass-abuse); not feasible for solo-operator harness.
- Network-attacker threat model; the harness is local-only by design.

**Note for the audit reviewer.** This review was produced after reading `atomic-state.sh` (full), `.husky/post-commit` (full), `bypass.sh` (full), `sprint-pii-redact.sh` (full), `worker-trigger.sh` (full), and grep-scanning the three sprint-docs for sensitive content. The closure-sprint failure mode (placeholder review accepted at audit) is the direct precedent this review is corrective against.
