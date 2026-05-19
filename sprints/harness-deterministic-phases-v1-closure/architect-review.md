# Architect Review — harness-deterministic-phases-v1-closure

> **Reviewer scope.** Evaluates the 6-wave AC structure + the new code/data introductions (gate-names.json, predicate engine extensions, hook regex extensions, evidence canonicalization) against the v0.7.0 architecture established by the parent sprint.

---

## 1. Wave dependency graph

```
                   ┌─────────────────────┐
                   │  Wave A: blockers   │  (L1-L4)
                   │  L1 hook smoke      │
                   │  L2 regex variants  │
                   │  L3 9-script audit  │
                   │  L4 parent walk     │
                   └──────────┬──────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼                              ▼
   ┌──────────────────────┐    ┌──────────────────────┐
   │  Wave B: verify       │    │  Wave C: polish       │
   │  L5-L11 (7 items)     │    │  L12-L20 (9 items)    │
   │                       │    │                       │
   │ Independent of C.     │    │ L12 + L13 + L14 + L15 │
   │ Smoke-tests only.     │    │ touch core primitives. │
   └──────────┬───────────┘    └──────────┬───────────┘
              │                            │
              └─────────────┬──────────────┘
                            ▼
              ┌──────────────────────────┐
              │  Wave D: mirror+release  │  (L25-L48)
              │  Depends on Waves A+B+C  │
              │  closed in lifeos.       │
              └──────────┬───────────────┘
                         │
                         ▼
              ┌──────────────────────────┐
              │  Wave E: doc cleanup     │  (L49-L53)
              │  Catches drift between   │
              │  v0.7 code + docs.       │
              └──────────┬───────────────┘
                         │
                         ▼
              ┌──────────────────────────┐
              │  Wave F: parent closure  │
              │  Uses Waves A+B fixes.   │
              └──────────────────────────┘
```

**Critical-path:** Wave A → Wave D → Wave F. Waves B + C + E run parallel-able after A.

---

## 2. New module boundary review

### 2.1 `scripts/lib/gate-names.json` (NEW — L17)

**Responsibility.** Source-of-truth list of valid gate names. Eliminates string-drift between manifest, USAGE.md "Phase enforcement" table, sub-step-coverage.md, and replay-validator regex.

**Interface.** Plain JSON: `{"version":"1.0.0","gates":["spec-lock-baseline-written",...]}`.

**Concerns:**

- ⚠️ **Sync point growth**. We already have manifest + USAGE.md + sub-step-coverage.md + validator regex. Adding gate-names.json makes 5. Mitigation: `validate-phase-manifest.mjs` extended to cross-check manifest gate names ⊆ gate-names.gates AND vice-versa. CI catches drift at PR time.
- ⚠️ **Bootstrap problem**. Gate-names.json must be authored before any of the 68 gate names exist anywhere else. v0.7.0 ships with all 68 gates declared in manifest; gate-names.json is generated FROM manifest then becomes source-of-truth going forward. Migration: validator runs in "permissive" mode for one minor release, then strict in v0.7.1.

**Decision.** Approved. Add a one-time migration command `node scripts/lib/validate-phase-manifest.mjs --bootstrap-gate-names` that generates initial constants file from current manifest.

### 2.2 Predicate engine extensions (L12 TOCTOU, L13 evidence canonical)

**L12 — TOCTOU-safe atomic write.**

Currently advance-phase reads `state.phase` at T0, runs predicates at T1, writes new phase at T2. Between T0 and T2 another process could advance.

**Mitigation.** Add `--arg expected_phase` to the atomic_update_state jq filter:

```jq
if .phase == $expected_phase
  then .prev_phase = $current | .phase = $next | ...
  else error("phase changed mid-advance: expected \($expected_phase), got \(.phase)")
end
```

**Concerns:**

- ✅ Works with existing flock (per-slug lock at write time).
- ⚠️ Error message ends up in stderr; advance-phase exits non-zero. Need to wrap in `|| { echo helpful; exit 1 }`.

**L13 — Evidence canonical.**

Reject absolute paths outside sprint dir + reject `..` traversal.

**Mitigation.** sub-step.sh::record_sub_step validates evidence at function entry:

```bash
if [[ "$evidence" == /* ]]; then
  evidence=$(realpath --relative-to="$REPO_ROOT" "$evidence" 2>/dev/null || echo "")
fi
if [[ "$evidence" == *".."* ]]; then
  echo "[FAIL] evidence path traversal rejected" >&2
  return 1
fi
```

**Concerns:**

- ⚠️ macOS `realpath --relative-to` may not exist (gnu-only). Fallback: pure bash trim or use `python3 -c`.
- ✅ Backward compat: existing entries with absolute paths are not re-validated; only new records.

### 2.3 Hook regex extensions (L2, L15)

**L2 — Broader jq variant coverage.**

Add pattern `\b(jq|python|python3|node|awk|gawk|perl|ruby)\b[^\n]{0,200}?(>|--in-place|-i)[^\n]{0,200}?docs/sprints/[^\s]+state\.json`.

**L15 — rm/mv block.**

Add pattern `\b(rm|mv)\b[^\n]{0,200}?docs/sprints/[^\s]+state\.json`.

**Concerns:**

- ⚠️ **False-positive risk**: legitimate cleanup scripts that `rm` test fixtures matching `state.json` glob in non-sprint dirs. Mitigation: regex anchors on `docs/sprints/...state.json` exactly.
- ✅ Combined with `SED_OR_REDIRECT_TO_STATE_JSON` and existing `JQ_PHASE_WRITE`, attack surface coverage approaches "everything that's not `atomic_update_state`".

### 2.4 Replay validator extensions (L19, L20)

**L19 — `--report-file <path>`** writes markdown report.

**L20 — Doc-vs-manifest false-positive audit.** Validator regex `^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)+$` matches every kebab-case backtick'd identifier in USAGE.md. Need exemption list for non-gate kebab-case strings (e.g., `spec-lock-baseline`, `pre-merge-review` if mentioned in prose).

**Concerns:**

- ✅ L19 is pure additive; no backward impact.
- ⚠️ L20: the right fix is either (a) restrict the doc-drift regex to a specific section (e.g., only the `## Phase enforcement` H2 block), or (b) add a `manifest.legacy_gate_names[]` allowlist.

**Architect decision.** Take option (a): only scan the `## Phase enforcement` section for kebab-case strings. Other sections may legitimately reference non-gate kebabs (drift-check, dup-check, pre-merge-review).

---

## 3. Failure-mode analysis (additive to parent sprint's)

| Failure                                                  | Detected by                          | Recovery                                                                                                      |
| -------------------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| L1 ppid check fails in real Claude Code flow             | L1 proof file shows hook self-blocks | Fallback to pgrep walk; revise proof file with mitigation                                                     |
| L4 parent sprint phase-walk hits unsatisfiable predicate | advance-phase exit 1                 | Bypass with SPRINT_BYPASS_GATE; add follow-up to instrument the sub-step in harness-verify-instrumentation-v1 |
| L10 onboarding-flow-v2 JSON unrepairable                 | jq empty fails after manual edit     | Quarantine as `.corrupt.json`; create empty replacement marked `phase=corrupted-quarantine`                   |
| L12 TOCTOU race actually happens during this sprint      | atomic_update_state exits with error | Re-run advance-phase from latest state; verify with --from                                                    |
| L17 gate-names.json drift                                | validator CI step fails at PR        | Run bootstrap command; commit regenerated file                                                                |
| L25-L43 sync-mirror.sh refuses overwrite                 | Mirror script exits non-zero         | Manual diff + selective overwrite; record in proof                                                            |
| L48 lifeos push attempted without approval               | Org policy + agent rules             | Block self; surface to user for explicit confirmation                                                         |

---

## 4. ADRs (this sprint)

### ADR-1: Wave-based AC grouping (not per-L-item)

6 ACs in §I, each owning a wave's L-items. DoD bullets per L-item. Rationale: scannability + commit cadence + USAGE.md mapping.

### ADR-2: Bootstrap gate-names.json from manifest

One-time migration: generate from current manifest, then validator strict mode in v0.7.1. Avoids the chicken-and-egg of authoring 68 names manually.

### ADR-3: Doc-drift regex scoped to "## Phase enforcement" only

USAGE.md has many kebab-case strings (drift-check, dup-check, pre-merge-review) that aren't manifest gates. Scope validator regex to just the phase-enforcement section.

### ADR-4: Per-L-item proof files at `proof/L<N>-<short-name>.md`

Not aggregated. Keeps audit trail traceable. Maintains parent sprint's convention.

### ADR-5: Wave D mirror via single bulk commit

`sync-mirror.sh` is the existing mirror tool. One commit per Wave D, not per-file. Aligns with parent sprint's mirror pattern (AC-9 of harness-parallel-safety-v2).

### ADR-6: Wave F resumes parent under closure-sprint's authority

Parent sprint paused; closure sprint advances it. The act of walking parent through final phases happens AS PART OF closure sprint's build phase (Wave F). Not a separate ceremony.

---

## 5. Approval with conditions

**APPROVED** subject to:

1. **L17 bootstrap migration** documented in DEVELOPER.md before validator goes strict.
2. **L20 regex scope** documented + tested with a real-world false-positive case.
3. **L48 push** requires explicit user `gio` confirmation in chat — agent must not self-approve.
4. **Wave F** documents EVERY bypass it issues against parent sprint (no silent bypasses).
5. **No corner-cutting** — every L-item has a real proof file, not a placeholder. The parent sprint's audit lesson is the explicit success criterion.

Without #5 above, this sprint repeats the parent's failure pattern and the meta-dogfood paradox returns.
