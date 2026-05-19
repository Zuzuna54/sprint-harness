# Architect Review — harness-deterministic-phases-v1

> **Reviewer scope.** This review evaluates the proposed system from spec §B (entities + invariants) and §D (API surface) against existing harness primitives. Focus: module boundaries, contracts, failure modes, integration with parallel-safety-v2, and known integration risks.

---

## 1. Module boundary review

Three new modules + one extended hook. Each must own a single responsibility; cross-module coupling must go through stable interfaces.

### 1.1 `scripts/lib/phase-manifest.json` (data layer)

**Responsibility.** Sole declarative source-of-truth for per-phase requirements: artifacts, state-fields, sub-step gate names, allowed transitions.

**Interface contract.**

- READ-ONLY at runtime. Mutations require a PR + replay-validator re-run (AC-13d gate enforces this).
- Schema validation runs at every `sprint-advance-phase.sh` invocation (~50ms overhead).
- `version` field uses semver; v0.7.x schema MAY add predicate kinds + gate names but MUST NOT remove. v0.8.0 reserved for breaking changes (e.g., removing `gates[]` dual-write).

**Boundary concerns:**

- ✅ Pure data — no logic, no I/O.
- ✅ Independently testable (validate-phase-manifest.mjs runs against it).
- ⚠️ **Risk:** manifest gate names are referenced by string in 5 places (predicates.sh, sub-step.sh, replay-validator.mjs, USAGE.md "Phase enforcement" table, sub-step-coverage.md). Refactor cost of renaming a gate is high. Mitigation: AC-13d drift gate. Long-term: extract gate-name constants to a separate file (`gate-names.json`) and inline-include in manifest. **Deferred to v0.7.1.**

### 1.2 `scripts/lib/phase-predicates.sh` (engine layer)

**Responsibility.** Read manifest. Evaluate predicates against sprint dir + state.json. Return 0/1 with `[FAIL]` lines per failure.

**Interface contract.**

- `check_phase_requirements <slug> <phase> → 0|1` (public).
- `sub_step_recorded <slug> <gate> → 0|1` (public; reused by replay validator).
- All predicate evaluators are `_pp_*` prefixed (private convention).
- Reads `state.json` via `jq`; uses `atomic-state.sh::_pp_state_file` for path resolution.

**Boundary concerns:**

- ✅ No state mutation — pure read.
- ⚠️ **Bash 3.2 compat surface.** macOS default bash. Empty arrays under `set -u` require `${arr[@]+"${arr[@]}"}` guard. `${var,,}` not supported (use `tr 'A-Z' 'a-z'`). Lessons from parallel-safety-v2 apply here.
- ⚠️ **`set -uo pipefail` + `grep -v` matching-nothing silent-exit hazard.** Caught in AC-11 day-5 validate. Engine code must use `|| true` after grep -v when empty result is acceptable.
- ⚠️ **PS4-from-parent-env leakage.** If parent shell has `set -x` set, predicate evaluator output gets garbled with trace lines. Mitigation: run engine inside `bash -c 'set +x; ...'` subshells when called from non-bash parent.
- ✅ Testable in isolation (call against a fixture state.json).

### 1.3 `scripts/sprint-advance-phase.sh` (mutator layer)

**Responsibility.** The only sanctioned path to `state.phase = X`. Resolves slug, loads manifest, runs engine, optionally writes bypass records, atomically advances phase + appends gate_history.

**Interface contract.**

- `sprint-advance-phase.sh <next-phase> [--from <expected>]` (CLI).
- Exports `SPRINT_ADVANCE_PHASE_RUNNING=1` to subprocess env for PreToolUse hook recognition.
- Reads `SPRINT_BYPASS_GATE` + `SPRINT_BYPASS_WHY` (comma-separated multi-gate).
- Writes via `atomic-state.sh::atomic_update_state` (parallel-safe per v0.5.0).
- On success: state.phase advanced, gate_history[] appended with `by="sprint-advance-phase.sh"`.

**Boundary concerns:**

- ⚠️ **Bypass-before-validate order bug.** Bypass records are written BEFORE manifest-name validation. A typo `SPRINT_BYPASS_GATE=desgin-locked` silently records a meaningless bypass for a non-existent gate. **Architect requirement: validate bypass gate names against manifest before recording.** Tracked as follow-up T2.1. [REGRADE: AC-4 → Broken-with-followup.]
- ✅ Idempotent on same-phase target (exits 0 if `current == next`).
- ✅ Atomic via flock.
- ⚠️ **`design_locked_at` / `predeploy_at` / `closed_at` timestamps set INSIDE the mutator.** Couples mutator to per-phase domain knowledge. Acceptable for v0.7 (3 timestamps), but if more accumulate, refactor to manifest-driven specialization. Deferred to v0.7.1.

### 1.4 `scripts/lib/sub-step.sh` (instrumentation layer)

**Responsibility.** `record_sub_step <slug> <gate> <verdict> [evidence] → 0|1`. Atomic, idempotent on `(slug, gate)`.

**Interface contract.**

- Dual-writes to `state.gates_passed[]` (canonical v0.7+) AND `state.gates[]` (legacy compat).
- Upgrades legacy bare-string entries to object form on first re-record.
- Verdict ∈ {pass, fail, bypassed}.

**Boundary concerns:**

- ✅ Single primitive; no per-gate variance.
- ⚠️ **Idempotency assumes string equality on gate name.** Whitespace-different names create separate entries. Caller responsibility: gate names are validated by manifest schema (`^[a-zA-Z0-9][a-zA-Z0-9-]+$`).
- ⚠️ **No gate-name validation at record time.** A caller passing `record_sub_step my-sprint typo-gate` silently records an entry not in manifest. Replay validator catches it (AC-13c) at PR time, not at record time. **Architect requirement: optional gate-name validation against manifest in `record_sub_step` (warn, don't block).** Deferred to v0.7.1.

### 1.5 `scripts/lib/bypass.sh` (escape-hatch layer)

**Responsibility.** Validate `SPRINT_BYPASS_GATE` + `SPRINT_BYPASS_WHY`, record to `state.gate_bypasses[]`. Provide deprecation shim for legacy `SPRINT_*_BYPASS=1` envs.

**Interface contract.**

- `check_bypass <gate> → 0|1` (0 = bypass accepted + recorded; 1 = no bypass for this gate, or bypass malformed).
- `deprecate_legacy_bypass <env-var> <new-gate>` — auto-synthesizes new envs from legacy ones; logs deprecation warning.

**Boundary concerns:**

- ⚠️ **`SLUG` env must be set by caller.** Not validated at function-entry boundary. Documented at function header but not enforced. Acceptable for v0.7 since all callers are sprint-\* scripts that resolve slug first.
- ⚠️ **`gate_bypasses[]` is unbounded.** No retention policy. Operator running 50 bypassed sprints accumulates 250+ entries in state.json files. **Architect requirement: velocity script flags >3 bypasses/sprint as "high-bypass"; deeper analytics in v0.8.**
- ⚠️ **`SPRINT_BYPASS_WHY` plaintext stored in state.json (committed to git).** Operators MUST NOT include secrets/PII in the rationale. Documented in bypass-cheatsheet.md.

### 1.6 `.claude/helpers/sprint-hook.cjs` (PreToolUse extensions)

**Responsibility.** Block (a) `jq … .phase = …` outside canonical mutator; (b) Write/Edit on state.json.

**Interface contract.**

- Receives JSON-stdin per Claude Code PreToolUse contract.
- Exit 0 = allow tool call; exit 2 = block + show stderr to operator.

**Boundary concerns:**

- ⚠️ **`parentIsAdvancePhase()` ppid check race.** Between hook's `ps` call and the actual subprocess exec, the parent could fork — though unlikely in practice. **Architect note: this is best-effort, not cryptographically secure. The threat model is the model accidentally writing inline jq, not a malicious actor.**
- ⚠️ **Hook only fires under Claude Code.** Operator running `bash scripts/whatever.sh` outside Claude Code has no PreToolUse enforcement. The chokepoint only applies during model-driven workflows. Documented in spec §J.
- ✅ Hook fail-open on parse error (returns allow). Prevents harness from soft-locking when input is malformed.

---

## 2. Cross-module contract diagram

```
                                ┌──────────────────────────┐
                                │  phase-manifest.json     │
                                │  (READ-ONLY data)        │
                                └──────────────────────────┘
                                       ▲              ▲
                                       │              │
                                       │              │
              ┌────────────────────────┘              └─────────────────────┐
              │                                                              │
              │                                                              │
┌─────────────┴──────────────┐                              ┌────────────────┴─────────────┐
│  phase-predicates.sh       │                              │ sprint-replay-validator.mjs  │
│  (read predicates,         │                              │ (read predicates + walk      │
│   evaluate against fs)     │                              │  closed sprints' state)      │
└─────────────┬──────────────┘                              └──────────────────────────────┘
              │
              │
              ▼
┌─────────────────────────────────────┐
│  sprint-advance-phase.sh            │
│  Reads predicates;                  │
│  writes via atomic_update_state     │
│  → state.phase + gate_history       │
└─────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐    ┌──────────────────────────────────┐
│  state.json (per-slug,              │←───│  sub-step.sh::record_sub_step    │
│  atomic-state.sh writes only)       │    │  (called from 15+ instrumentation │
└─────────────────────────────────────┘    │   sites; writes to gates_passed)  │
              ▲                            └──────────────────────────────────┘
              │
              │     ┌────────────────────────────────────────────────────────┐
              │     │  bypass.sh::check_bypass (writes to gate_bypasses)     │
              └─────┤                                                        │
                    │  Called from sprint-advance-phase.sh + sub-step.sh    │
                    └────────────────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────────────────────┐
   │  sprint-hook.cjs (PreToolUse)                                       │
   │                                                                     │
   │  BLOCKS:                                                            │
   │   - Bash regex /jq … \.phase = …/  unless parentIsAdvancePhase()    │
   │   - Write/Edit on docs/sprints/*/state.json (always)                │
   │  ALLOWS:                                                            │
   │   - sprint-advance-phase.sh (verified via ps -o command= -p $PPID)  │
   └─────────────────────────────────────────────────────────────────────┘
```

**Reuse from parallel-safety-v2 (v0.5.0):**

- `atomic-state.sh::atomic_update_state` (variadic `--arg` forwarding to jq) — every write goes through it.
- `session-file.sh::get_session_slug` — slug resolution chain v2 (no mtime fallback).
- `lock-dir.sh::$LOCK_DIR` — XDG-runtime-dir-anchored lock directory.

All three are foundation primitives; this sprint adds 5 new modules ON TOP without touching them.

---

## 3. Failure-mode analysis

| Failure                                                  | Detected by                    | Caller behavior                                                         | Recovery                                                |
| -------------------------------------------------------- | ------------------------------ | ----------------------------------------------------------------------- | ------------------------------------------------------- |
| Manifest corrupt JSON                                    | `validate-phase-manifest.mjs`  | advance-phase exits 1 with `[FAIL] manifest parse`                      | Fix JSON; re-run                                        |
| Manifest schema violation (bad gate name)                | validator                      | exit 1 with `[FAIL] gate name "X" invalid`                              | Fix manifest                                            |
| Predicate fails + no bypass                              | engine                         | exit 1 with `[FAIL] <predicate>: <reason>`                              | Fix artifact OR set bypass envs                         |
| Atomic write fails (flock timeout, fs full)              | atomic-state.sh                | advance-phase exits 1                                                   | Retry; state.json untouched                             |
| state.json missing                                       | atomic-state.sh                | exit 1 with `state.json not found`                                      | `recover_state_from_bak` (v0.5.0)                       |
| state.json corrupt (concurrent crash)                    | atomic-state.sh                | jq parse fails                                                          | `recover_state_from_bak`                                |
| Operator typo in `SPRINT_BYPASS_GATE`                    | **NOT DETECTED** (bug)         | Silently records meaningless bypass; predicate still fails on real gate | Manual cleanup of state.gate_bypasses[]                 |
| Wizard rename of gate without manifest update            | replay-validator AC-13c        | CI fails at PR                                                          | Fix manifest OR rename back                             |
| Hook misfires on legitimate non-phase jq                 | Hook regex                     | Hook may block (false positive)                                         | Add specificity to regex; SPRINT_BYPASS_GATE if needed  |
| Parent process not advance-phase (real Claude Code flow) | Hook                           | **UNVERIFIED — see §1.6**                                               | T2 follow-up: smoke against real Claude Code            |
| `worker_rigor` field missing from state                  | spec-locked manifest predicate | advance-phase refuses → spec-lock                                       | Run wizard §J5 OR set state.worker_rigor='lax' manually |

---

## 4. Integration with existing harness

### 4.1 Coexistence with v0.5.0 parallel-safety

- ✅ Uses `atomic_update_state` for every write. No new state-write paths.
- ✅ Uses `session-file.sh` for slug resolution; respects `SPRINT_SLUG_OVERRIDE` precedence.
- ✅ Hook addition (jq+phase + state.json edit) is additive to existing forbidden-action regex. Doesn't override `SPRINT_DRIFT_BYPASS=1` paths.

### 4.2 Coexistence with v0.6.0 workers-on-demand

- ✅ Worker outputs (`worker-output/<worker>.json`) become required artifacts at verify phase. Workers are gated by their existing on-demand triggers.
- ✅ `worker_rigor` flag controls which worker outputs are required predicates vs advisory.
- ⚠️ **Integration concern:** when `worker_rigor=strict`, advance-phase from `verifying → pre-deploy` requires `verify-worker-map-refreshed` + `verify-worker-consolidate-refreshed`. These are recorded by `sprint-verify.sh` AFTER worker outputs land. If worker times out (10-min limit per v0.6.0), the sub-step is unrecorded → predicate fails. Mitigation: operator bypass with rationale = "worker timed out, see worker-output/<worker>.log".

### 4.3 Coexistence with husky hooks

- ✅ Pre-commit drift-check + duplication-block fire independently of phase manifest. Their `state.gate_bypasses[]` records under different gate names (`drift-check`, `dup-check`).
- ⚠️ **`SPRINT_DRIFT_BYPASS=1` legacy env auto-shims** to `SPRINT_BYPASS_GATE=drift-check SPRINT_BYPASS_WHY=legacy-shim-…`. Deprecation warning fires. Acceptable for v0.7.x; remove in v0.8.

### 4.4 Coexistence with CI workflows

- ✅ `.github/workflows/test.yml` gains 2 new steps (validate-phase-manifest + replay-gate-history). Both are fast (~100ms each on fresh checkout). No external dependencies.
- ⚠️ **Replay validator's `--ignore-pre <date>` default** is set to v0.7.0 release date. Operators upgrading to v0.7.0 mid-sprint will have one closed sprint that doesn't meet the new contract. Mitigation: implicit "pre-v0.7" skip if `gate_history` has no `.by="sprint-advance-phase.sh"` entry.

---

## 5. Architect decisions (ADR-style)

### ADR-1: Manifest is data, not code

We chose a JSON manifest over a TypeScript/JS module exporting predicates because:

- Replay validator + USAGE.md doc generator + IDE schema validation all consume the same source.
- jq-readable from bash without spawning Node.
- Diffable in PRs; visible in operator-facing docs.

### ADR-2: Single canonical mutator (sprint-advance-phase.sh) is non-negotiable

The PreToolUse hook chokepoint only works if there's ONE allowed writer. If we permitted, e.g., `sprint-end.sh` to also write phase, the hook regex would need to allow both → bigger attack surface. Sprint-end delegates instead.

### ADR-3: `gates_passed[]` + `gates[]` dual-write for one minor-version cycle

Pre-v0.7 closed sprints have entries in `gates[]` as bare strings. We can't break them. Dual-write + union-read for v0.7.x; remove `gates[]` write in v0.8.0 with deprecation announcement in v0.7.0 CHANGELOG.

### ADR-4: Bypass record happens BEFORE predicate check, NOT after

(REJECTED — this is the v0.7.0 implementation choice and it's buggy.)

In code today: advance-phase records the bypass first, then runs predicates which see the bypass record and count the predicate as `[BYPASS]`. **Bug:** typo'd gate names record meaningless bypasses for non-existent gates.

**Architect requirement for T2.1:** validate `SPRINT_BYPASS_GATE` against manifest gate names BEFORE recording. Reject unknown names with a clear error.

### ADR-5: Worker rigor is binary (lax/strict), not per-worker

Per-worker overrides (`worker_rigor: {audit: strict, optimize: advisory}`) add complexity for no clear use case in v0.7.0. Operators choose one knob. Defer per-worker to v0.8 if real demand surfaces.

---

## 6. Approval with conditions

**APPROVED** subject to the following follow-ups:

1. **T2.1 (REQUIRED before v0.7.0 ship):** Fix AC-4 bypass-pre-validation bug. Typo'd gate names must be rejected.
2. **T2.2 (REQUIRED before v0.7.0 ship):** Fix AC-10 worker_rigor write-time. `sprint-spec-wizard.mjs` must write state.worker_rigor at §J5 answer-time, not rely on amend-spec.
3. **T2.5 (REQUIRED before v0.7.0 ship):** Smoke-test AC-5 hook in real Claude Code invocation (not synthetic stdin).
4. **T4 (architectural follow-up, can ship as separate sprint):** Address AC-8 sub-step instrumentation gap. Either split manifest into "v0.7.0 enforced" + "deferred follow-up" sets so operators don't need 50+ bypasses, OR instrument the missing 53 sites in `harness-verify-instrumentation-v1`.
5. **v0.7.1 polish:** gate-name validation at `record_sub_step` boundary; gate-name constants extracted to separate file.

Without 1+2+3 above, this is a Broken-with-followup-AC release. With them, Production.
