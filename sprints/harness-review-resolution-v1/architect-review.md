# Architect Review — harness-review-resolution-v1

> **Reviewer:** principal architect (sprint design lock gate)
> **Spec:** [`spec.md`](./spec.md) (assembled 2026-05-19T19:09:56Z, wizard sections A/H/I/J)
> **Sketches:** [`solution-sketches.md`](./solution-sketches.md) — Sketch A (Superset) selected
> **Parent sprint:** `harness-audit-resolution-and-scope-v1` (closed 2026-05-19) — its 5 ADRs carry forward where load-bearing.
> **Verdict:** **APPROVED with 3 conditions** (see [§ Conditions for Approval](#conditions-for-approval))
> **Scope:** 7 ACs — generalize audit-resolution phase to handle 3 producers (audit + knip + sonar) under a unified review-resolution phase with back-compat aliasing.

This sprint applies the same triage discipline the prior sprint imposed on ruflo daemon audit findings to the next two finding lanes that are about to accrue legacy debt: knip dead-code and sonar quality. The trigger is empirical — the prior sprint surfaced 10 audit findings that all landed in `.claude/helpers/*.js` because no phase forced operators to look at them earlier; knip and sonar are on the same trajectory unless their findings get a Fix/Defer/Accept walk now. The 7 ACs are tightly scoped to one architectural change (multi-producer aggregation) plus the producer mode flags on the two existing parser scripts.

Five ADRs below capture the load-bearing decisions specific to multi-producer aggregation. The parent sprint's ADR-1 (dashboard visibility), ADR-2 (pure-state jq predicate), ADR-3 (atomic per-decision walker), ADR-4 (two-strikes rerun rule), and ADR-5 (versioned encryption envelope) all remain load-bearing; this sprint's ADRs extend them rather than supersede.

---

## ADR-001 — Unified `review_findings[]` schema vs producer-specific arrays

### Decision

State.json carries a single flat array `review_findings[]`. Each entry has a `producer` discriminator:

```json
{
  "producer": "audit" | "knip" | "sonar",
  "har_id": "HAR-1",
  "severity": "high" | "medium" | "low",
  "file": "apps/web/src/components/Foo.tsx",
  "line": 42,
  "description": "Unused export 'bar'",
  "status": "open" | "resolved" | "deferred" | "accepted",
  "decided_at": "2026-05-21T14:32:00Z",
  "rationale": "[REDACTED via sprint-pii-redact.sh]",
  "deferred_to_sprint": "harness-cleanup-v2",
  "ac_id": "AC-5"
}
```

### Alternative considered

Producer-specific arrays: `audit_findings[]`, `knip_findings[]`, `sonar_findings[]`. Predicate would sum across three.

### Rationale

The exit predicate arithmetic stays simpler with one array:

```
(.review_findings // []) | (
  ((map(select(.status=="open")) | length) == 0)
  and all(select(.status=="deferred"); .deferred_to_sprint != "" and .ac_id != "")
  and all(select(.status=="accepted"); .rationale | length >= 30)
)
```

One jq expression, one fixture set, one allowlist. Producer-specific arrays would require three nested sums plus careful jq escape — directly contradicting the parent sprint's ADR-2 ("evaluable purely from state.json via single jq expression"). The discriminator field also means a future eslint or depcruise producer is a one-line block addition in `scripts/lib/phase-manifest.json`, not a state-shape migration.

The producer field also makes the dashboard ADR-1 stacked bar render naturally: `group_by(.producer) | map({producer: .[0].producer, count: length})`.

---

## ADR-002 — `sprint-audit-resolve.sh` back-compat as thin alias

### Decision

`sprint-audit-resolve.sh` stays. It becomes a ~20 LOC shim that filters `review_findings[]` to `producer=="audit"` and delegates the walk to `sprint-review-resolve.sh --producer audit`. Same for `sprint-audit-rerun.sh` → `sprint-review-rerun.sh --producer audit`.

### Alternative considered

Delete the audit-_ scripts; force operators to learn the review-_ names. (Sketch B's approach in `solution-sketches.md`.)

### Rationale

Operators learned the audit-resolve flow exactly one sprint ago. Forcing a rename now resets that learning curve and signals "naming is unstable" — which discourages investment in operator-facing tools. The shim is cheap (one-time write, self-documenting), and the delegation path is one jq filter — there is no risk of the alias drifting from the canonical walker because the alias does not duplicate logic, only filters.

A side benefit: the alias's existence is itself the audit trail. When a future reader sees `sprint-audit-resolve.sh` is ~20 LOC and delegates, they immediately learn that the canonical walker is `sprint-review-resolve.sh`. Self-documenting indirection beats a deleted-script git-archaeology dig.

---

## ADR-003 — `worker-output/` becomes per-producer with independent baselines

### Decision

`worker-output/` gains per-producer JSON files:

```
docs/sprints/<slug>/worker-output/
├── audit.json                 (ruflo daemon audit worker, existing)
├── audit-baseline.json        (parent sprint ADR-4 baseline)
├── knip.json                  (NEW — sprint-deadcode-delete.mjs --json)
├── knip-baseline.json         (NEW)
├── sonar.json                 (NEW — sprint-sonar-parse.mjs --json)
└── sonar-baseline.json        (NEW)
```

Each producer's rerun touches only its own file. `sprint-review-rerun.sh --producer knip` fires `pnpm exec knip --reporter json > worker-output/knip.json` and diffs against `knip-baseline.json` for the targeted finding.

### Alternative considered

One flat `worker-output/findings.json` with all 3 producers' raw output merged.

### Rationale

Per-producer files are independently rerun-able. Knip reruns in ~1s, sonar in ~10s, audit (ruflo daemon) in ~30s. A merged file would force the slowest producer's latency on every rerun and tangle the parent sprint's two-strikes regression rule (ADR-4) across producer boundaries — knip's deterministic output would inherit audit's LLM-jitter false-positive handling, which is not warranted.

Each baseline file is captured at review-resolution phase entry. Rerun success is per-finding: `target HAR_id absent from producer output AND (deterministic producer: zero new findings; nondeterministic: two-strikes per parent ADR-4)`.

---

## ADR-004 — `har_id` namespace: global per-sprint, not per-producer

### Decision

`har_id` is a single sequence `HAR-1, HAR-2, …, HAR-N` across all producers within one sprint. Producer is a separate field. So:

```json
[
  { "har_id": "HAR-1", "producer": "audit", "file": ".claude/helpers/foo.js" },
  { "har_id": "HAR-2", "producer": "knip", "file": "apps/web/src/Bar.tsx" },
  { "har_id": "HAR-3", "producer": "sonar", "file": "apps/api/src/Baz.ts" },
  { "har_id": "HAR-4", "producer": "knip", "file": "apps/web/src/Qux.tsx" }
]
```

### Alternative considered

Producer-prefixed IDs: `audit:HAR-1`, `knip:HAR-1`, `sonar:HAR-1`. Each producer starts its own count.

### Rationale

A flat namespace makes operator references unambiguous. "Fix HAR-3" needs zero disambiguation; "Fix HAR-1" under the prefixed scheme would require asking "which HAR-1?". When an operator pastes "see HAR-4 in #incidents" into a deferral rationale, the reader does not need to look up which producer it came from.

The producer field is still available for filtering (`jq '.review_findings | map(select(.producer=="knip"))'`) and for the dashboard ADR-1 stacked bar.

This decision also closes the cross-producer collision attack surface (`security-review.md` S3) — there is no way for two findings to share a har_id, even across producers.

ID assignment happens at verifying phase entry, in producer order (audit first, then knip, then sonar), in source-file order within each producer. Deterministic; reproducible from raw producer output.

---

## ADR-005 — Phase name: `review-resolution`, not generic `resolution`

### Decision

The new phase is named `review-resolution`. The word "review" anchors the phase to its trigger condition (a review producer fired and found something), distinguishing it from a hypothetical future "deploy-resolution" or "rollback-resolution" phase.

### Alternative considered

Bare `resolution` — shorter, generic.

### Rationale

Phase names are operator-facing strings. They appear in `state.json::phase`, in `sprint-status.sh` output, in dashboard banner, in commit messages of phase transitions, and in every sprint doc going forward. A bare `resolution` would invite confusion about WHAT is being resolved. `review-resolution` reads correctly: "we're resolving findings the review producers surfaced."

The name also makes `audit-resolution` (parent sprint, now alias) a natural subtype. Future producers join the family by name: a hypothetical `lint-resolution` would feel out of place; `review-resolution(producer=lint)` is the canonical shape.

---

## ADR Summary Table

| ID      | Decision                                                                                  | Status                   |
| ------- | ----------------------------------------------------------------------------------------- | ------------------------ |
| ADR-001 | Single flat `review_findings[]` with `producer` discriminator                             | Required for AC-2        |
| ADR-002 | `sprint-audit-resolve.sh` stays as ~20 LOC alias filtering `producer==audit`              | Required for AC-3        |
| ADR-003 | `worker-output/{audit,knip,sonar}.json` per producer, each with its own baseline + rerun  | Required for AC-4 + AC-5 |
| ADR-004 | `har_id` globally sequential per sprint; `producer` separate field; no collision possible | Required for AC-2        |
| ADR-005 | Phase name `review-resolution`; `audit-resolution` remains valid (alias)                  | Required for AC-1        |

Parent sprint ADRs that carry forward as load-bearing:

| Parent ADR                                                  | Why it still binds                                                                             |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Parent ADR-1 (dashboard out-of-scope ratio)                 | Extended: stacked bar must now segment by producer (audit + knip + sonar).                     |
| Parent ADR-2 (pure-state jq predicate)                      | Required: new predicate `review_resolution_complete` is one jq expression over the new field.  |
| Parent ADR-3 (atomic per-decision walker, resume by har_id) | Required: review walker reuses the audit walker's atomic-write + resume primitives.            |
| Parent ADR-4 (two-strikes regression rule)                  | Required for audit producer only; knip + sonar are deterministic — single-rerun is sufficient. |
| Parent ADR-5 (encryption versioned envelope)                | Unchanged — no encryption changes in this sprint.                                              |

---

## Conditions for Approval

The sprint is approved subject to all three conditions holding at sprint-end. If any fails, sprint cannot close as Production.

### Condition 1 — Predicate `review_resolution_complete` is fixture-tested across all 3 producer combinations

Before AC-2 is marked Production:

- Fixture state files under `docs/sprints/_fixtures/review-resolution/`:
  1. Only audit findings, all resolved → PASS
  2. Mix of audit + knip + sonar, all decided (some resolved, some deferred, some accepted) → PASS
  3. One knip finding open → FAIL with named field
  4. One sonar finding deferred without `ac_id` → FAIL with named field
  5. One audit finding accepted with rationale < 30 chars → FAIL with named field
  6. Empty `review_findings[]` (vacuous case) → PASS
- The predicate jq expression is the single source of truth: same string in `phase-predicates.sh`, same string in the fixture test harness.

### Condition 2 — Back-compat alias `sprint-audit-resolve.sh` exercised against a live mixed-producer state

Before AC-3 ships as Production:

- A test fixture state with 2 audit findings + 2 knip findings + 2 sonar findings is run through `sprint-audit-resolve.sh`.
- Walker MUST iterate exactly the 2 audit findings; MUST NOT touch knip or sonar findings.
- After the alias walk completes, the same state run through `sprint-review-resolve.sh` MUST iterate exactly the remaining 4 (knip + sonar) findings.
- Combined coverage proves the alias filters correctly without dropping or double-counting findings.

### Condition 3 — Producer rerun independence proven in CI smoke

Before AC-4 + AC-5 land:

- Smoke test fires `sprint-review-rerun.sh --producer knip --har-id HAR-2` on a fixture sprint.
- Asserts: `worker-output/knip.json` was rewritten; `worker-output/audit.json` and `worker-output/sonar.json` are byte-identical to pre-rerun.
- Symmetric tests for `--producer audit` and `--producer sonar`.
- Producer-independence is a load-bearing claim of ADR-003; without this test, regression to a merged-file design is silent.

---

## Out of scope (deferred — explicit, named, with owner)

These are correctly excluded per `spec.md` §J:

- **ESLint findings producer** — already blocking via `verify-lint`; does not need a triage phase because zero-tolerance fail-on-error is the right policy for syntax/typo issues. Owner: keep blocking.
- **TypeScript findings producer** — already blocking via `verify-typecheck`; same rationale.
- **Task-sub-agent gates** (api-contract / debug-rls / module-status / aidefence) — these are presence/scope gates, not finding-producers. Separate appetite if they ever produce structured findings.
- **Strict mode (worker_rigor=strict) end-to-end smoke** — v0.7.2 polish; not blocked by this sprint.

---

## Open questions for design lock

1. Should `review_findings[]` carry a `producer_version` field (e.g., `knip@5.30.0`) so historical reruns can detect schema drift between producer releases? Recommendation: yes — single jq read, one-line manifest add. Decide at design lock.
2. When knip OR sonar emits zero findings, should the verifier still create an empty `knip.json` / `sonar.json` file for shape consistency? Recommendation: yes — predicate code stays simpler with files-always-present.
3. Should the dashboard ADR-1 stacked bar also surface **resolution latency per producer** (time-to-decide from finding-surfaced to status≠open)? Out of scope for this sprint; flag for observability sprint.

---

**Verdict reaffirmed: APPROVED with 3 conditions.** Proceed to design lock once conditions are scheduled into the AC fixture list.
