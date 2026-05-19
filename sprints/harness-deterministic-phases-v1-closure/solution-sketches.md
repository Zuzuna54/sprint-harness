# Solution Sketches — harness-deterministic-phases-v1-closure

> **Problem.** 53 leftover items from parent sprint span 6 distinct concerns: hook regex hardening, predicate engine extensions, evidence canonicalization, mirror execution, doc cleanup, and parent-sprint phase-walk. How to organize the build?

---

## Sketch 1 — One AC per leftover item (53 ACs)

Each L1-L53 becomes its own AC. §I has 53 entries. Per-AC commits.

### Pros

- **Maximum granularity**: every item gets an explicit proof file.
- Easy to track via task system (1 task ↔ 1 AC).
- If any L-item is rejected at architect review, only that AC pivots.

### Cons

- **AC inflation**: 53 ACs in §I is unmaintainable; spec.md would be ~500 lines just for §I.
- Wizard `--user-confirmed` per AC means 53 separate confirmations (in interactive mode).
- Replay validator's per-AC sub-step coverage check would explode.
- Dashboard hill-chart unreadable with 53 entries.

---

## Sketch 2 — One AC per "wave" (6 ACs)

Group items into 6 thematic waves (A-F per plan):

- AC-WaveA: ship-blockers (L1-L4)
- AC-WaveB: verification (L5-L11)
- AC-WaveC: polish (L12-L20)
- AC-WaveD: mirror+release (L25-L48)
- AC-WaveE: doc cleanup (L49-L53)
- AC-WaveF: parent sprint closure walk

Each AC has a list of L-items in its DoD. Per-item proof files but single AC closure.

### Pros

- **Readable spec**: §I fits one page.
- Dashboard usable.
- Per-wave commit batches preserve thematic coherence.
- Per-L-item proof files still required → maintains granularity where it matters.
- Matches the natural USAGE.md build-phase cadence: each wave is a build sub-cycle.

### Cons

- If 1 of 7 items in a wave is broken-with-followup, the whole wave can't be marked Production. Mitigation: per-L-item DoD bullets show partial verdict.
- Pair-mode auto-trigger fires on the whole wave even when only one L-item has a complex keyword. Acceptable: pair-mode is opt-in rigor.

---

## Sketch 3 — Two ACs per major area (12 ACs)

Split each wave into "implement" + "verify" ACs. AC-WaveA-impl + AC-WaveA-verify, etc.

### Pros

- Forces explicit verify-after-implement cadence.
- Each AC smaller and faster to close.

### Cons

- Doubles AC count without adding signal (verify steps already required by manifest).
- Implement+verify split is artificial for trivially-verifiable items (L18 schema field add).

---

## 6-dimensional comparison

| Dimension                                  | Sketch 1 (53 ACs)   | Sketch 2 (6 ACs) ✓ | Sketch 3 (12 ACs) |
| ------------------------------------------ | ------------------- | ------------------ | ----------------- |
| Spec readability                           | Poor                | Good               | Medium            |
| Per-item proof granularity                 | High                | High (via DoD)     | High              |
| Day-5 hill-chart usability                 | Terrible            | Good               | OK                |
| Pair-mode keyword trigger noise            | Per-AC (52 noisy)   | Per-wave (3 fire)  | Per-AC (8 fire)   |
| Commit batching naturalness                | Forces tiny commits | Per-wave commit    | Awkward mid-wave  |
| Replay-validator complexity                | High                | Low                | Medium            |
| Maps to USAGE.md "build sub-cycle" pattern | No                  | Yes                | Partially         |

---

## Decision: Sketch 2 (6 wave-mapped ACs)

Reasons:

1. **USAGE.md pattern**: build phase IS a sequence of sub-cycles. Mapping 1:1 to waves keeps the protocol observation legible.
2. **Per-L-item proof preserved**: DoD bullets reference proof files; closure of AC requires all DoD bullets satisfied.
3. **Operator UX**: 6 ACs in §I + 6 hill-chart entries is scannable in 30 seconds. Sketch 1 is unscannable; Sketch 3 has artificial split.
4. **Replay validator**: 6 sub-steps × phase < 12 × phase < 53 × phase. Cleaner audit trail.

---

## Rejected variants of Sketch 2

| Variant                                        | Why rejected                                                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------------- |
| 7 waves (split Wave A into bugs + Wave F walk) | Artificial — L4 phase-walk depends on L1+L3 fixes; can't parallelize            |
| 5 waves (merge Wave E into Wave D)             | Mirror work + doc cleanup are different concerns; merging hides doc-pass signal |
| Per-wave parent-sprint mini-sprint             | Recursion + meta-dogfood paradox; one closure sprint is enough                  |

---

## Open questions resolved during planning

- **Q1: Should each L-item have its own proof file or aggregate?**
  Answer: per-L-item proof file. Aggregating loses traceability. Pattern: `proof/L<N>-<short-name>.md`.

- **Q2: For Wave D mirror, should files be ported one-by-one with per-file commits or one bulk commit?**
  Answer: bulk commit via `scripts/sync-mirror.sh` (existing helper from harness-parallel-safety-v2 AC-9). Atomic mirror with brand-strip in one pass; single commit clearer than 24 file-by-file.

- **Q3: How to handle Wave F (parent sprint walk) — separate AC or absorb into Wave E?**
  Answer: separate (AC-WaveF). It's a distinct activity (operating on parent sprint, not closure sprint) and has its own success criterion (replay-validator passes for parent).

- **Q4: Do we need a sprint-checkin at Day 5 for a closure sprint with such concrete items?**
  Answer: yes, per USAGE.md to-the-teeth policy. Real cut/push/pivot answers even if the answer is "no cut, push all 6 waves, no pivot".

- **Q5: For Wave D L48 push to lifeos, who approves?**
  Answer: user `gio` explicit confirmation per org policy. Plan documents this; closure sprint will NOT push without it.
