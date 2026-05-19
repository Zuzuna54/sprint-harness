# Solution sketches — harness-audit-resolution-and-scope-v1

Three sketches for the 19-AC combined sprint that lands (a) scope-bounded verify workers, (b) a real `audit-resolution` phase between `verifying` and `pre-deploy`, (c) the 10 HAR vulnerability fixes in `.claude/helpers/*.js`, and (d) Wave-4 doc + v0.7.2 polish (G1/G2/G3).

Every sketch must produce concrete, falsifiable artifacts. The closure-sprint precedent (placeholder reviews, skipped dogfood) is the failure mode we are explicitly designing around — the just-closed `harness-truthful-docs-and-wiring-v1` dogfood confirmed it by surfacing 10 pre-existing audit findings with 100% noise ratio, which this sprint exists to fix.

The 19 ACs split across 4 waves:

- **Wave 1 — Scope-bounding** (AC-1..AC-4): `gate_audit_blocks` learns `<slug>` + spec.md §H scope filter; `gate_optimize_scope_filter` advisory; `sprint-verify.sh` passes SLUG; `phase-workers.json` extended with `{scope, scope_mode}` per worker, default `repo/none`.
- **Wave 2 — Audit-resolution phase** (AC-5..AC-8): new `audit-resolution` phase in `phase-manifest.json` with exit predicate `resolved + deferred + accepted == total AND every deferred has slug+ac_id`; new `sprint-audit-resolve.sh` (~350 LOC) interactive walker; new `sprint-audit-rerun.sh` (~200 LOC) diff-vs-baseline; new `_templates/audit-resolutions.md`.
- **Wave 3 — HAR fixes** (AC-9..AC-18): HAR-1..HAR-10 with `aes-256-gcm` + `scryptSync` from Node built-in `crypto` (ZERO new npm deps per locked decision), one AC per vuln, each shipping a vitest test file.
- **Wave 4 — Docs + v0.7.2 polish + dogfood** (AC-19 + G1/G2/G3): 4-doc updates (USAGE/QUICKSTART/DEVELOPER/SCRIPTS), `phase_manifest_version_seen` replay back-compat, `sprint-status.sh` resolution priority reorder, post-commit Edit-tool lockfile.

---

## Sketch A — Linear waves W1 → W2 → W3 → W4 (LOCKED choice)

Strict sequential — each wave is a self-contained block of commits with its own proof file, no wave starts until the previous wave's proof file is green. This is the locked ordering per the plan because Wave 1 (scope-bounding) is a prerequisite for Wave 2's dogfood (audit-resolution-phase) to converge, and Wave 2's infrastructure is a prerequisite for Wave 3's per-HAR audit-rerun assertions to mean anything.

**Order**

1. **Days 1-3 — Wave 1 (scope-bounding).** AC-1 + AC-2 + AC-3 + AC-4 commit-by-commit. Land `gate_audit_blocks(slug)` and `gate_optimize_scope_filter`; pass `$SLUG` from `sprint-verify.sh`; extend `phase-workers.json` schema with optional `{scope, scope_mode}` (default `repo/none`). Wave proof: re-run audit against current sprint's `worker-output/` — with `scope=files-touched`, vulnerabilities[] reduces to in-scope-only. Test against W1 stress fixture (inject an in-scope vuln + an out-of-scope vuln; verify in-scope blocks, out-of-scope is advisory only).
2. **Days 4-6 — Wave 2 (audit-resolution phase).** AC-5 adds new phase block to `phase-manifest.json` between `verifying` + `pre-deploy` with required artifacts (`audit-resolutions.md` ≥1KB) + state fields (`audit_findings_total`, `..._resolved_count`, `..._deferred[]`, `..._accepted[]`) + exit predicate. AC-6 + AC-7 ship `sprint-audit-resolve.sh` (interactive walker, Fix/Defer/Accept per finding, atomic-state-writes on every decision) and `sprint-audit-rerun.sh` (re-fire audit worker, diff vs baseline, exit 0/1). AC-8 formalizes `_templates/audit-resolutions.md`. Wave proof: synthetic-finding smoke (inject a vuln into the fixture, walk resolve.sh, confirm decision recorded + atomic-state-write + resume-from-quit works).
3. **Days 7-11 — Wave 3 (HAR fixes).** AC-9..AC-18, one HAR vuln per AC, in severity order (HAR-1..HAR-4 high first, then HAR-5..HAR-10 medium/low). Each AC commits with the inject-violation-catch-restore pattern: pre-fix audit-rerun records the finding; fix; post-fix audit-rerun confirms finding gone + no new vulns. Per-AC test file under `.claude/helpers/__tests__/` covers (a) fix actually fixes vuln, (b) regression test for failure mode. Wave proof: per-AC audit.json diff + final audit-rerun shows 0 vulns in the 4 touched files.
4. **Days 12-14 — Wave 4 (docs + polish + dogfood).** AC-19 updates USAGE/QUICKSTART/DEVELOPER/SCRIPTS in one combined commit per doc. G1 adds `phase_manifest_version_seen` to replay validator. G2 reorders `sprint-status.sh` priority (git-branch first, session-file fallback). G3 adds `.claude/state/edit-tool.lock` check to `.husky/post-commit` with 30s stale-lock reclaim. Day 14 dogfood: walk THIS sprint through `sprint-advance-phase.sh` (not direct invocation); day-11 verify fires audit (scope-bounded → expect ≤1 in-scope finding); day-11/12 audit-resolution-phase walks any findings.

**Wave-2 scope-bound implementation (LOCKED choice (a) post-filter at gate):** `gate_audit_blocks(slug)` parses `spec.md` §H at evaluation time and post-filters `.vulnerabilities[]` by `.file in scope`. This mirrors the canonical `gate_testgaps_blocks` pattern that already lives in `worker-gates.sh:70-85`. Worker scans the whole repo; gate filters at evaluation. No daemon changes; no env vars to plumb through; matches the existing well-tested code-path.

**Wave-3 HAR test infrastructure (LOCKED choice (b) NEW `.claude/helpers/__tests__/` with vitest config):** A dedicated test directory with its own `vitest.config.cjs` so HAR fixes ship with executable proofs runnable by `pnpm test` without polluting the apps/ or packages/ test trees. Test files use the `.test.cjs` extension to match the `.cjs` helper files. Each test exercises the encrypted-load/save round-trip (HAR-2/HAR-4), the allowlist gate (HAR-5), the path validation (HAR-6), the UUID source (HAR-3), etc.

**Pros**

- **Convergence guarantee.** Wave 1 lands first → Wave 2's own audit run during this sprint sees only in-scope findings (which there are zero of for harness scripts), so the audit-resolution-phase smoke can be against synthetic fixtures rather than fighting noise. Without Wave 1 first, Wave 2's dogfood would re-surface the same 10 HAR-1..10 findings the prior sprint already triaged.
- **Per-wave commits enable surgical rollback** (per §J rollback strategy). Wave 1 break → revert 3 commits; Wave 2 break → revert 4; Wave 3 break → revert per-HAR.
- **Matches the methodology that just succeeded** in `harness-truthful-docs-and-wiring-v1` (per-wave commits, real proof files, resist context-fatigue) — same shape, scaled to 19 ACs.
- **Audit signal monotone-improves** across the sprint: noise drops at end of W1, infrastructure lands at end of W2, real fixes land across W3, polish lands in W4. Each day's verify is better than the last.

**Cons**

- **Longest critical path.** No parallelism extracted from independent surfaces (scope-bound, audit-phase scaffolding, HAR fixes, docs). Risk of slipping into Day 14 with Wave 4 still mid-flight.
- **Wave 3 is 5 days of repetitive HAR-fix-audit-rerun-test cycles** (10 fixes × ~3 git operations × ~30min each ≈ 5-6h coding + 4-5h proof). Fatigue corner-cutting risk in days 9-11.
- **Doc work compressed to Days 12-13.** If Wave 3 overruns, AC-19's 4-doc cross-file consistency review gets squeezed (same failure mode as the closure sprint's hurried final commits).

---

## Sketch B — Parallel triad (Wave 1 + Wave 2 stub + Wave 3 HAR-1..3 first, while Wave 1 stabilizes)

Exploits the fact that Wave 1's `worker-gates.sh` changes (scope-bounding), Wave 2's `phase-manifest.json` block (declaration-only, no runtime), and Wave 3's HAR-1..HAR-3 fixes (3 isolated `.claude/helpers/*.js` files with their own tests) touch disjoint paths. Run them as three concurrent worktrees / sub-agents.

**Order**

- **Days 1-3 (parallel triad):**
  - **Worktree A:** Wave 1 implementation (AC-1..AC-4) + W1 stress-fixture smoke.
  - **Worktree B:** Wave 2 _stub_ — `phase-manifest.json` block declaration (AC-5 declaration half), `_templates/audit-resolutions.md` skeleton (AC-8). NO `sprint-audit-resolve.sh` or `sprint-audit-rerun.sh` yet — those depend on Wave 1's scope-bounding to be meaningful.
  - **Worktree C:** Wave 3 _front-load_ — HAR-1 (`execSync → execFile`), HAR-3 (`Date.now() → randomUUID`), HAR-5 (allowlist gate). All small/medium, all in `github-safe.js` + `session.js`, all independent of Wave 1's scope logic. Tests scaffolded into `.claude/helpers/__tests__/` so Wave 3's later HAR-2/HAR-4 encryption work inherits the harness.
- **Day 4:** Merge A + B + C onto sprint branch. Wave 1 must be merged first because Wave 2's `sprint-audit-rerun.sh` (still to write) depends on scope-bound `gate_audit_blocks(slug)`.
- **Days 5-7:** Finish Wave 2 — `sprint-audit-resolve.sh` (AC-6) + `sprint-audit-rerun.sh` (AC-7). These are the bulk Wave-2 LOC.
- **Days 8-11:** Finish Wave 3 — HAR-2, HAR-4, HAR-6..HAR-10 (the remaining 7 fixes including the two encryption-wrap ACs).
- **Days 12-14:** Wave 4 docs + G1/G2/G3 polish + dogfood walk.

**Wave-2 scope-bound implementation:** same locked choice (a) post-filter at gate. Sketch B does not change this; the choice is locked at plan-level not sketch-level.

**Wave-3 HAR test infrastructure:** same locked choice (b) NEW `.claude/helpers/__tests__/` with vitest config. Front-loaded in Worktree C so HAR-2/HAR-4's encryption tests inherit the infra rather than ship it.

**Pros**

- **~2 days calendar compression** vs Sketch A — independent surfaces run in parallel days 1-3. The 3 HAR-1/3/5 front-loaded fixes also de-risk Wave 3 by validating the test-harness pattern before the harder encryption HARs (HAR-2/HAR-4).
- **Wave 4 gets a real 3-day budget** (Days 12-14) for doc cross-file consistency review + the G1/G2/G3 polish work + a complete dogfood. Direct mitigation of closure-sprint failure mode (hurried Wave-4 = corner-cut docs).
- **Wave-2 stub gives Wave 3's later fixes an audit-resolution phase target** — by the time HAR-2/HAR-4 land in Days 8-11, the new phase exists in `phase-manifest.json` even if `sprint-audit-resolve.sh` isn't finished. Lets the per-HAR audit-rerun proofs land in the correct phase folder structure.
- **Three small worktrees reduce merge-conflict surface** — A touches `worker-gates.sh` + `sprint-verify.sh`, B touches `phase-manifest.json` + `_templates/`, C touches `.claude/helpers/*.js`. Disjoint files; clean 3-way merge.

**Cons**

- **Three concurrent worktrees on one harness sprint risk `.swarm/memory.db` and `state.json` contention during this very sprint.** The just-closed `harness-truthful-docs-and-wiring-v1` already fixed the state.json race, but three sub-agents writing simultaneously is still a stress test the harness hasn't seen.
- **Wave 2 split across days 1-3 (stub) and 5-7 (real)** adds context-switching cost. Author has to re-read the audit-resolution-phase design twice.
- **Coordination overhead** — 3 sub-agents to spawn, instruct, and merge. ~0.5d of management overhead, partially eating the parallelism gain.
- **Wave-3 front-loaded fixes (HAR-1/3/5) ship before Wave-1's scope-bounding lands.** Their proof files record audit-rerun-noise that the merge then has to reconcile — small but real bookkeeping cost.

---

## Sketch C — HAR-fixes-first (Wave 3 first, then Wave 1, then Wave 2)

Land the 10 HAR security fixes first while they're top-of-mind from the closure sprint's audit. Then scope-bound the workers (Wave 1). Then build the audit-resolution-phase infrastructure (Wave 2). Wave 4 polish last.

**Order**

1. **Days 1-6 — Wave 3 first.** Fix HAR-1..HAR-10. Each commits with inject-violation-catch-restore against the _current_ (non-scope-bounded) `gate_audit_blocks`. Per-AC proof shows the finding removed from the full-repo audit run.
2. **Days 7-8 — Wave 1.** Scope-bound `gate_audit_blocks(slug)` + extend `phase-workers.json`. Re-run audit against current sprint — should be zero in-scope findings (HAR-fixes landed already; this sprint's `## Files touched` is now `.claude/helpers/*.js` _plus_ `worker-gates.sh` etc.).
3. **Days 9-12 — Wave 2.** Audit-resolution-phase infrastructure + interactive resolve.sh + audit-rerun.sh + template.
4. **Days 13-14 — Wave 4.** Docs + G1/G2/G3 + dogfood.

**Wave-2 scope-bound implementation:** same locked choice (a) post-filter at gate.

**Wave-3 HAR test infrastructure:** same locked choice (b) NEW `.claude/helpers/__tests__/` with vitest config.

**Pros**

- **Security-first sequencing.** The 10 vulns are the only customer-impactful surface in this sprint — they land Day 6 rather than Day 11. Earliest ship of real security value.
- **Wave-1 dogfood gets a real test target:** by the time scope-bounding lands Day 7-8, this sprint's _own_ audit run produces zero in-scope findings (the HAR fixes are already in `## Files touched`), which is exactly the convergence proof Wave 1 wants to demonstrate.
- **Wave-2 builds against working code, not against not-yet-fixed helpers.** `sprint-audit-resolve.sh`'s smoke fixture can use a real synthetic finding without competing against the 10 HAR-1..10 baseline noise.

**Cons** (the dominant risk; see Recommendation below)

- **100% audit noise during all of Wave 3.** Every per-HAR audit-rerun run during Days 1-6 sees the full 10-finding baseline (minus whichever HAR was just fixed). Each proof file has to manually annotate "9 out-of-scope findings ignored, 1 in-scope finding removed." Bookkeeping cost compounds across 10 fixes; format drift / inconsistency risk is high.
- **Per-AC proof files in Days 1-6 will record the same advisory noise we already triaged in the prior sprint** — duplicated effort, not new signal.
- **Wave 1 lands Day 7-8 — too late to retroactively de-noise Wave 3's proofs.** Even after scope-bounding ships, the W3-proof files already record the noisy diffs. Either we accept the noise or re-run all 10 HAR audits post-Wave-1 (extra ~2h).
- **Reverses the plan's locked decision** — the plan explicitly notes "scope-bounding must land before audit-resolution-walk runs (else the resolution walk surfaces the same 100% noise)" — Sketch C violates this for Wave 3's own audit-rerun proofs even though Wave 2 itself comes after Wave 1.

---

## Recommendation: **Sketch A + (a) post-filter at gate + (b) NEW `.claude/helpers/__tests__/` with vitest config**

**Pick Sketch A.** Three reasons in order of weight:

1. **The locked plan decision is correct and Sketch A executes it cleanly.** The plan's §A explicitly states "scope-bounding must land before audit-resolution-walk runs (else the resolution walk surfaces the same 100% noise)." Wave 1 → 2 → 3 → 4 is the only ordering where every wave's verify run sees monotonically-improving signal. Sketch C violates this on Wave 3's own audit-rerun proofs; Sketch B mitigates it but still ships HAR-1/3/5 against pre-scope-bound audit output, producing the same noise-annotation bookkeeping cost on a smaller scale. Sketch A is the only ordering where every proof file reads cleanly without "ignore the 9 advisory findings, finding-N is the real one" footnotes.

2. **Class of corner-cutting that killed the closure sprint is structural, not scheduling.** Sketch B's calendar compression is real but partial — saves ~2 days only if the parallel triad merges cleanly, which depends on no harness regressions surfacing during the very sprint that fixes harness regressions. Sketch A pays the linear-critical-path cost up front (14 days for 19 ACs ≈ 1.4 ACs/day, well within historical sprint velocity) and uses the predictable schedule to enforce a real Wave-4 dogfood instead of buying calendar slack that gets re-spent on coordination overhead.

3. **Post-filter at gate (option a) is the only choice that survives the existing test surface.** Choices (b) prompt-inject in worker-trigger and (c) env-var to ruflo daemon both require touching the ruflo daemon worker-invocation path, which has zero in-repo tests because the daemon is external. Choice (a) modifies `gate_audit_blocks` in `worker-gates.sh` — a function that already has the canonical test pattern via `gate_testgaps_blocks` (which works the same way). Mirroring proven code is cheaper to test and cheaper to debug. Per the plan's §B "pre-existing model — NO new work needed," `gate_testgaps_blocks` already scope-bounds via spec.md §H parsing at gate-evaluation; we just extend the same pattern to `gate_audit_blocks`. Choice (a) is locked because it's the lowest-risk, best-tested implementation surface.

**Why test infrastructure (b) NEW `.claude/helpers/__tests__/` with vitest config is locked:**

- (a) inline assertions in helper files mixes test code with production code in the same `.cjs` file — violates separation-of-concerns and makes the helpers heavier to load on every Claude Code session.
- (c) shell-based smoke tests via inject-violation pattern would work but doesn't give the per-HAR proof a quick `pnpm test` re-run path — operators would have to manually re-construct each smoke each time they touch a helper. Vitest gives a one-command regression suite.
- (b) gives executable, runnable, CI-friendly per-HAR proofs with the cost of one `vitest.config.cjs` file. The 10 HAR fixes are the only customer-facing security work in this sprint; they deserve real test infrastructure not shell scaffolding.

**Why not Sketch B:** the calendar compression is real but bought at the cost of (i) Wave-3 front-loaded fixes producing proofs against the pre-scope-bound audit output (same bookkeeping cost as Sketch C, smaller scale), (ii) coordination overhead across 3 worktrees eating ~0.5d of the parallelism gain, (iii) Wave-2 split across days 1-3 (stub) and 5-7 (real) doubles the context-load cost for the author. Net savings ≈ 1d, which Sketch A buys back simply by not corner-cutting Wave 4.

**Why not Sketch C:** explicitly violates the plan's locked decision on wave ordering. The 100% noise ratio during all of Wave 3 is exactly the failure mode this sprint exists to eliminate — running Wave 3 _against_ that failure mode for 6 days is intellectually self-defeating, even if Wave 1 fixes it on Day 7. The proof files would record the noise we are paid to eliminate.

**Risk to watch in Sketch A:** Wave 3 fatigue corner-cutting in Days 9-11. Mitigation: each HAR AC must include (i) the audit-rerun output before fix, (ii) the audit-rerun output after fix, (iii) the corresponding `.claude/helpers/__tests__/*.test.cjs` test file, (iv) an entry in the wave's running proof file. No prose-only entries. If a per-HAR AC overruns its half-day budget, escalate to splitting HAR-2 or HAR-4 (the two encryption-wrap ACs, both Medium effort) into a follow-up sprint — but keep HAR-1/3/5/6/7/8/9/10 in scope (8 of 10 fixes ship is a real result; 0 of 10 because HAR-2 ate the week is the closure-sprint failure mode recurring).
