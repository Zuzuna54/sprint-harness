# Architect Review — harness-truthful-docs-and-wiring-v1

**Reviewer:** principal-architect agent
**Date:** 2026-05-19
**Verdict:** Approved with conditions (3 must hold by W5 close; see end).
**Scope reviewed:** spec.md §A/H/I/J, sprint-advance-phase.sh, lib/atomic-state.sh, lib/worker-trigger.sh, .husky/post-commit, phase-manifest.json (top + verifying phase + deferred_gates[]).

---

## Context

Three audits surfaced the same underlying issue: the harness _says_ it enforces 68 gates and serializes state writes, but in practice (1) 43 of 68 gates are uninstrumented declarations, (2) post-commit and atomic-state.sh use two different lockfile paths so they don't actually exclude each other, and (3) the closure sprint shipped without firing daemon workers because direct `sprint-advance-phase.sh` calls bypass the wrappers that fire them. This is theatre, not enforcement. The sprint converts the harness from "passes because nobody made it earn its passes" to a deterministic state machine where the gates that pass are real gates.

The intent is correct. The plan is also broadly correct. What follows is the architecture-level critique on each of the five waves, with concrete redirects where the current spec under-specifies the design.

---

## 1. Wave 1 — race fix: is shared-lockfile-via-source-atomic-state the right boundary?

**Decision being made:** `.husky/post-commit` will stop defining its own `atomic_state_update()` shell function (lines 32–54) and `STATE_LOCK="$STATE_FILE.lock"` (line 32), and will instead `source scripts/lib/atomic-state.sh` and call `atomic_update_state "$SLUG" '<filter>'`. This collapses two lockfile paths (`$STATE_FILE.lock` in-tree vs `$LOCK_DIR/state-<slug>.lock` under `$HOME/.cache/lifeos/locks/`) into one.

**This is the right boundary.** The lockfile path is the mutual-exclusion contract — same path = same critical section. Forking the implementation into a shell hook means the contract was _aspirational_, not enforced. Sourcing the library is the only way to keep one truth.

But there is a subtler question the spec does not address: **post-commit fires the reuse-audit detached (`nohup ... &` at line 187) while the pair-mode advisory runs synchronously.** The fix collapses lockfile paths but does not change the detachment topology. That topology has two implications:

1. **The detached audit runner re-implements lockfile logic inline** (line 156–166: `set -C; : > "$STATE_LOCK"`). After W1, the detached child must also source `atomic-state.sh`. Otherwise the race comes back through the back door — the parent is serialized, the child isn't. Spec §A mentions `atomic-state.sh:71 vs .husky/post-commit:32` but **does not call out line 157 inside the AUDIT_RUNNER heredoc**, which is a third lockfile path. _Fix scope:_ W1 must instrument the heredoc child too, not just the parent. If the heredoc subprocess cannot easily `source` a script (it runs under `env -i` for secret hygiene at line 181), then the heredoc needs to invoke a small `scripts/sprint-state-append.sh` wrapper that does the source itself.

2. **Detached `&` is correct here and should stay.** Synchronous would force `git commit` to block on jscpd (1-3GB, 30-120s). The right rule is: _commit-blocking work runs synchronously inline (pair-mode advisory, fast); long-running audits run detached_. Detachment is not the bug — the bug was that detachment and inline both _wrote state.json with different locks_. After W1, they write through the same lock; detachment becomes safe.

**Verdict W1:** Boundary is right. Add the heredoc-child fix to AC-1, otherwise the audit subprocess remains a third writer with its own lockfile.

---

## 2. Wave 2 — wrap-workers: coupling concern and per-phase vs per-(phase, worker-rigor)

**Decision being made:** `sprint-advance-phase.sh` will read `scripts/lib/phase-workers.json` and call `trigger_workers_parallel` for the entering phase. Today, advance-phase is a pure state mutator (lines 199–238 of advance-phase.sh: atomic_update_state + gate_history append). After W2, it becomes a state-mutator-plus-orchestrator.

### Coupling concern: ruflo daemon as hard dep

`worker-trigger.sh` has three failure surfaces that determine graceful-degrade behavior:

| Surface                        | Current behavior (worker-trigger.sh:96–154) | Graceful-degrade required                                                                                 |
| ------------------------------ | ------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `claude` CLI not installed     | return 2 (hard fail)                        | Skip + record bypass with rationale `claude-cli-missing`                                                  |
| CI=true + no ANTHROPIC_API_KEY | return 1 (hard fail)                        | Per Q8, hard-fail is correct in CI for _required_ workers; advisory workers should skip                   |
| Local + claude unauth'd        | return 1 + WARN                             | Already records "skipping" — make sure advance-phase treats this as bypass-with-rationale, NOT as failure |
| ruflo daemon won't start       | return 1 (hard fail)                        | Skip + record bypass `daemon-unavailable`                                                                 |
| sprint-pause-during-sprint     | n/a (no current code)                       | advance-phase to `paused` must NOT fire workers                                                           |

**The spec underspecifies this.** §J risks (2) says "graceful degrade (warn-and-continue when daemon down, recorded as bypass with rationale)" but doesn't distinguish:

- **Required workers** (e.g., `verify-worker-audit` is a required sub_step gate at phase=verifying in the manifest). Skipping these without bypass-rationale violates the gate.
- **Advisory workers** (e.g., `consolidate` post-checkin, no manifest gate). Skipping is silent.

**Fix scope for W2:** Add a `required: true|false` field to each entry in `phase-workers.json`. On daemon-unavailable:

- `required:true` → record bypass with `SPRINT_BYPASS_WHY=daemon-unavailable` so it shows up in `state.gate_bypasses[]` and the predeploy review can flag it
- `required:false` → silent skip + log to `state.worker_invocations[]` with `skipped:true`

### Per-phase vs per-(phase, worker-rigor)

The manifest already distinguishes `required_sub_step_gates[]` (always) from `strict_only_sub_step_gates[]` (gated on `state.worker_rigor == 'strict'`) — see verifying phase, lines 210–214. **The worker config MUST mirror this two-tier structure.** Otherwise we get a manifest that says "strict-only" for `verify-worker-map-refreshed` and a phase-workers.json that fires `map` unconditionally → drift between declared rigor and observed worker fires.

**Recommend:** `phase-workers.json` schema:

```json
{
  "verifying": {
    "always": [
      { "worker": "audit",    "required": true,  "timeout_s": 600 },
      { "worker": "testgaps", "required": true,  "timeout_s": 600 },
      { "worker": "optimize", "required": false, "timeout_s": 300 }
    ],
    "strict_only": [
      { "worker": "map",         "required": true, "timeout_s": 120 },
      { "worker": "consolidate", "required": true, "timeout_s": 120 }
    ]
  },
  ...
}
```

Per-(phase, worker-rigor). Not per-phase alone. Authority for the rigor flag is `state.worker_rigor`, set at spec-lock per existing manifest convention. This keeps one source of truth.

**Verdict W2:** Approved with the required/optional distinction and the strict_only tier added to phase-workers.json. Without these, the wave will produce a system that _says_ workers fired but cannot tell required-failed-but-bypassed apart from advisory-skipped.

---

## 3. Wave 3 — doc reorg: terminology contract

The audit's root finding was "docs are not LLM-readable because the same concept is described 3 different ways across 3 files." The fix is a terminology contract: **define ONCE, link from everywhere else.**

| Term                   | Definition                                                                                                                                                                                                                                                                                                               | Owning doc                                         | Cross-refs from                        |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------- | -------------------------------------- |
| **phase**              | A node in `phase-manifest.json:.phases`. 11 nodes total. Advance-only state machine, transitions in `advances_to[]`. Owns: required_artifacts, required_state_fields, required_sub_step_gates.                                                                                                                           | `docs/sprints/DEVELOPER.md` §Phase model           | USAGE, QUICKSTART, every script header |
| **sub-step gate**      | A named check inside a phase, recorded via `record_sub_step <slug> <gate-name>` in state.json under `.sub_steps[].gate`. Predicate engine validates phase-advance against `required_sub_step_gates[]`.                                                                                                                   | `docs/sprints/_guides/sub-step-coverage.md`        | DEVELOPER, USAGE                       |
| **worker**             | A ruflo daemon-invoked process. 11 types: audit, testgaps, optimize, map, consolidate, predict, document, ultralearn, refactor, deepdive, plus a few. Writes to `.claude-flow/metrics/<basename>.json`, copied to `docs/sprints/<slug>/worker-output/<worker>.json` by `worker-trigger.sh`. NOT the same as a sub-agent. | `docs/ruflo-sessions/ruflo-for-lifeos.md` §workers | DEVELOPER, USAGE                       |
| **sub-agent**          | A Claude Task-tool spawned process. Invoked synchronously from a parent Claude session via the Task tool. Uses parent's session quota. Used for: spec-lock 4-way review, predeploy reviewer, security-architect. NOT the same as a worker.                                                                               | `docs/sprints/DEVELOPER.md` §Sub-agents vs workers | USAGE, QUICKSTART                      |
| **autopilot side-car** | A non-blocking advisory layer. Examples: pair-mode stderr advisory in post-commit (line 76–86), drift-score warning. Suggests, never blocks.                                                                                                                                                                             | `docs/sprints/USAGE.md` §Autopilot side-cars       | DEVELOPER                              |

**Define-ONCE-and-link rule:** Each term is _defined_ exactly once. Every other mention is a markdown link to that anchor. CI gate: a `scripts/check-terminology.sh` script greps for the bold form of each term outside its owning doc and fails if a definition (matched by heading depth + colon) appears elsewhere. _This is a small addition to W3 the spec does not currently include — recommend adding it as AC-3.5._

The most failure-prone term is **worker** vs **sub-agent** (the audit explicitly says spec-lock 4-way review producer is ambiguous: "Claude vs Task agents"). Make this distinction loud:

> **Workers** are daemon-invoked, run async, don't consume Claude session tokens (they shell out to a separately-authed `claude --print`). **Sub-agents** are Task-tool-spawned, run synchronously, consume the parent's session quota. Spec-lock 4-way review uses **sub-agents** (Task tool, 4 parallel). Verify-phase analysis uses **workers** (ruflo daemon trigger).

**Verdict W3:** Approved. Add AC-3.5 (terminology lint) so the contract is enforced, not just documented.

---

## 4. Wave 4 — instrument all 43: record_sub_step at END only, or START+END?

The 43 deferred gates split into four classes:

- 14 wizard gates (`wizard-section-A`...`wizard-assemble`)
- 4 spec-lock gates (sketches, architect-review, security-review, hive-mind-consensus)
- 21 verify gates (typecheck, lint, tests, ..., worker-audit, worker-testgaps, worker-optimize)
- 5 deploy gates (pulumi-preview, human-gate, pulumi-up, smoke, vercel)

**Decision: record_sub_step at END (after success) only, OR at BOTH START (running marker) AND END?**

| Approach    | Pro                                                                                                                                                           | Con                                                                                                                                                                 |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| END only    | Simpler. State.json only records _true facts_ (the gate passed). Failure → no record → predicate fails → caller sees [FAIL] and acts.                         | A script that crashes mid-run is _indistinguishable_ from "never ran." Operator cannot tell "lint hadn't started yet" from "lint crashed at 80%." Forensics suffer. |
| START + END | State.json records `status: 'running' \| 'passed' \| 'failed'`. Crashed runs leave orphan `running` entries with a timestamp. Operator can detect stale runs. | Doubles state.json writes per gate. 43 gates × 2 = 86 writes per sprint (vs 43). Still small absolute volume. Requires schema change to `.sub_steps[].status`.      |

**Recommendation: hybrid — START+END for the 21 verify gates (long-running, can crash), END-only for the 18 wizard/spec-lock/deploy gates (short, atomic, crashes are obvious from missing files).**

Rationale: a verify-typecheck run takes 30-120s and a kill -9 during it is plausible (operator Ctrl-C, OOM, etc). A wizard-section-A gate is recorded the moment the wizard's section-A answer JSON is captured — there is no "during", it either happened or didn't.

For the 21 verify gates, schema addition:

```json
".sub_steps[] = { gate: string, at: ISO8601, status: 'running'|'passed'|'failed', evidence_path: string, elapsed_s: int }"
```

**Failure mode for a script crashing mid-run, with the hybrid:**

1. Script writes `status:'running'` at start via `record_sub_step --start <gate>`
2. Script crashes (kill -9, OOM, sigterm).
3. State.json shows `status:'running'` with timestamp T0.
4. Next sprint-advance-phase call: predicate engine sees `running` for a gate, treats it as **NOT PASSED** (same as missing) — refuses to advance.
5. Operator runs `sprint-status` and sees `1 gate stuck running (verify-typecheck, since T0)`.
6. Operator re-runs verify-typecheck; on success, `record_sub_step --end <gate> passed` overwrites the running entry.

Without START markers, step 5 is impossible — operator has no signal that something crashed vs never ran.

**Verdict W4:** Approved with the hybrid schema. The spec does not specify START/END semantics today and AC-4 is XL (12-16h) — adding 1-2h for the verify-gate schema change keeps the proof file honest.

---

## 5. Wave 5 — dogfood: is "≥6 worker files" the right success criterion?

The criterion as written in spec §A "≥6 worker files matching harness-parallel-safety-v2 baseline footprint" is **gameable**. Six no-op workers (e.g., 6 invocations of `consolidate` which is a free LOCAL worker per worker-trigger.sh:53 `_local_workers="map consolidate"`) would satisfy the count without exercising the audit/testgaps/optimize path that actually matters.

The real success criterion is **substantive worker output AT THE RIGHT PHASE TRANSITIONS**. Specifically:

1. **Worker diversity:** ≥4 distinct worker types fired (not 6 of the same). At least one each from: `audit`, `testgaps`, `optimize`, plus `map` or `consolidate`. Verifiable via `jq '.worker_invocations[].worker' state.json | sort -u | wc -l`.
2. **Worker-output payload size:** Total bytes in `worker-output/*` ≥ 20KB (the harness-parallel-safety-v2 baseline was 47KB, but 20KB is the floor below which workers produced trivially empty output). Verifiable via `du -sb docs/sprints/<slug>/worker-output/`.
3. **Worker→gate linkage:** For each required worker-gate (`verify-worker-audit`, `verify-worker-testgaps`, `verify-worker-optimize`), state.json's `.sub_steps[]` contains a `passed` entry with `evidence_path` pointing at the corresponding `worker-output/*.json`. Verifiable via a 5-line jq query.
4. **Worker invocation came from advance-phase, not a manual invocation:** `.worker_invocations[].by` field added to record caller. After W2, this should be `sprint-advance-phase.sh` for the verify-phase workers, NOT a human or a separate orchestrator.

**Anti-gaming check:** Add to W5 acceptance:

> The dogfood sprint must reach phase=done with: ≥4 distinct worker types, ≥20KB worker-output, each required worker-gate linked to its evidence file in `.sub_steps[]`, AND the closure sprint's gap (1 file / 123B) is provably not reachable from this configuration — demonstrated by a unit test that runs `sprint-advance-phase verifying` against a fresh sprint dir and asserts ≥3 worker invocations fired.

**Verdict W5:** Approved with the substantive criterion replacing the count-based one. As stated, "≥6 worker files" repeats the closure sprint's failure mode — passing the metric without earning the underlying property.

---

## ADRs (locked decisions)

### ADR-001: Single canonical lockfile for state.json mutation

**Decision:** All state.json writers (post-commit hook, atomic-state.sh, worker-trigger.sh, sprint-\*.sh family, and the reuse-audit heredoc subprocess) acquire the same `$LOCK_DIR/state-<slug>.lock` via `atomic_update_state`. The post-commit hook's inline `atomic_state_update()` function is deleted; the heredoc child either sources atomic-state.sh or calls a new `scripts/sprint-state-append.sh` wrapper.
**Status:** Accepted. Implements §A audit finding (2).
**Consequences:** Single critical section per slug. Cost: shell scripts must `source` a library (already standard in advance-phase.sh:40). Benefit: eliminates the orphan `}` / `gate_bypasses[]`-leaking-into-`reuse_audits[]` corruption observed during the closure sprint.

### ADR-002: phase-workers.json is per-(phase, worker-rigor) with required:bool

**Decision:** `phase-workers.json` schema has two tiers per phase (`always[]` and `strict_only[]`), mirroring the manifest's two-tier sub_step structure. Each worker entry has `required: bool`. Daemon-unavailable for `required:true` records a bypass with rationale; for `required:false` it's a silent skip recorded in `state.worker_invocations[]` with `skipped:true`.
**Status:** Accepted. Replaces spec's under-specified "graceful degrade" wording.
**Consequences:** Operators can pause-during-sprint, run in CI without OAuth, or run locally without `claude` installed and the system tells them what was actually verified. Cost: small schema; benefit: production-grade observability.

### ADR-003: Terminology contract — define-ONCE-and-link

**Decision:** Each of {phase, sub-step gate, worker, sub-agent, autopilot side-car} is defined in exactly one document (per the table in §3 above). All other mentions are markdown links. A CI gate (`check-terminology.sh`) fails if a definition (heading + colon pattern) appears outside its owning doc.
**Status:** Accepted. Adds AC-3.5 to W3.
**Consequences:** Doc drift becomes a CI failure, not a code-review judgement. Cost: 30 min to write the lint script. Benefit: the audit's root finding ("same concept described 3 different ways") becomes structurally impossible.

### ADR-004: Hybrid record_sub_step — START+END for verify gates, END-only for wizard/spec-lock/deploy

**Decision:** The 21 verify-* gates use a two-call pattern: `record_sub_step --start <gate>` at the top of each script, `record_sub_step --end <gate> {passed|failed}` at the bottom. State.json schema gains `.sub_steps[].status: 'running'|'passed'|'failed'`. The 18 wizard/spec-lock/deploy gates use END-only (single call after the artifact is produced).
**Status:** Accepted. Addresses crash-mid-run forensic gap.
**Consequences:** Stale `running` entries are visible signals of script crashes; without this, crashed runs are indistinguishable from never-ran. Cost: schema bump + ~21 scripts × 2 call-sites instead of 1. Benefit: when a sprint stalls, operators see *where\*.

### ADR-005: W5 dogfood success criterion is substantive, not count-based

**Decision:** "≥6 worker files" is replaced with a four-part predicate: ≥4 distinct worker types, ≥20KB worker-output, each required worker-gate linked to evidence in `.sub_steps[]`, and worker invocations attributed to `sprint-advance-phase.sh` (not manual). A unit test asserts `sprint-advance-phase verifying` against a fresh sprint dir triggers ≥3 worker invocations.
**Status:** Accepted. Replaces the gameable count criterion in §A success vision.
**Consequences:** The dogfood proves the wiring works end-to-end at the right transitions, not just that the worker-output directory has files. Cost: 1h to write the unit test. Benefit: the closure sprint's failure mode (1 file / 123B) is structurally non-reachable.

---

## Conditions for approval (must hold by W5 close)

1. **Lockfile unity proof.** Run a 20-writer concurrent stress test that simulates: 5 post-commit fires + 5 advance-phase calls + 5 worker-trigger updates + 5 sprint-checkin atomic_update_state calls, all racing on one slug. Acceptance: zero state.json parse errors, every write either succeeded or returned `[atomic-state] flock timeout` cleanly; no orphan `}` braces; no `gate_bypasses[]` entries leaking into `reuse_audits[]`. _If this fails, ADR-001 was not actually implemented — the heredoc subprocess is the most likely culprit._

2. **Worker-required vs advisory observability.** Simulate daemon-down during phase=verifying. Acceptance: `sprint-advance-phase pre-deploy` blocks with a clear `[FAIL] verify-worker-audit (required, daemon-unavailable)` message AND `state.gate_bypasses[]` is populated only after the operator explicitly runs `SPRINT_BYPASS_GATE=verify-worker-audit SPRINT_BYPASS_WHY='daemon-unavailable in CI' bash scripts/sprint-advance-phase.sh pre-deploy`. Advisory workers (e.g. `consolidate`) silent-skip. _If this fails, ADR-002's required/optional bit is wired incorrectly._

3. **Substantive dogfood, not theatre.** Run the dogfood sprint to phase=done. Acceptance: `du -sb docs/sprints/harness-truthful-docs-and-wiring-v1/worker-output/ ≥ 20480 bytes`; `jq '.worker_invocations | map(.worker) | unique | length' state.json ≥ 4`; for each of `verify-worker-audit`, `verify-worker-testgaps`, `verify-worker-optimize`, `jq '.sub_steps[] | select(.gate == "<gate>") | .status' state.json == "passed"`. _If this fails, ADR-005's criterion was not enforced and the closure sprint's failure mode is still reachable._

---

## Open questions (non-blocking)

- **Heredoc subprocess hygiene under `env -i`.** Post-commit line 181 strips env via `env -i` + allowlist before invoking the audit subprocess. Sourcing `atomic-state.sh` requires `BASH_SOURCE`/`PATH` to resolve `_atomic_state_dir`. Need to verify this still works under the env-stripped sub-shell, or accept the `scripts/sprint-state-append.sh` wrapper as the path of least resistance.
- **Bypass rationale taxonomy.** ADR-002 introduces `SPRINT_BYPASS_WHY=daemon-unavailable` as a structured value. Should there be an enum of accepted reasons (validated against a list in phase-manifest.json) or free-text? Recommend enum + free-text fallback so dashboards can categorize.
- **State.json size growth.** Hybrid START+END doubles writes for verify gates. Across a sprint, `state.sub_steps[]` could grow to 60-100 entries. Acceptable today; if state.json crosses 100KB, revisit with a rotation policy (move old entries to `state-history.jsonl`).
