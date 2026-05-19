# Sprint Quickstart — Your First Sprint in 5 Minutes

> **Goal of this doc:** get you to the wizard within 5 minutes of opening it.
> **Pairs with:** [`USAGE.md`](./USAGE.md) (full guide), [`README.md`](./README.md) (architecture).

---

## Worker model — what to expect (NEW 2026-05-19)

Sprint-stage-driven workers (audit, optimize, testgaps, etc.) fire ONLY at known checkpoints:

- **Day 0** (start): `map` worker refreshes codebase context
- **Day 11-12** (verify): `audit` + `testgaps` run as BLOCKING gates; deploy blocks on any vulnerability or untested route in `## Files touched`
- **Day 14** (retro): `document` worker proposes CLAUDE.md updates into retro.md

These use your Claude Code OAuth session (Pro/Max quota), not a separate API key. **Daemon state:** `RUNNING` with 0 workers on schedule (verify via `ruflo daemon status`). Cost per 14-day sprint: ~50 min Sonnet, all at consequential checkpoints. **>99% reduction** vs the prior scheduled-worker model.

In CI without OAuth: sprint-verify hard-fails with a clear "run locally before pushing" error. Local-only by design.

Full mapping: [USAGE.md "Worker integration"](./USAGE.md#worker-integration-on-demand-sprint-protocol-driven).

---

## Before you start (60 seconds)

Run the **systems-health precheck** (AC-33). It blocks `sprint-start.sh` if anything critical is down:

```bash
bash scripts/sprint-precheck.sh --mode start --strict
```

Expected: all 6 checks ✓ (ruflo daemon, MCP server, memory.db, launchd memory-decay, graphify-out, husky hooks). If any FAIL:

```bash
# Daemon down?
ruflo daemon start --workspace .

# Launchd cron not registered?
bash scripts/launchd/install-memory-decay.sh

# graphify-out missing?
pnpm graphify:rebuild
```

Override (logged): `SPRINT_PRECHECK_BYPASS=1 bash scripts/sprint-start.sh ...`. AWS profile is auto-checked by precheck.

---

## The single command (1 second)

```bash
bash scripts/sprint-start.sh my-first-sprint
```

Output:

```
╔══════════════════════════════════════════════════════════════════════╗
║  Sprint started: my-first-sprint
╚══════════════════════════════════════════════════════════════════════╝

  Sprint dir: docs/sprints/my-first-sprint/
  State:      docs/sprints/my-first-sprint/state.json
  Branch:     sprint/my-first-sprint

  Next step: Claude will now invoke the sprint-spec-wizard skill.

  Ask Claude: "start the spec wizard"
```

That's it. You're in.

---

## The wizard (20-40 minutes)

Tell Claude:

> "start the spec wizard"

Claude will guide you through **10 sections**. At any point you can:

- **Pause:** just stop — state is saved after every answer
- **Resume:** run `bash scripts/sprint-status.sh` then tell Claude "continue the wizard"
- **Redo a section:** tell Claude "redo §C"
- **See progress:** tell Claude "show me the spec so far"

### What the 10 sections cover

| §   | Topic               | Adaptive — skipped if...         |
| --- | ------------------- | -------------------------------- |
| A   | Problem & Vision    | Never                            |
| B   | Business Logic      | "pure refactor, no logic change" |
| C   | Data & Schema       | "no schema change"               |
| D   | API Surface         | "frontend only"                  |
| E   | UI Components       | "backend only"                   |
| F   | UX Flow             | "backend only"                   |
| G   | Visual Design       | "no UI"                          |
| H   | Integration Points  | Never                            |
| I   | Acceptance Criteria | Never                            |
| J   | Risks & Rollback    | Never                            |

A typical full-stack sprint asks ~35-45 questions; a backend-only refactor asks ~15.

---

## After the wizard (15 minutes)

Claude generates 4 outputs for the spec-lock gate:

1. **Solution sketches** — 2-3 alternatives with tradeoffs
2. **Architect review** — separate agent reviews boundaries
3. **Security review** — separate agent reviews RLS/auth
4. **Hive-mind consensus** — 5 workers vote on coherence

You read all 4, edit `spec.md` if needed, then:

```bash
bash scripts/sprint-amend-spec.sh --lock
```

From this moment forward:

- **Every commit gets a drift score** — below 0.75 pauses the commit
- **Every file edit is checked** against the spec's "Files touched" list
- **`git push` and `pulumi up` are forbidden** until sprint-end

---

## The 5 gates (you decide at each)

1. **Spec-lock** — after wizard + 4 reviews
2. **Design-lock** — after SPARC architect output
3. **Pre-merge review** — every commit in PR
4. **Day-5 check-in** — cut, push, or pivot?
5. **Pre-deploy approval** — workflow pauses at `pulumi preview`

---

## A real example — what to expect

Let's say you say:

> "start a sprint for supplements compliance widget"

What happens:

```
[me] Running bash scripts/sprint-start.sh supplements-compliance
     ✓ Sprint dir created
     ✓ Branch sprint/supplements-compliance checked out
     ✓ Drift control armed (will activate at spec-lock)

[me] Starting §A — Problem & Vision.
     I recalled 2 LifeOS patterns relevant to "supplements":
       - lifeos-build-context (score 0.71)
       - frontend-hook-pattern (score 0.58)

     Apply as defaults?

[you] Yes.

[me] A1 — In your own words, what's broken or missing today?

[you] Users configure supplements at onboarding but never get reminded
     or see compliance %.

[me] A2 — Who suffers? Pick 1-2 personas.

[you] Early-users post-onboarding. Zefyra noticed she stopped taking
     hers after day 4.

[me] A3 — Why now?

[you] Founding-user trust signal at risk. Data infra is in place; just
     need UI.

[... A4, A5 ...]

[me] Coherence check after §A: success vision matches problem. Moving
     to §B — Business Logic.

[... continues through §B-§J ...]

[me] Wizard complete. Assembling spec.md.
     Generating solution sketches...
     Architect review...
     Security review...
     Hive-mind consensus: 5/5 yes ✓

     Spec is locked-pending-review. Read these 4 files:
       - docs/sprints/supplements-compliance/spec.md
       - docs/sprints/supplements-compliance/solution-sketches.md
       - docs/sprints/supplements-compliance/architect-review.md
       - docs/sprints/supplements-compliance/security-review.md

     Make any edits, then say "lock it".

[you] [reads, edits] Lock it.

[me] Running bash scripts/sprint-amend-spec.sh --lock
     ✓ Drift baseline embedded
     ✓ Phase → spec-locked

     Now starting SPARC design phase. Day 1-2.
```

You're off and running.

---

## What you have to remember

Just **7 things**:

1. **`bash scripts/sprint-start.sh <slug>`** to begin (runs AC-33 precheck first)
2. **`bash scripts/sprint-status.sh`** to check progress (shows time-box at 110% appetite)
3. **Tell Claude what you want** — Claude drives the rest
4. **5 gates need your sign-off** — spec-lock, design-lock, per-commit, day-5, pre-deploy
5. **`SPRINT_DRIFT_BYPASS=1`** is the escape hatch if drift blocks something you need
6. **AC-31 amendments require WHY+INTENT** — `AMEND_WHY="..." AMEND_INTENT="..." bash scripts/sprint-amend-spec.sh --add-file <path>`
7. **Production verdict requires inject-catch-restore evidence**, not file presence. Use `scripts/sprint-inject-violation.sh <fixture> "<gate-cmd>"` to produce proof files.

Everything else is in [`USAGE.md`](./USAGE.md). Stuck? [`_guides/troubleshooting.md`](./_guides/troubleshooting.md).

---

## Common "wait, what?" moments

> _"The wizard is asking too many questions."_

You picked a feature too big. Tell Claude: _"cut scope — let's make this backend-only first, then a follow-up sprint for the UI."_ I'll re-evaluate skip flags and shorten the wizard.

> _"The drift check just blocked my commit."_

Three options (prompted automatically):

1. Amend spec: `bash scripts/sprint-amend-spec.sh` (re-baselines)
2. Discard commit: `git reset HEAD~ --soft`
3. Override once: `SPRINT_DRIFT_BYPASS=1 git commit ...`

> _"The hook blocked `git push`."_

That's by design — PR flow only during sprint. Run `bash scripts/sprint-end.sh <slug>` to close, OR `bash scripts/sprint-pause.sh` to suspend enforcement.

> _"I want to skip §G — I know the design already."_

When §G starts, tell Claude: _"skip §G, follow existing Ordex brand book."_ I'll mark it skipped with reason.

> _"Something broke and I don't know what's happening."_

```bash
bash scripts/sprint-status.sh --json    # full state dump
node scripts/sprint-dashboard.mjs <slug> --open  # visual catch-up
cat docs/sprints/<slug>/state.json | jq .
```

Then tell me: _"explain what's happening with this sprint"_ — I'll read state + recent commits + drift events and give you a brief.

---

## What you get at the end

After 14 days (or however long):

```bash
bash scripts/sprint-end.sh my-first-sprint
```

Produces:

- **`retro.md`** — what worked / didn't / surprised + velocity metrics
- **3-5 new memories** stored in `.swarm/memory.db` (recallable in future sprints)
- **Possible CLAUDE.md update** if a new convention emerged
- **DAA reviewer feedback batch** (the lifeos-reviewer agent learns your style)
- **`metrics.json`** — timing, drift count, AC closure rate, success criteria

Your next sprint will:

- Have more memories to recall from
- Routing slightly better tuned (SONA adapted)
- DAA reviewer marginally smarter
- Hit fewer false-positive drift pauses (you tuned the threshold based on data)

---

## Where to go from here

- **Full guide:** [`USAGE.md`](./USAGE.md) (everything; ~25 min read)
- **Architecture:** [`README.md`](./README.md) (dir structure; ~5 min)
- **Spec template:** [`_template/spec.md`](./_template/spec.md) (what the wizard fills)
- **Worked example:** [`USAGE.md` §"14-day flow with worked example"](./USAGE.md#the-14-day-flow-with-worked-example)
- **Troubleshooting:** [`USAGE.md` §"Troubleshooting"](./USAGE.md#troubleshooting)

---

**Stuck?** Tell Claude: _"I'm stuck — explain where we are and what to do next."_ I'll read state + recent activity and give you a 2-paragraph brief.

---

## Harness depth at a glance

71 capabilities, 14 groups, all proven via inject-violation-catch-restore:

| Group              | Range    | What it covers                                                                                                                          |
| ------------------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| 1 (Verify gates)   | AC-1-15  | typecheck, lint, test, graphify, playbook, sonar, migration, knip, coverage-delta, audit-deps, bundle, cycle, perf, aidefence, all-pass |
| 2 (Workflows)      | AC-16-19 | build / verify / cleanup / deploy YAMLs via `run-workflow.sh` shim                                                                      |
| 3 (Scripts)        | AC-20-25 | pause / resume / checkin / hillchart / standup / pr-body / amend                                                                        |
| 4 (Leftovers)      | AC-26-30 | DAA queue, hive-mind polling, GH addSubIssue, audit wiring                                                                              |
| 5 (Wizard)         | AC-31-35 | orchestrator, context, coherence, assemble, 10 section skills                                                                           |
| 6 (Drift)          | AC-36-40 | drift-check, drift-score, sprint-hook.cjs, PreToolUse Bash/Edit                                                                         |
| 7 (Husky)          | AC-41-44 | pre-commit / post-commit / pre-push / post-merge                                                                                        |
| 8 (Build)          | AC-45-49 | 8-agent swarm, claims, stream-chain, pair-mode, 7 daemon workers                                                                        |
| 9 (Autopilot)      | AC-50-52 | lint-fix / test-backfill / doc-sweep                                                                                                    |
| 10 (Verify skills) | AC-53-56 | api-contract / debug-rls / module-status / performance_profile                                                                          |
| 11 (Reporting)     | AC-57-60 | statusline / dashboard / sprint-pr-body GH action / sprint-rebase-check GH action                                                       |
| 12 (End-to-end)    | AC-61-62 | deploy chain, cleanup chain                                                                                                             |
| 13 (Amend+memory)  | AC-63-67 | --add-file / --lock / --close-ac, memory-decay, cross-pattern audit                                                                     |
| 14 (Docs+search)   | AC-68-71 | claude-md-upgrade, sprint-system-test, sprint-system-audit, **WebSearch PII redaction**                                                 |

Full proof files: `docs/sprints/harness-full-coverage/proof/AC-1.md` through `AC-71.md`.
