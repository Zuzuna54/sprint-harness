# Sprint Quickstart — Your First Sprint in 5 Minutes

> **Goal of this doc:** get a new operator (or LLM session) to "start a sprint correctly" in 5 minutes.
> **Pairs with:** [`USAGE.md`](./USAGE.md) (full 14-day flow, worker architecture, bypass, troubleshooting), [`DEVELOPER.md`](./DEVELOPER.md) (internals, terminology contract, extension recipes).
>
> This doc is intentionally short. Anything not on this page lives in USAGE or DEVELOPER.

---

## v0.7.0 callout — phase enforcement is mechanical now

> **What changed.** Before v0.7.0, the 14-day protocol was documented but a model could skip wizard sections, day-5 questions, retro patterns, or verify commands and the sprint would still close. v0.7.0 made every phase transition a predicate check against `scripts/lib/phase-manifest.json`. v0.7.1 wired the remaining 43 sub-step gates and the per-phase worker map.
>
> **Single canonical writer.** `scripts/sprint-advance-phase.sh <next-phase>` is the only sanctioned writer of `state.phase`. Every other phase-writer (`sprint-amend-spec.sh --lock`, `sprint-build-launch.sh`, `sprint-end.sh`, etc.) delegates to it.
>
> **Single bypass UX.** When you genuinely need to skip a gate:
>
> ```bash
> SPRINT_BYPASS_GATE=<gate-name> SPRINT_BYPASS_WHY='<≥10 chars rationale>' \
>   bash scripts/sprint-advance-phase.sh <next-phase>
> ```
>
> **`SPRINT_DRIFT_BYPASS=1` is DEPRECATED** (still works in v0.7.x via auto-translation with a stderr warning; **removal scheduled v0.8.0**). Same for `SPRINT_DESIGN_LOCK_BYPASS=1`, `SPRINT_HIVE_MIND_BYPASS=1`, and every other per-script `SPRINT_*_BYPASS=1` env. Use the canonical UX above.
>
> **v0.7.3+ additions.** New `review-resolution` phase (supersedes `audit-resolution`) walks **three** producer streams under one phase: audit (security) + knip (dead-code) + sonar (code quality). Run `bash scripts/sprint-review-resolve.sh` to triage each HAR-N finding interactively (Fix / Defer / Accept) across all producers; `bash scripts/sprint-review-rerun.sh` does per-producer baselines diff (FIXED/REGRESSION/UNCHANGED) with twice-consecutive regression gating. The `audit-resolution` phase + `sprint-audit-resolve.sh` / `sprint-audit-rerun.sh` remain as legacy aliases for sprints that locked spec under v0.7.2.
>
> **v0.7.2 additions** (still active): new `audit-resolution` phase (Days 12–13) adds explicit fix capacity between `verifying` and `pre-deploy`. Worker scope-bounding (`gate_audit_blocks` is `files-touched`-aware, mirroring `gate_testgaps_blocks`) drops repo-wide noise to advisory and keeps in-scope findings blocking. At-rest encryption (AES-256-GCM via node built-in `crypto`) landed for `.claude/helpers/{memory,session}.js`. See [`USAGE.md` §1 (14-day flow) + §3 (Worker scope)](./USAGE.md) for operator details.

---

## The 7-step happy path

A normal sprint goes through these seven steps. Each step has one canonical entry.

| Step | What                                                       | How                                                                                                               |
| ---- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| 1    | Sprint start                                               | `bash scripts/sprint-start.sh <slug>`                                                                             |
| 2    | Spec wizard                                                | Tell Claude: `"start the spec wizard"` (10 adaptive sections, 20–40 min)                                          |
| 3    | Spec-lock 4-way review                                     | Tell Claude: `"do the spec-lock review chain"` — produces sketches + architect + security + consensus             |
| 4    | SPARC design                                               | Tell Claude: `"do the SPARC design phase"` → `design.md` → user sign-off                                          |
| 5    | Build                                                      | `bash scripts/sprint-build-launch.sh` — TDD swarm; drift score per commit                                         |
| 6    | Verify                                                     | Tell Claude: `"verify the sprint"` — runs typecheck/lint/tests/RLS + daemon workers (audit/testgaps)              |
| 6.5  | Review-resolution _(v0.7.3+; supersedes audit-resolution)_ | `bash scripts/sprint-review-resolve.sh` — walk each HAR finding across audit + knip + sonar: Fix / Defer / Accept |
| 7    | Retro                                                      | `bash scripts/sprint-end.sh <slug>` — retro.md + memory extraction + metrics                                      |

Each step ends with a phase transition via `sprint-advance-phase.sh`. The manifest blocks the advance if any required sub-step gate is unrecorded.

---

## Step 1 — Sprint start (1 minute)

```bash
bash scripts/sprint-start.sh my-first-sprint
```

Creates:

- `docs/sprints/my-first-sprint/` with `state.json`, `spec.partial.json`, and the skeleton dirs
- (Optionally) branch `sprint/my-first-sprint` via `--with-branch`
- (Optionally) GitHub Issue

The systems-health precheck runs first (AC-33). If anything's down (ruflo daemon, MCP, memory.db, launchd cron, graphify, husky), it tells you exactly what to fix:

```bash
# Daemon down?
ruflo daemon start --workspace .

# Launchd cron not registered?
bash scripts/launchd/install-memory-decay.sh

# graphify-out missing?
pnpm graphify:rebuild
```

Emergency override (logged): `SPRINT_PRECHECK_BYPASS=1 bash scripts/sprint-start.sh ...`.

---

## Step 2 — The wizard (20–40 minutes)

Tell Claude:

> "start the spec wizard"

Claude walks 10 sections (A–J). Skip rules adapt to your answers in §A (backend-only → skip E/F/G; no schema change → skip C; etc.). After every 3 sections, Claude runs a coherence check.

At any point:

- **Pause:** just stop — state saves after every answer
- **Resume:** `bash scripts/sprint-status.sh` then tell Claude `"continue the wizard"`
- **Redo §X:** tell Claude `"redo §C"`
- **See spec so far:** `node scripts/sprint-wizard-assemble.mjs <slug> --partial --dry-run`

A typical full-stack sprint asks ~35–45 questions; a backend-only refactor asks ~15.

---

## Step 3 — Spec-lock 4-way review (15 minutes)

After §J, tell Claude:

> "do the spec-lock review chain"

Claude generates four artifacts in `docs/sprints/<slug>/`:

1. `solution-sketches.md` — 2–3 alternatives with tradeoffs
2. `architect-review.md` — architect Task sub-agent reviews boundaries
3. `security-review.md` — security-architect Task sub-agent reviews RLS/auth
4. `consensus-spec.json` — hive-mind consensus (5 workers vote on coherence)

You read all four, edit `spec.md` if needed, then:

```bash
bash scripts/sprint-amend-spec.sh --lock
```

From this moment forward:

- Every commit gets a **drift score**; below 0.75 pauses the commit
- Every file edit is checked against `## Files touched`
- `git push` and `pulumi up` are hook-blocked until sprint-end

---

## Steps 4–7 — Design, build, verify, retro

In order:

```bash
# Step 4 — SPARC design (Days 1-2)
# Tell Claude: "do the SPARC design phase"
# Produces docs/sprints/<slug>/design.md → user sign-off → design-locked

# Step 5 — Build (Days 3-11)
bash scripts/sprint-build-launch.sh
# Day 5 mid-cycle:
bash scripts/sprint-checkin.sh

# Step 6 — Verify (Days 11-12)
# Tell Claude: "verify the sprint"
# Fires audit + testgaps + optimize daemon workers; blocks on **in-scope** findings or untested routes
# (out-of-scope findings logged as advisory only — see USAGE.md §3 Worker scope)

# Step 6.5 — Review-resolution (Days 12-13, v0.7.3+; supersedes audit-resolution)
bash scripts/sprint-review-resolve.sh
# Walks each HAR-N finding across THREE producers (audit + knip + sonar) interactively. Fix = make
# code change + sprint-review-rerun.sh re-fires the affected producer + diffs per-producer baseline.
# Defer = REQUIRED follow-up sprint slug + AC ID. Accept = REQUIRED risk owner + business rationale.
# Every decision atomically persisted; Ctrl-C safe — resume picks up where you left off. Vacuous
# PASS if all three producers reported 0 findings (no operator action needed).
#
# Legacy alias: bash scripts/sprint-audit-resolve.sh — still works for sprints that locked spec
# under v0.7.2 (the audit-only walker; review_resolution_complete predicate transparently consumes
# legacy audit_findings_* state fields).

# Step 7 — Retro (Day 14)
bash scripts/sprint-end.sh my-first-sprint
# Tell Claude: "walk me through the retro"
```

Each command writes its phase advance through `sprint-advance-phase.sh`. If any required sub-step gate is missing, the advance refuses to proceed and points you at the exact unmet predicate.

---

## Common stuck recipes

### "The drift check just blocked my commit"

Three options (prompted automatically):

1. **Amend spec** — the work is in scope but the spec didn't mention it:
   ```bash
   AMEND_WHY='...' AMEND_INTENT='...' bash scripts/sprint-amend-spec.sh --add-file <path>
   ```
2. **Discard commit** — the diff isn't what you wanted: `git reset HEAD~ --soft`
3. **Override once** — you have a real reason; use the canonical bypass:
   ```bash
   SPRINT_BYPASS_GATE=drift-check \
   SPRINT_BYPASS_WHY='Refactor touches mealprep module — orthogonal to current sprint but tactical fix' \
     git commit ...
   ```
   `SPRINT_DRIFT_BYPASS=1 git commit` still works in v0.7.x with a deprecation warning. Prefer the canonical UX.

### "The hook blocked my `git push`"

That's by design — PR flow only during active sprint. Two paths:

```bash
bash scripts/sprint-end.sh <slug>     # finish the sprint, then push
bash scripts/sprint-pause.sh "reason" # suspend enforcement; bash scripts/sprint-resume.sh later
```

### "I want to skip a wizard section"

When §G starts, tell Claude: `"skip §G — following existing Ordex brand book."` Claude marks it skipped with the reason; the wizard records a `skip_reasons.G` entry that the assembler propagates to the spec.

### "The wizard is asking too many questions"

You picked a feature too big. Tell Claude: `"cut scope — let's make this backend-only first, then a follow-up sprint for the UI."` Claude re-evaluates skip flags from your earlier answers and shortens the remaining sections.

### "I genuinely need to skip a verify gate"

The tool is down, or the predicate doesn't apply to this sprint shape (e.g., harness-itself sprint with no Lambdas → no `verify-debug-rls`). Use the canonical bypass:

```bash
SPRINT_BYPASS_GATE=verify-sonar \
SPRINT_BYPASS_WHY='Sonar container down — escalated to infra; rerun scheduled within 24h' \
  bash scripts/sprint-advance-phase.sh pre-deploy
```

Every accepted bypass appends to `state.gate_bypasses[]` and surfaces in retro + dashboard. `sprint-velocity.mjs` flags sprints with >3 bypasses as `high_bypass: true`.

---

## What you have to remember

Just **5 things**:

1. **`bash scripts/sprint-start.sh <slug>`** to begin
2. **`bash scripts/sprint-status.sh`** to check progress
3. **Tell Claude what you want** — Claude drives the rest
4. **`SPRINT_BYPASS_GATE=... SPRINT_BYPASS_WHY=...`** is the single canonical escape hatch
5. **`sprint-advance-phase.sh`** is the only sanctioned writer of `state.phase` — every other phase script delegates to it

Everything else (the 14-day flow, the worker architecture, the full bypass + troubleshooting catalogs) is in [`USAGE.md`](./USAGE.md). System internals, the terminology contract, and extension recipes are in [`DEVELOPER.md`](./DEVELOPER.md).

---

## Where to go from here

- **Full guide:** [`USAGE.md`](./USAGE.md) — 14-day flow, phase enforcement, worker architecture, bypass cheatsheet, troubleshooting
- **Script reference:** [`SCRIPTS.md`](./SCRIPTS.md) — canonical inventory of every harness script (90+ files)
- **Internals:** [`DEVELOPER.md`](./DEVELOPER.md) — terminology contract, phase-manifest extension, state.json schema, race recipes
- **Architecture overview:** [`README.md`](./README.md)
- **Bypass cheatsheet:** [`_guides/bypass-cheatsheet.md`](./_guides/bypass-cheatsheet.md) (folded into USAGE §4 — this is the long-form copy)
- **Troubleshooting catalog:** [`_guides/troubleshooting.md`](./_guides/troubleshooting.md) (folded into USAGE §5)
- **State.json recovery:** [`_guides/state-json-recovery.md`](./_guides/state-json-recovery.md)

---

**Stuck?** Tell Claude: `"I'm stuck — explain where we are and what to do next."` Claude reads `state.json`, recent commits, and recent drift events and gives you a 2-paragraph brief.
