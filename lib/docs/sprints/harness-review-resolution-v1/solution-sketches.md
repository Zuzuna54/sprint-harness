# Solution Sketches — harness-review-resolution-v1

> **Purpose:** evaluate three architectures for generalizing the audit-resolution phase (v0.7.2) into a multi-producer review-resolution phase that triages findings from audit + knip + sonar under one operator workflow.
> **Constraint:** must preserve the replay-validator's view of prior 11 sprints' state.json (none of which know the word "review-resolution").
> **Constraint:** must preserve operator muscle memory for `sprint-audit-resolve.sh` / `sprint-audit-rerun.sh`.
> **Recommended:** **Sketch A — Superset**. Rationale + scoring at bottom.

---

## Sketch A — Superset (review-resolution is NEW phase; audit-resolution becomes alias) — RECOMMENDED

### Shape

- `audit-resolution` remains a valid phase name (replay-validator allowlist keeps it forever).
- `review-resolution` is added as a new phase block in `scripts/lib/phase-manifest.json`. Same `advances_to=[pre-deploy, paused]`, same `required_state_fields=[review_findings_total present]`.
- `review_findings[]` is a single flat array in state.json:
  ```json
  { "producer": "audit" | "knip" | "sonar",
    "har_id": "HAR-1", "severity": "high",
    "file": "...", "line": 42, "description": "...",
    "status": "open" | "resolved" | "deferred" | "accepted",
    "decided_at": "...", "rationale": "...",
    "deferred_to_sprint": "...", "ac_id": "..." }
  ```
- New script `sprint-review-resolve.sh` walks `review_findings[]` regardless of producer; same Fix/Defer/Accept loop the audit walker pioneered.
- New script `sprint-review-rerun.sh` dispatches per-finding rerun to producer-specific verifier (audit → ruflo daemon; knip → `pnpm knip --json`; sonar → `sprint-sonar-parse.mjs --json`).
- `sprint-audit-resolve.sh` STAYS as a thin alias that pre-filters `review_findings[]` to `producer==audit` and delegates the rest to `sprint-review-resolve.sh`. Operators who type the audit command keep working.
- Exit predicate `review_resolution_complete` (extends the existing `audit_resolution_complete` shape):
  ```
  count(open) == 0 across all producers
  AND every status==deferred has deferred_to_sprint != "" and ac_id != ""
  AND every status==accepted has acceptance_rationale | length >= 30
  ```
- Worker-output layout: `worker-output/audit.json` + `worker-output/knip.json` + `worker-output/sonar.json`, each with its own baseline sidecar.

### Wins

- **Zero replay break.** Every prior sprint's `state.json` still validates (phase=audit-resolution is still legal). Reading 11 historical state files in CI smoke test stays green.
- **Operator muscle memory preserved.** Typing `sprint-audit-resolve.sh` still works on day 1 of the new sprint — no retraining cost.
- **One walker, one predicate.** Operator-facing surface area shrinks even though producer count grows 3x.
- **Producer rerun independence.** Knip rerun (~1s) does not need to touch ruflo daemon (~30s) or sonar (~10s); each can fire alone.
- **State shape is forward-compatible.** Adding a 4th producer later (e.g., eslint, depcruise, semgrep) is a phase-manifest entry + a producer block, no schema migration.

### Costs

- Two phase names that both exist. Documentation must explain the alias relationship; some operators may be confused which to call.
- `sprint-audit-resolve.sh` becomes a thin shim — duplicates a small surface (arg parsing, banner) but the body delegates.

### Risk

- Low. The aliasing layer is read-only at the resolution path (it filters; it does not write through a different path). Worst case: someone writes a new producer and forgets to wire it into the alias filter — finding shows in review-resolve but not audit-resolve. That is a feature, not a bug, for the dedicated alias.

---

## Sketch B — Clean break (rename audit-resolution → review-resolution; migration script for prior sprints)

### Shape

- `audit-resolution` is removed from `phase-manifest.json`. Renamed to `review-resolution` everywhere — script names, phase names, predicate name, state fields (`audit_findings_*` → `review_findings_*`).
- One-shot migration script (`scripts/sprint-state-migrate-v0.7.3.mjs`) walks every `docs/sprints/*/state.json`, rewrites phase strings, and renames fields. Run once at sprint start.
- Replay validator accepts only `review-resolution`; prior `audit-resolution` strings are migrated.
- `sprint-audit-resolve.sh` deleted; operators must learn `sprint-review-resolve.sh`.

### Wins

- One name, one walker, one predicate, zero duplication. The codebase reads cleanly to a future contributor with no historical baggage.
- No alias maintenance burden.
- Producer field becomes a first-class concept everywhere instead of bolted on.

### Costs

- **Replay-validator regression on prior sprints.** Every closed sprint's `state.json` carries `phase: "audit-resolution"` at the moment it transitioned through it. The migration script must rewrite history — and any prior sprint that has been git-tagged or referenced externally now reads differently than its tag.
- **Muscle memory shock.** Operators who learned the audit-resolve flow yesterday must relearn today. This is exactly the kind of churn that desensitizes operators.
- **Migration is a new failure mode.** A botched migration script (off-by-one in jq path, missed `phase-history[]`, dropped a sub-step gate name) silently corrupts all 11 prior sprint states. Even with --dry-run, the recovery story is "restore from git" — operationally heavy.
- **One-shot scripts go stale.** `sprint-state-migrate-v0.7.3.mjs` will be deleted by the dead-code gate within two sprints, leaving no audit trail of what changed.

### Risk

- Medium-high. The replay validator break is the dominant risk; it weakens the "every prior sprint replays clean" CI invariant the harness depends on.

---

## Sketch C — Producer-per-phase (separate knip-resolution + sonar-resolution phases parallel to audit-resolution)

### Shape

- `phase-manifest.json` gains TWO new phases alongside `audit-resolution`:
  - `knip-resolution` (after audit-resolution, before pre-deploy)
  - `sonar-resolution` (after knip-resolution, before pre-deploy)
- Three walker scripts: `sprint-audit-resolve.sh` (existing), `sprint-knip-resolve.sh` (new), `sprint-sonar-resolve.sh` (new).
- Three exit predicates: `audit_resolution_complete`, `knip_resolution_complete`, `sonar_resolution_complete`. Each is a clone of the audit predicate with field-name swap.
- Three baseline files, three rerun scripts, three state-field families (`audit_findings_*`, `knip_findings_*`, `sonar_findings_*`).

### Wins

- Producer separation is structural — no producer field needed in findings; the phase IS the producer.
- Each producer's predicate is independently testable in fixture isolation without cross-producer interference.

### Costs

- **Phase count grows from 11 → 13.** Every new phase is a 7-file ripple (`phase-manifest.json`, schema, advance-phase, predicates, sprint-end, replay-validator, docs). Three new phases = 21 file edits, not counting the new walker scripts.
- **Operator does three walks per sprint.** Even when zero knip findings exist, the phase must transition. That's three banner screens + three "no findings, advancing" prompts. Operators will start `SPRINT_BYPASS_GATE`-ing the empty ones.
- **Drift surface tripled.** Three predicate files to keep in sync, three walker scripts to keep in sync, three rerun scripts. The next refactor (e.g., adding rationale length check) is 3x the diff.
- **State shape stays fragmented.** `audit_findings_total` + `knip_findings_total` + `sonar_findings_total` are three counters where one would do. Dashboards (ADR-1 stacked bar) must read all three.

### Risk

- Medium. The phase-count explosion is the main concern; it taxes every operator interaction with the harness, not just the resolution phase.

---

## Scoring matrix

| Dimension                    | Sketch A | Sketch B | Sketch C |
| ---------------------------- | -------- | -------- | -------- |
| Replay validator safety      | ++       | --       | +        |
| Operator muscle memory cost  | 0        | --       | -        |
| Code surface (LOC + scripts) | +        | 0        | --       |
| New-producer ergonomics      | ++       | +        | --       |
| Predicate-test isolation     | +        | +        | ++       |
| Migration risk               | 0        | --       | 0        |
| Schema evolution flexibility | ++       | 0        | -        |
| Total (heuristic)            | **+8**   | **-3**   | **-2**   |

---

## Recommendation: **Sketch A**.

The decisive factors are (1) zero replay break on the 11 historical sprints, (2) preserved operator muscle memory, and (3) the producer field is a clean schema-level discriminator that makes future producers (eslint, depcruise) a 1-block manifest add rather than a 7-file ripple. Sketch B's clean break is theoretically prettier but the migration is a foot-cannon. Sketch C's structural separation is over-engineered for a 3-producer use case and triples the drift surface for marginal predicate-test clarity.

The aliasing cost in Sketch A is small and self-documenting: the alias script is ~20 LOC that delegates, and the docs make the alias relationship explicit. We trade a small amount of script duplication for a large amount of historical-state stability.
