# Solution Sketches — harness-deterministic-phases-v1

> **Problem (recap from spec §A):** 8 mechanical phase gates exist today; the other ~32 documented USAGE.md steps are prose-only. The model can skip sub-steps under token pressure and the sprint still closes with `phase=done`.

This document compares **3 candidate designs** for converting prose-only steps into mechanical predicates. Each is evaluated on 6 dimensions. Chosen design is at the end with rationale.

---

## Sketch 1 — Inline assertions in every phase-writer script

Every `sprint-*.sh` script that today writes `state.phase` would gain its own predicate-check block before writing. Each script's predicates live in its own bash body; no external manifest. Operators bypass via the existing per-script env (`SPRINT_DESIGN_LOCK_BYPASS=1`, etc).

```bash
# In sprint-design-lock.sh
[ -f docs/sprints/$SLUG/solution-sketches.md ] || { echo "[FAIL] solution-sketches.md missing"; exit 1; }
[ -f docs/sprints/$SLUG/architect-review.md ] || { echo "[FAIL] architect-review.md missing"; exit 1; }
# ... 4 more checks ...
atomic_update_state "$SLUG" '.phase = "design-locked"'
```

### Pros

- Smallest diff: ~5 lines per script.
- No new dependencies, no new manifest format to maintain.
- Each script owns its own contract — readable in isolation.
- Existing `SPRINT_*_BYPASS=1` envs keep working unchanged.

### Cons

- **Predicate duplication.** Same `[ -f spec.md ]` check appears in 3-4 scripts. Drift risk: one script adds a new predicate, others don't.
- **No declarative source of truth.** The "what must hold for each phase" knowledge is scattered across 9 bash scripts. Documenting it requires walking every script.
- **PreToolUse hook still has nothing to block.** The model can still write `jq '.phase = X' state.json` directly and bypass every script. No mechanical chokepoint.
- **Replay validator becomes harder.** A CI tool that walks closed sprints and asserts protocol completeness needs to know "what phase X required" — but that knowledge is in code, not data. Validator has to be hand-coded with one branch per phase.
- **Operator bypass UX stays bad.** 7+ different `SPRINT_*_BYPASS=1` envs, no centralized audit trail.

---

## Sketch 2 — JSON-schema runtime (ajv) + state.json schema validation

State.json gains an inline JSON schema. Every state write is validated against the schema. Phase transitions encoded as a state-machine schema constraint (e.g., `oneOf: [{ phase: "spec-locked", required: ["solution_sketches"] }, ...]`).

Toolchain: `ajv-cli` (npm dep) runs every state write through schema validation. CI runs `ajv validate` on every closed sprint's `state.json`.

### Pros

- Single schema file is unambiguous source of truth.
- Existing tooling (`ajv`, IDE JSON-schema integration, online validators).
- State.json gets typed in a way humans can read.

### Cons

- **Heavy dependency for a tiny schema.** `ajv` + `ajv-formats` + `ajv-cli` adds ~5MB to install size for a 100-line schema. The harness ships as `@ordex/sprint-harness` — every npm install pulls ajv even though 95% of operators won't customize the schema.
- **JSON Schema's expressiveness is wrong for our case.** We need: "for phase=spec-locked, file at `docs/sprints/<slug>/solution-sketches.md` exists AND has ≥200 bytes". JSON Schema can express "field exists" but not "this path on disk exists at this size" — those are runtime predicates, not data validation.
- **Bypass model has to be bolted on.** JSON Schema has no native "this constraint is bypassable with a rationale" concept. We'd build our own bypass layer on top, which defeats the "use standard tooling" benefit.
- **PreToolUse hook still has nothing concrete to block.** Same problem as Sketch 1 — schema validation is post-hoc.
- **CI integration is awkward.** `ajv validate state.json schema.json` doesn't actually walk the per-phase progression; it just validates the final state object shape.

---

## Sketch 3 — Single canonical mutator + declarative manifest + PreToolUse chokepoint (CHOSEN)

One artifact (`phase-manifest.json`) declares per-phase required artifacts/state-fields/sub-step gates. One script (`sprint-advance-phase.sh`) is the only sanctioned writer of `state.phase`; it loads the manifest, runs a predicate engine, refuses to advance if predicates fail (unless a single audited bypass env is set). PreToolUse hook blocks every other path to `state.phase` mutation — inline `jq`, direct `Edit` on state.json, etc.

```
phase-manifest.json (data) ─→ phase-predicates.sh (engine) ─→ sprint-advance-phase.sh (mutator)
                                                                       ↑
                                                                       │ ONLY caller
                                                              sprint-hook.cjs blocks
                                                              every other path
```

### Pros

- **Single declarative source of truth.** The manifest IS the spec. Operators, replay validators, doc generators, and CI all read the same file. Doc-vs-manifest drift gate (AC-13d) catches USAGE.md ↔ manifest divergence.
- **PreToolUse hook has something concrete to block.** Inline `jq '.phase = …'` is mechanically rejected. The env-spoof attack is defeated by checking the parent process via `ps -o command= -p $PPID`. No prose enforcement.
- **One bypass interface.** `SPRINT_BYPASS_GATE=<name>` + `SPRINT_BYPASS_WHY=<reason ≥10 chars>` is one path. Every bypass is audited to `state.gate_bypasses[]` with caller attribution. Velocity script flags >3 bypasses/sprint as "high-bypass".
- **Replay validator becomes a 235-line script.** Walks manifest, walks `state.gate_history`, asserts every `required_sub_step_gates[]` per walked phase is in `gates_passed[]` ∪ `gate_bypasses[]`. Generic — no per-phase hand-coding.
- **No new heavy deps.** Manifest is plain JSON; structural validator is 130 lines of Node, no ajv. Predicate engine is bash + jq (already required for atomic-state.sh).
- **Migration path.** 9 existing phase-writer scripts each replace their inline `.phase = X` write with `bash sprint-advance-phase.sh X`. Pre-existing artifact validation in each script stays — new validation comes from the manifest.
- **Legacy `SPRINT_*_BYPASS=1` envs degrade gracefully.** Deprecation shim auto-synthesizes new bypass envs for v0.7.x compat. Removal v0.8.0.

### Cons

- **Manifest can drift from reality.** If a wizard section gets renamed and the manifest doesn't update, advance-phase refuses. Mitigation: doc-vs-manifest drift validator (AC-13d) catches it at PR time.
- **`record_sub_step` has to be wired into every instrumentation site.** 68 named gates → 68 sites. Realistically v0.7.0 ships ~15 instrumented; the rest deferred to follow-up sprints. **This is the biggest known gap.** Mitigation in v0.7.0: explicitly document in `_guides/sub-step-coverage.md` which gates are wired vs deferred. Operators see the gap and either bypass or contribute instrumentation.
- **Predicate engine in bash is fragile.** jq filter strings + bash arrays + macOS bash 3.2 compat (no `${var,,}`, `${arr[@]+"${arr[@]}"}` empty guard) means careful coding. Mitigation: integration test via dogfood — this sprint is built USING the engine, and surfaced real bash 3.2 gotchas during its own construction.
- **Bypass abuse risk.** Operators could SPRINT_BYPASS_GATE everything. Mitigation: bypasses are audit-logged, surfaced in dashboard.html + retro.md, velocity flags >3 as "high-bypass" trend signal.

---

## 6-dimensional comparison

| Dimension                                        | Sketch 1 (inline)      | Sketch 2 (ajv)               | Sketch 3 (manifest + mutator) ✓          |
| ------------------------------------------------ | ---------------------- | ---------------------------- | ---------------------------------------- |
| **Code duplication risk**                        | High (9 scripts)       | Low (1 schema)               | Low (1 manifest)                         |
| **Declarative source of truth**                  | No (scattered in code) | Yes (schema)                 | Yes (manifest JSON)                      |
| **Can PreToolUse hook block bypass?**            | No                     | No                           | **Yes** — jq+phase regex match           |
| **CI replay validator complexity**               | ~500 lines hand-coded  | ~200 lines (ajv-driven)      | ~235 lines (manifest-driven)             |
| **Bypass audit trail**                           | 7 envs, no log         | None native                  | 1 env pair, logged                       |
| **Heavy npm deps added**                         | None                   | ajv + ajv-formats + ajv-cli  | None (Node stdlib only)                  |
| **Operator migration effort (existing sprints)** | 0 changes              | Schema-versioning required   | Pre-v0.7 sprints skip via `--ignore-pre` |
| **Predicate expressiveness for "file ≥N bytes"** | Bash one-liner         | Custom JSON Schema extension | Native predicate kind                    |
| **Doc-vs-manifest drift gate**                   | N/A                    | Hard (no doc tie-in)         | Yes (AC-13d)                             |

---

## Decision: Sketch 3

Reasons (in priority order):

1. **PreToolUse hook chokepoint** is the only design that mechanically prevents the model from writing `state.phase` outside the canonical mutator. Sketches 1+2 leave this attack surface open.
2. **Doc-vs-manifest drift gate** is only possible when there IS a single manifest. Sketches 1+2 leave the prose↔code link unenforced.
3. **Single bypass UX** (`SPRINT_BYPASS_GATE` + `SPRINT_BYPASS_WHY`) is auditable; Sketch 1's 7 envs sprawl is what we're trying to clean up.
4. **No heavy npm deps** — important because the harness ships as a package and operators install it into their own repos.

Known risk accepted: 53 of 68 sub-step gates instrumented as `record_sub_step` deferred to follow-up sprint. Documented in `_guides/sub-step-coverage.md`. Operators on v0.7.0 will need to bypass those until a follow-up `harness-verify-instrumentation-v1` sprint wires them.

---

## Rejected variants of Sketch 3

| Variant                                                               | Why rejected                                                                                                     |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Manifest in YAML instead of JSON**                                  | YAML adds a parser dep + indentation-error surface. JSON parses with `jq` (already required).                    |
| **Predicates in TypeScript instead of bash**                          | Predicate engine called from many bash scripts; TS would require Node spawn on every check. Bash + jq is direct. |
| **Per-sprint manifest override (custom predicates per sprint)**       | Adds complexity; almost no use case. Defer to v0.8 if real demand surfaces.                                      |
| **Bypass requires GitHub PR review instead of env var**               | Too heavy for operator escape valve. Audit trail in `state.gate_bypasses[]` + retro surfacing is sufficient.     |
| **Phase advance is a multi-step transaction (begin/commit/rollback)** | Overengineering. Single atomic write via `atomic_update_state` is sufficient for parallel-safe.                  |

---

## Open questions resolved during build

- **Q1: How to defeat env-spoof on `SPRINT_ADVANCE_PHASE_RUNNING=1`?**
  Answer: hook also checks `ps -o command= -p $PPID`. Belt + suspenders. (Implemented AC-5.)

- **Q2: Should bypasses be limited to N per sprint?**
  Answer: No hard cap; velocity script flags >3 as "high-bypass" trend metric. Hard caps would force operators to lie about reasons.

- **Q3: Should the manifest be writable from `spec.md` for per-sprint overrides?**
  Answer: No in v0.7.0. Defer to v0.8 if real demand. (Out of scope per spec §J.)

- **Q4: How does `worker_rigor` change the manifest evaluation?**
  Answer: `state.worker_rigor=strict` adds `strict_only_sub_step_gates[]` to the required set per phase. `lax` (default) skips them. Operator-controlled via wizard §J5.

- **Q5: What about closed pre-v0.7 sprints?**
  Answer: Replay validator's `--ignore-pre <date>` flag (default 2026-05-19) skips them. Implicit skip if `gate_history` has no `.by="sprint-advance-phase.sh"` entry + no `worker_rigor` field.
