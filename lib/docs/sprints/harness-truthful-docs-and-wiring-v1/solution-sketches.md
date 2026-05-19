# Solution sketches — harness-truthful-docs-and-wiring-v1

Three sketches for the 5-AC sprint that converts the harness from "passes because nobody made it earn its passes" to production-grade. The bar set by the closure-sprint audit failure (placeholder reviews) is non-negotiable: every sketch must produce concrete, falsifiable artifacts.

The 5 ACs to land:

- **AC-1** State.json race fix (.husky/post-commit + atomic-state.sh lockfile unification)
- **AC-2** Worker wiring (advance-phase fires the right daemon workers per phase)
- **AC-3** Docs reorg (QUICKSTART/USAGE/DEVELOPER de-contradicted + 2 new guides)
- **AC-4** 43-gate instrumentation (wizard 14 + spec-lock 4 + verify 21 + deploy 5 → record_sub_step at every call-site)
- **AC-5** Dogfood: this sprint produces ≥6 worker files / matches harness-parallel-safety-v2 footprint

---

## Sketch A — Linear waves W1→W5, individual gate proofs, wrap-into-advance-phase

The "by the book" plan. Each wave is a single commit with a single proof file. Workers wired by wrapping `sprint-advance-phase.sh` (the decision the plan locked).

**Order**

1. W1 (1d) — race fix. `.husky/post-commit:32` and `atomic-state.sh:71` both point to `$HOME/.cache/lifeos/locks/state-<slug>.lock`. Delete the in-tree `state.json.lock` path entirely. 20-writer stress test proof.
2. W2 (1d) — worker wiring. New `scripts/lib/phase-workers.json` maps phase → worker list. `sprint-advance-phase.sh` post-write reads the map and shells `worker-trigger.sh`. Daemon-down → record bypass + warn + continue.
3. W3 (1.5d) — docs reorg. Single source of truth for bypass syntax (`SPRINT_BYPASS_REASON=<text>`, kill `SPRINT_DRIFT_BYPASS=1`). New `_guides/bypass-cheatsheet.md` and `_guides/sub-step-coverage.md`. Heading slugs preserved.
4. W4 (3-4d) — 43 gates. **Each** of 43 call-sites gets a `record_sub_step` call AND an inject-violation-catch-restore proof in `W4-43-gates-wired.md`. ~12-16h.
5. W5 (1d) — dogfood. Run THIS sprint through the orchestration scripts; verify `worker-output/` ≥6 files / ≥6KB; diff against parallel-safety-v2 baseline.

**Wave-2 wiring (locked):** wrap into advance-phase. Single entry point = single trace. Daemon-down handled as a bypass entry with rationale.

**Wave-4 instrumentation:** 43 individual proofs. Maximally defensible — every gate provably catches a real violation. Matches the two-verdict policy literally (each AC is Production).

**Pros**

- Lowest risk of a regression slipping past — every gate has its own proof.
- Easiest to audit post-hoc: 43 proofs in one file map 1:1 to 43 manifest entries.
- W1 lands first → eliminates state.json corruption for the rest of the sprint's own commits (eats own dog food on day 1).

**Cons**

- W4 is the long pole and blocks W5. If W4 overruns (>16h), W5 dogfood gets compressed and the sprint risks landing without the proof that the sprint itself runs cleanly through the harness — same failure mode as the closure sprint.
- 43 inject-violation-catch-restore cycles is ~40-50 git operations during one wave; risk of fatigue corner-cutting (closure-sprint failure mode recurring).
- Serial — no parallelism extracted from the 3 independent surfaces (docs, race-fix, gates).

---

## Sketch B — Parallel triad (W1/W3 concurrent, W4 class-sampled), W2 wraps, W5 last

Exploits the fact that W1 (race fix in 2 files), W3 (docs reorg, no code), and W4 prep (audit + categorize 43 gates) touch disjoint paths. Run them as three worktrees / three sub-agents.

**Order**

- **Day 1-2 (parallel):**
  - Worktree A: W1 race fix + 20-writer stress harness.
  - Worktree B: W3 docs reorg + 2 new guides.
  - Worktree C: W4 audit — categorize 43 gates into 4 classes (wizard / spec-lock / verify / deploy), draft the sample matrix.
- **Day 3:** merge A+B+C onto sprint branch. W2 wiring lands next (depends on W1 lockfile path being final).
- **Day 4-6:** W4 implementation under class-sampled proof model.
- **Day 7:** W5 dogfood.

**Wave-2 wiring (locked):** wrap into advance-phase. Same as A — single entry point. The alternative (separate orchestrator + warn) was rejected because it duplicates the call surface that the closure sprint already proved operators bypass when invoking `sprint-advance-phase.sh` directly. Wrapping makes the wiring un-bypass-able by construction.

**Wave-4 instrumentation: class-sampled proof (~5 gates per category, 20 total).** Pick 5 representative gates per class (wizard / spec-lock / verify / deploy + 5 spares), produce full inject-violation-catch-restore for those, and a grep-coverage report for the remaining 23 confirming `record_sub_step` is wired at every call-site. Methodology mirrors §J risk mitigation language ("smoke per gate-class, not per-gate (sampling Production-grade methodology)").

**Pros**

- ~30-40% calendar compression: race-fix + docs land in parallel with W4 audit prep.
- Class-sampled proof drops W4 from ~14h to ~7h while still falsifiable (sampling is rigorous, not handwave). Frees 1 full day for W5 dogfood — direct mitigation of closure-sprint failure mode.
- W2 still wraps advance-phase → wiring stays single-entry-point + un-bypass-able.
- Three small worktrees reduce merge-conflict surface (disjoint files).

**Cons**

- Class-sampled proof is the audit-attack surface: if a reviewer rejects sampling, 23 gates have only grep-evidence and W4 has to be re-opened. §J authorized this path explicitly, but the closure sprint's audit failure was also placeholder-ish proof — must be careful that the 5 samples per class are genuinely inject-violation-catch-restore, not described-as-such.
- Three concurrent worktrees on one harness sprint risks the `.swarm/memory.db` and `state.json` race manifesting during this very sprint (until W1 lands). Mitigation: W1 lands at end of day 1, before C-thread's audit writes hit state.json.
- Slightly more orchestration overhead (3 sub-agents to coordinate).

---

## Sketch C — Reverse-order: W5 dogfood-stub first, then W1/W2/W4, W3 last

Land a minimal dogfood scaffold on day 1 — run the sprint through the broken harness immediately to surface every bug the closure sprint hid. Then fix in the order the dogfood revealed.

**Order**

1. **Day 1:** W5-stub — run THIS sprint's own phase transitions through `sprint-advance-phase.sh` (not direct invocation). Capture every failure: which workers don't fire, which gates aren't recorded, which state.json writes corrupt. Output: `W5-dogfood-failures.md` — a real defect inventory, not a hypothesis.
2. **Day 2:** W1 — race fix (almost certainly top of the defect inventory).
3. **Day 3-4:** W2 wrap into advance-phase. Now W5-stub iterations stop bypassing workers.
4. **Day 5-9:** W4 gate instrumentation in defect-priority order (start with the gates that fired bypasses in the dogfood, not in manifest order).
5. **Day 10:** W3 docs — written LAST because only by now does the author know which contradiction the docs are actually hiding.
6. **Day 11:** W5-full — second dogfood pass against the now-fixed harness. Must produce ≥6 worker files.

**Wave-2 wiring (locked):** wrap into advance-phase. The alternative — keep separate orchestrator + add a warn-on-direct-invoke shim — was rejected for two reasons. (a) `sprint-advance-phase.sh` is what operators (including this sprint's own ACs) call directly; a warn shim relies on the operator reading the warning, which the closure sprint proved they don't. (b) The harness-parallel-safety-v2 baseline of 22 invocations was achieved precisely because workers were invoked from a single point — preserving that single-point invariant is non-negotiable.

**Wave-4 instrumentation:** class-sampled proof (same as Sketch B) — 5 gates per category proven via inject-violation-catch-restore, remaining 23 via grep-coverage. Reverse order has no extra W4 budget vs B; same methodology.

**Pros**

- Dogfood-driven prioritization: the W4 gate-instrumentation order is set by which gates actually failed silently in the day-1 run, not by manifest ordering. Highest-signal first.
- Docs land last → they describe what the harness actually does, not what we hoped it would do. Eliminates the §A doc-contradiction class of failure at the source.
- Forces the closure-sprint failure mode (sparse worker output, corrupted state) to manifest on day 1 where it can be measured, not at end-of-sprint where it can be excused.

**Cons**

- Day 1's dogfood runs against a known-broken harness; state.json will corrupt during the very sprint. Recovery requires a side-channel JSON repair script — additional engineering surface.
- W3 last means LLM-readable docs don't exist mid-sprint when sub-agents need to read them. Sub-agents in this sprint have to read the spec + sketches directly (mitigated by this very file existing).
- Higher coordination cost: defect inventory must be re-prioritized 2-3 times as new failures surface. Adds 0.5-1d management overhead.
- Most novel of the three — least precedent in the repo's prior sprints.

---

## Recommendation: **Sketch B (parallel triad, wrap-into-advance-phase, class-sampled W4)**

**Pick Sketch B.** Three reasons in order of weight:

1. **It directly fixes the closure-sprint failure mode.** The closure sprint failed because W4-equivalent work overran and W5 dogfood got skipped or stubbed. Sketch B's class-sampled W4 buys back ~7h and parallelizes W1/W3 — that's roughly 1.5 days of slack that go directly into a real W5 dogfood, which is AC-5's success criterion (≥6 worker files matching parallel-safety-v2 baseline).
2. **Class-sampling is authorized by §J and is rigorous, not corner-cutting** — provided the 5 per class are full inject-violation-catch-restore. The two-verdict policy is satisfied because each _AC_ is Production; the 23 grep-covered gates ride under AC-4's evidence as supplementary coverage, not as the primary proof. This is the same methodology the audit accepted for harness-parallel-safety-v2.
3. **Wrap-into-advance-phase is the only Wave-2 choice that survives operator behavior.** The closure sprint demonstrated empirically that operators invoke `sprint-advance-phase.sh` directly; any wiring that depends on them invoking a separate orchestrator instead will be bypassed. Both A and B make this call; B preserves it without the calendar cost of A.

**Why not A:** the 43-individual-proofs model is more defensible on paper but in practice produces the corner-cutting fatigue that already burned the closure sprint. Defensibility is worthless if W5 doesn't run.

**Why not C:** dogfooding day-1 against a corrupting harness is intellectually clean but operationally expensive — the state.json repairs alone could eat the day-1 savings, and docs-last leaves mid-sprint sub-agents without the bypass cheatsheet they need (this sprint will run bypasses; they need documented syntax).

**Risk to watch in Sketch B:** the audit-attack on class-sampling. Mitigation: every one of the 20 sampled proofs must include the inject diff, the failing assertion output, AND the restore diff in `W4-43-gates-wired.md` — no prose-only entries. If a reviewer rejects sampling anyway, escalate to A's individual-proof model for the rejected class only (1 class = ~3-4h extra, recoverable inside the sprint).
