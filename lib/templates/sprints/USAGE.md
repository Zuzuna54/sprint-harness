# Sprint System — Usage Guide

> **For:** anyone building LifeOS features
> **What this is:** the practical "how to use it" guide. Pairs with [`README.md`](./README.md) (architecture overview) and [`hazy-gathering-kettle.md`](../../../.claude/plans/hazy-gathering-kettle.md) (full design plan, in `~/.claude/plans/`).
> **Audience:** solo dev who's never seen this system before. Or a future dev joining the team.

---

## TL;DR (30 seconds)

You're building features in 2-week chunks. Every chunk is a "sprint." Each sprint follows the same shape: **spec → design → build → verify → deploy → retro**. Claude (me) drives it; you make decisions at 5 gates.

**Harness depth (as of 2026-05-17):** 71 capabilities across 14 groups, all proven via inject-violation-catch-restore. Production verdict requires real-injection evidence — file presence is not enough. See [README.md §"Harness capabilities"](./README.md) for the catalog.

**One command to start:**

```bash
bash scripts/sprint-start.sh <slug>
```

Then tell me: `"start the spec wizard"` and I'll walk you through 10 sections of product discovery (15-45 adaptive questions). By the end, you have a complete spec, drift control is armed, and we can start building.

---

## What this tool does for you

| Without sprint system                         | With sprint system                                   |
| --------------------------------------------- | ---------------------------------------------------- |
| "Hey Claude, build X" → ad-hoc work           | Structured 14-day cycle with deterministic phases    |
| Scope drifts during build                     | Drift score on every commit; hard pause below 0.75   |
| Claude edits files outside the intended scope | PreToolUse hook blocks out-of-scope edits            |
| Forgetting a spec detail                      | Wizard captures it; spec.md is the source of truth   |
| No record of why a decision was made          | Wizard transcript + recalled patterns + retro        |
| Building the same thing twice in 3 months     | Memory recall surfaces prior patterns at spec time   |
| Push to main by accident                      | Husky hook blocks `git push` during sprint           |
| Lost track of what's done                     | Hill chart + dashboard + GitHub PR auto-fill         |
| Patterns never re-used                        | Retro extracts 3-5 patterns → stored to ruflo memory |

---

## Two ways to interact

### Way 1 — Talk to Claude

Easiest. Tell me what you want, I run the right scripts.

| You say                                     | I do                                                                                      |
| ------------------------------------------- | ----------------------------------------------------------------------------------------- |
| "start a sprint for supplements compliance" | `bash scripts/sprint-start.sh supplements-compliance` → invoke `sprint-spec-wizard` skill |
| "continue the wizard" / "next section"      | Read current state, ask next question per `sprint-spec-wizard/sections/<X>.md`            |
| "show me the spec so far"                   | `node scripts/sprint-wizard-assemble.mjs <slug> --partial --dry-run`                      |
| "redo §C"                                   | Clear `sections_answers.C`, re-enter §C                                                   |
| "what's the sprint status?"                 | `bash scripts/sprint-status.sh`                                                           |
| "pause the sprint"                          | `bash scripts/sprint-pause.sh`                                                            |
| "resume"                                    | `bash scripts/sprint-resume.sh`                                                           |
| "amend the spec"                            | `bash scripts/sprint-amend-spec.sh`                                                       |
| "do the day-5 check-in"                     | `bash scripts/sprint-checkin.sh` + walk through 3 questions                               |
| "verify the sprint"                         | Execute lifeos-sprint-verify workflow                                                     |
| "deploy"                                    | Execute lifeos-deploy workflow (will pause for your approval)                             |
| "end the sprint"                            | `bash scripts/sprint-end.sh <slug>` + walk through retro                                  |

### Way 2 — Run scripts directly

Useful for scripting/CI. Less context — you drive instead of me.

```bash
bash scripts/sprint-start.sh <slug>            # create sprint dir, branch, issue
bash scripts/sprint-status.sh                  # current phase
bash scripts/sprint-status.sh --slug-only      # active slug (programmatic)
bash scripts/sprint-status.sh --json           # full state JSON

node scripts/sprint-spec-wizard.mjs status <slug>            # wizard progress
node scripts/sprint-spec-wizard.mjs section <slug> A         # emit section A context
node scripts/sprint-spec-wizard.mjs answer <slug> A A1 '"<text>"'  # record answer
node scripts/sprint-spec-wizard.mjs assemble <slug>          # render spec.md

bash scripts/sprint-amend-spec.sh              # edit spec (re-baselines drift)
bash scripts/sprint-amend-spec.sh --lock       # spec-lock gate
bash scripts/sprint-amend-spec.sh --cut AC-3,AC-5   # scope reduction
bash scripts/sprint-amend-spec.sh --add-file <path> # widen scope

bash scripts/sprint-rebaseline.sh              # re-embed spec.md for drift

bash scripts/sprint-pause.sh "reason"          # pause
bash scripts/sprint-resume.sh                  # resume

bash scripts/sprint-checkin.sh                 # day-5 hill chart

node scripts/sprint-hillchart.mjs <slug>       # print hill chart
node scripts/sprint-hillchart.mjs <slug> --refresh   # write to hill-chart.md
node scripts/sprint-pair-check.mjs <slug>      # which ACs need pair-mode

bash scripts/sprint-build-launch.sh            # Phase 3 kickoff

node scripts/sprint-standup.mjs <slug>         # generate today's standup
node scripts/sprint-pr-body.mjs <slug>         # generate PR body (stdout)
node scripts/sprint-pr-body.mjs <slug> --pr 42 # update PR #42
node scripts/sprint-dashboard.mjs <slug>       # write dashboard.html
node scripts/sprint-dashboard.mjs <slug> --open  # also open in browser

bash scripts/sprint-gh-project-sync.sh         # sync GH Project board
bash scripts/sprint-train.sh                   # gated neural training check
bash scripts/sprint-train.sh --force           # force-run training
bash scripts/sprint-daa-feedback.sh            # feed DAA reviewer

node scripts/sprint-velocity.mjs <slug>        # compute metrics.json
node scripts/sprint-velocity.mjs <slug> --json # JSON output

bash scripts/sprint-end.sh <slug>              # retro + close

# Sprint-system-100 additions (51 scripts total)
bash scripts/sprint-precheck.sh <slug> --mode start --strict    # AC-33 health gate
bash scripts/sprint-system-test.sh <slug>      # AC-16/closeout: 99-test smoke
bash scripts/sprint-smoke-validate.sh <slug>   # AC-16 quick file-presence audit
bash scripts/sprint-hive-mind-spec-lock.sh <slug>  # AC-12 two-queen consensus
bash scripts/sprint-pre-merge-gate.sh          # AC-13 pre-push gate logic
node scripts/sprint-claude-md-upgrade.mjs <slug>   # AC-8 CLAUDE.md auto-diff
node scripts/sprint-changelog.mjs <slug>       # AC-30 CHANGELOG + index regen
node scripts/sprint-research-cache.mjs list    # AC-10 WebSearch cache
node scripts/sprint-research-cache.mjs save <slug> '<query>' '<sources-json>'
node scripts/sprint-research-cache.mjs get <slug>
node scripts/sprint-deadcode-delete.mjs <slug>          # AC-18 dry-run
node scripts/sprint-deadcode-delete.mjs <slug> --commit # AC-18 + git rm + revert-on-fail
node scripts/sprint-test-hardening.mjs <slug>  # AC-19 route-coverage CSV
node scripts/sprint-gh-mirror.mjs check        # AC-32 GH diag
node scripts/sprint-gh-mirror.mjs init <slug>  # AC-32 Epic + sub-issues
node scripts/sprint-gh-mirror.mjs close-ac <slug> <AC-N>
node scripts/sprint-gh-mirror.mjs close <slug>
bash scripts/sprint-cleanup-launch.sh <slug>   # AC-24 day 11-12 cleanup phase
bash scripts/sprint-cleanup-launch.sh <slug> --commit-deadcode  # actually delete
node scripts/sprint-spec-wizard.mjs recall-backfill <slug>  # AC-27 auto-recall
node scripts/sprint-spec-wizard.mjs set-mode <slug> autopilot # AC-1 wizard mode
bash scripts/launchd/install-memory-decay.sh   # AC-6 install nightly cron

# Harness-full-coverage additions (2026-05-17) — 71-AC proof tooling
bash scripts/sprint-inject-violation.sh <fixture> "<gate-command>"  # inject-catch-restore helper
bash scripts/run-workflow.sh <yaml> [slug=<slug>]   # minimal YAML workflow runner (ruflo #1916 shim)
bash scripts/sprint-lint-check.sh [paths...]        # ESLint shim (bypasses interactive next lint)
bash scripts/sprint-pii-redact.sh "<text>"          # strip email/UUID/JWT/API-key/password/dburl
bash scripts/sprint-pii-redacted-search.sh "<query>"  # redact-then-search wrapper
node scripts/sprint-harness-readiness.mjs <slug>    # aggregate proof/AC-N.md → harness-readiness.md
```

## Env vars (cross-section quick reference)

| Var                                                                                     | Default       | Effect                                              |
| --------------------------------------------------------------------------------------- | ------------- | --------------------------------------------------- |
| `SPRINT_DRIFT_THRESHOLD`                                                                | `0.75`        | Cosine threshold for pre-commit drift block         |
| `SPRINT_DRIFT_BYPASS`                                                                   | unset         | Skip drift + scope-hook (logs to retro)             |
| `SPRINT_DUP_THRESHOLD`                                                                  | `50`          | jscpd similarity % that blocks                      |
| `SPRINT_DUP_BYPASS`                                                                     | unset         | Skip AC-17 jscpd block (logs `gate_bypasses[]`)     |
| `SPRINT_DUP_REPO_SCAN`                                                                  | unset         | Single-file commits also trigger repo-wide jscpd    |
| `SPRINT_SKIP_REUSE_AUDIT`                                                               | unset         | Skip post-commit AC-5 reuse audit entirely          |
| `SPRINT_NO_REVIEW_GATE`                                                                 | unset         | Skip AC-13 pre-push review gate (logs bypass)       |
| `SPRINT_PRECHECK_BYPASS`                                                                | unset         | Skip AC-33 systems-health blocking precheck         |
| `SPRINT_HIVE_MIND_BYPASS`                                                               | unset         | Skip AC-12 daemon requirement                       |
| `SPRINT_GH_BYPASS`                                                                      | unset         | Skip every GH API call in mirror script (offline)   |
| `SPRINT_SKIP_GRAPHIFY`                                                                  | unset         | Skip verify-workflow graphify-rebuild step          |
| `SPRINT_DEADCODE_COMMIT`                                                                | unset         | Cleanup phase actually deletes (vs dry-run)         |
| `AMEND_WHY` / `AMEND_INTENT`                                                            | required      | AC-31 strict — empty = exit 1                       |
| `AMEND_ALLOW_EMPTY`                                                                     | unset         | AC-31 bypass (logged)                               |
| `AMEND_NONINTERACTIVE`                                                                  | unset         | Skip TTY prompts in amend script                    |
| `AMEND_SCOPE_IMPACT` / `AMEND_ACS_AFFECTED` / `AMEND_ALTERNATIVES` / `AMEND_DECIDED_BY` | optional      | Structured amendment fields                         |
| `SPRINT_WIZARD_MODE`                                                                    | `interactive` | Set to `autopilot` for tooling-only sprints         |
| `SPRINT_BASE_BRANCH`                                                                    | `main`        | Coverage-delta + merge-base reference               |
| `REPO_ROOT`                                                                             | computed      | Launchd-safe override for `sprint-memory-decay.mjs` |

See [`_guides/bypass-cheatsheet.md`](./_guides/bypass-cheatsheet.md) for deeper rationale per env var.

---

## The 14-day flow (with worked example)

Let's walk through a real sprint: **"supplements compliance widget"**.

### Day 0 — Start

```bash
$ bash scripts/sprint-start.sh supplements-compliance

╔══════════════════════════════════════════════════════════════════════╗
║  Sprint started: supplements-compliance
╚══════════════════════════════════════════════════════════════════════╝

  Sprint dir: docs/sprints/supplements-compliance/
  State:      docs/sprints/supplements-compliance/state.json
  Branch:     sprint/supplements-compliance

  Next step: Claude will now invoke the sprint-spec-wizard skill.
  The wizard runs through 10 discovery sections (A-J) adaptively.
  Estimated time: 20-40 minutes.

  Ask Claude: "start the spec wizard" or "continue with §A".
```

Now ask me: _"start the spec wizard"_.

### Day 0 — Wizard (the most important part)

I'll do 4 things at the start of each section:

1. **Recall augmentation** — search memory for patterns relevant to your problem
2. **Codebase grep** — find existing files that might apply
3. **Ask questions** — adaptive to your prior answers
4. **Free-form refinement** — at the end of each section

Example exchange for §A:

```
Me: Starting §A — Problem & Vision.

I recalled 2 LifeOS patterns relevant to "supplements compliance":
  - lifeos-build-context (score 0.71): full MVP build status snapshot
  - lifeos-mvp-build-complete (score 0.58): MVP completion snapshot

Want me to apply these as defaults during §A, or skip and revisit per-question?

You: Apply them.

Me: A1 — In your own words, what's broken or missing today? Don't say
    "we should improve X" — say what specifically goes wrong, when, and
    for whom.

You: Users don't have a way to check off supplements they've taken today.
     They set up their stack at onboarding but never get reminded or see
     compliance %. We have the data model but no UI surface.

Me: A2 — Who suffers from this? Pick 1-2 personas: founder, early-user,
    onboarding-user, returning-user. For each, describe HOW this problem
    hits them in their day.

You: Mostly early users post-onboarding. They configured 5 supplements,
     forgot to take them on day 2, and we have no record because we never
     prompted them.

Me: A3 — Why now? What changed?

You: Zefyra noticed she stopped taking her stack after day 4 and that
     hurts the founding-user trust signal. Plus we have data infra in
     place; just need UI.

[... A4 through A5 ...]

Me: A6 (auto-injected because A1 mentioned an existing module):
    I see we have 8 LifeOS patterns about supplements — review and
    confirm any apply? Top 3 most relevant:
      - lifeos-rls-4-policy-template (will apply at §C)
      - frontend-hook-pattern (will apply at §E)
      - lifeos-soft-delete-pattern (will apply at §C)

You: All three.

Me: Refinement — anything else for §A? Edge cases, vision, tradeoffs?

You: We should also think about partial completion (took 3 of 5) — is
     that "compliant" or not?

Me: [records to sections_answers.A.refinement]
    Moving to §B — Business Logic.
```

After 3 sections (A → B → C), I'll run a **coherence check**:

```
Me: Coherence check after §C:

    You said in §A "we have the data model but no UI surface"
    but in §C you proposed a new `supplements_compliance_logs` table.

    Reconcile: do we have the data model already, or do we need new
    storage? (Options: (a) clarify here, (b) edit §A or §C, (c) accept
    apparent contradiction with rationale)

You: Edit §C — we have user_supplements table but compliance is
     computed on-the-fly from supplement_logs. No new table needed.

Me: [updates §C to "no schema change", re-evaluates skip conditions]
```

The wizard continues like this through §J. Total time: 20-40 min.

### Day ½ — Spec lock (4-way review)

After the wizard completes, I generate 4 outputs:

1. **Solution sketches** — 2-3 alternatives with tradeoffs (`solution-sketches.md`)
2. **Architect review** — separate agent reviews boundaries (`architect-review.md`)
3. **Security review** — separate agent reviews RLS/auth (`security-review.md`)
4. **Hive-mind consensus** — 5 workers vote "is this coherent?" (`consensus-spec.json`)

You read all 4, edit `spec.md` if needed, then:

```bash
$ bash scripts/sprint-amend-spec.sh --lock
[+] Spec locked. Drift baseline written.
```

From this moment forward:

- Every commit gets a drift score
- Every file edit is checked against `## Files touched`
- `git push` and `pulumi up` are forbidden until you finish the sprint

### Day 1-2 — SPARC design

Tell me: _"do the SPARC design phase"_. I'll run:

- `/sparc:spec-pseudocode` — Specification + Pseudocode → `design.md`
- `/sparc:architect` — Architecture + diagrams → `design.md`

You sign off → design lock.

### Day 3-11 — Build

This is where the swarm + autopilot side-cars do real work.

```bash
$ bash scripts/sprint-build-launch.sh
```

The `lifeos-sprint-build.yaml` workflow:

1. Initializes 8-agent `hierarchical-mesh` swarm
2. Grants claims (backend, frontend, database, types, tests, review, security, infra)
3. Spawns 3 autopilot side-cars (lint-fix, test-backfill, doc-sweep)
4. Opens ReasoningBank trajectory

I then execute per AC in `§I`:

- **Simple AC** → swarm TDD: red → green → refactor → review → commit
- **Complex AC** (auth/RLS/migration/JWT keyword) → automatic pair-programming DRIVER mode

Every commit runs `scripts/sprint-drift-check.sh`. If drift drops below 0.75:

```
╔══════════════════════════════════════════════════════════════════════╗
║  DRIFT DETECTED — sprint paused                                      ║
╚══════════════════════════════════════════════════════════════════════╝

  Sprint:    supplements-compliance
  Threshold: 0.75
  Score:     0.61   ← below threshold

  Commit message:
    refactor unrelated mealprep stage logic

  This commit semantically diverges from the spec's intent. Options:

  (a) AMEND SPEC to include this work
       bash scripts/sprint-amend-spec.sh

  (b) DISCARD this commit (drift was unintentional)
       git reset HEAD~ --soft

  (c) OVERRIDE ONCE (will be logged in retro)
       SPRINT_DRIFT_BYPASS=1 git commit
```

You pick one. The system logs the decision for retro.

### Day 5 — Mid-cycle check-in

```bash
$ bash scripts/sprint-checkin.sh

╔══════════════════════════════════════════════════════════════════════╗
║  Day-5 check-in: supplements-compliance
╚══════════════════════════════════════════════════════════════════════╝

  Hill chart: docs/sprints/supplements-compliance/hill-chart.md
  Check-in:   docs/sprints/supplements-compliance/check-in-day5.md
```

Tell me: _"walk me through the day-5 check-in"_. I update the hill chart from current AC states and ask:

1. Which ACs are over the hill (building, downhill)?
2. Which are stuck under the hill (still figuring out)?
3. Cut, push, or pivot?

If you cut: `bash scripts/sprint-amend-spec.sh --cut AC-3,AC-5`.

### Day 11-12 — Verify

```bash
$ ruflo workflow execute lifeos-sprint-verify \
    --input spec=docs/sprints/supplements-compliance/spec.md \
    --input slug=supplements-compliance
```

Chains: typecheck → lint → tests → `/api-contract-validation` → `/debug-rls` → `/module-status` → `performance_profile` → `aidefence_scan`.

Any failure pauses. Fix, re-run.

### Day 12 — Pre-deploy review

I spawn `reviewer` + `security-architect` agents for full diff review. You read, edit if needed, sign off.

### Day 13 — Deploy

```bash
$ ruflo workflow execute lifeos-deploy \
    --input branch=sprint/supplements-compliance \
    --input slug=supplements-compliance
```

The workflow runs until:

```
Step: pulumi-preview
  ✓ pulumi preview --stack Zuzuna54/dev

HUMAN GATE — review preview output, approve pulumi up

  [pulumi preview output above]

  Type 'proceed' to continue to `pulumi up`.
  Type 'abort' to halt the deploy.
```

You type `proceed`. Workflow continues: `pulumi up` → smoke test → `vercel deploy --prod`.

### Day 14 — Retro

```bash
$ bash scripts/sprint-end.sh supplements-compliance
```

Tell me: _"walk me through the retro"_. I:

1. Fill `retro.md` with worked/didn't/surprised based on session logs
2. Propose 3-5 reusable patterns; you approve each, I store via `ruflo memory store`
3. Propose CLAUDE.md updates if a new convention emerged
4. Batch DAA reviewer feedback (`scripts/sprint-daa-feedback.sh`)
5. Close trajectory
6. Compute velocity metrics (`scripts/sprint-velocity.mjs`)

```
Sprint velocity: supplements-compliance

Timing:
  Elapsed:                   13.2d (94% of appetite)
  Time to spec-lock:         8h
  Time to design-lock:       18h

ACs:
  Total:                     5
  Closed:                    5 (100%)
  Complex (pair-mode):       2

Drift:
  Total events:              12
  Below 0.75 (paused):       2
  Pause events:              2

Scope:
  Amendments:                1
  Files touched:             14

Success criteria (4 of 4):
  ✓ all_acs_closed
  ✓ within_appetite_14d
  ✓ low_drift_events
  ✓ time_to_design_lock_under_2d

Overall: ✓ SUCCESS
```

---

## What the system enforces automatically

### Pre-commit (husky)

Every `git commit` during an active sprint runs `scripts/sprint-drift-check.sh`:

1. Reads the spec's baseline embedding (set at spec-lock)
2. Embeds the commit's message + diff stat + sample of changed lines
3. Computes cosine similarity
4. **≥ 0.75** → logs score, commit proceeds
5. **< 0.75** → blocks commit, prompts you with 3 options (amend / discard / override)

Bypass: `SPRINT_DRIFT_BYPASS=1 git commit`.

### Pre-tool-use (Claude Code hooks)

Every Bash command I run is checked by `.claude/helpers/sprint-hook.cjs`:

- Blocked patterns: `git push`, `pulumi up`, `pulumi destroy`, `rm -rf /`, `DROP TABLE`, `DELETE FROM` (non-test)
- Bypass: `SPRINT_DRIFT_BYPASS=1`

Every Write/Edit/MultiEdit I do is checked:

- Path matched against spec's `## Files touched` list
- Always allowed: docs/, test files, CLAUDE.md, the sprint dir itself
- Out of scope → I have to ask you to amend spec or skip the edit

### GitHub PR opening

When you `gh pr create` on a `sprint/*` branch, `.github/workflows/sprint-pr-body.yml` fires and auto-fills the PR body with:

- Problem statement (from spec §A)
- Success vision (from spec §A)
- AC checklist with closed/open status
- Files in PR vs files in spec scope (warnings if drift)
- DoD checklist (LifeOS standard)
- Drift events summary

Reviewers know exactly what the sprint was supposed to do.

### Daemon side-cars during build phase

Three autopilot loops run alongside your work:

| Loop            | Trigger                              | What it does                                                 |
| --------------- | ------------------------------------ | ------------------------------------------------------------ |
| `lint-fix`      | manual / per AC commit               | Runs `pnpm lint:fix` on changed files, max 5 iterations      |
| `test-backfill` | paired with `testgaps` daemon worker | Generates Vitest/Supertest tests for uncovered Lambda routes |
| `doc-sweep`     | 5+ commits in same area within 2h    | Proposes (not auto-commits) CLAUDE.md + JSDoc updates        |

All 3 have `forbidden: [git push, pulumi up/destroy, rm -rf, DROP/DELETE]` and `permittedDomains` globs.

---

## Common workflows

### "I want to start working — what do I do?"

```bash
bash scripts/sprint-start.sh <slug>
# Then tell me: "start the spec wizard"
```

### "I'm halfway through the wizard and need to step away"

The wizard saves state after every answer. Just leave. When you come back:

```bash
node scripts/sprint-spec-wizard.mjs status <slug>
# Then tell me: "continue the wizard from §<X>"
```

### "I changed my mind about a wizard answer"

Tell me: `"redo §C"` — I clear that section and regenerate questions with current context (other answers + new memory).

### "I want to see what the spec looks like so far"

```bash
node scripts/sprint-wizard-assemble.mjs <slug> --partial --dry-run
```

Or tell me: `"show me the spec so far"`.

### "The drift check just blocked my commit but it was a legitimate change"

Three options:

1. **Amend spec** — the work IS in scope but spec didn't mention it: `bash scripts/sprint-amend-spec.sh` (opens editor, re-baselines drift on save)
2. **Discard commit** — the diff isn't what you wanted: `git reset HEAD~ --soft` (commit undone, changes still staged)
3. **Override once** — you have a good reason: `SPRINT_DRIFT_BYPASS=1 git commit` (logged for retro)

### "I need to touch a file outside the spec's scope"

Tell me, I'll run: `bash scripts/sprint-amend-spec.sh --add-file apps/web/hooks/useSomething.ts`. This adds the file to `## Files touched` + re-baselines drift.

### "Sprint is going off the rails — I want to abort cleanly"

```bash
bash scripts/sprint-pause.sh "going to revisit scope"
# come back later
bash scripts/sprint-resume.sh
```

Or to fully abandon:

```bash
bash scripts/sprint-end.sh <slug>
# In retro, note "aborted at day N for reason Y"
git checkout main  # leave the sprint branch behind
```

### "I'm stuck on a hard piece — invoke pair mode"

Tell me: `"engage pair-programming DRIVER mode for AC-3"`. I switch into pair mode (verification on every commit, truth score ≥0.95).

Or it triggers automatically when an AC has complexity keywords (auth/RLS/payment/migration/JWT/secret/delete/password/hash/encrypt).

### "I want to see the live dashboard"

```bash
node scripts/sprint-dashboard.mjs <slug> --open
```

Opens HTML at `docs/sprints/<slug>/dashboard.html` with hill chart, AC checklist, drift timeline, phase progression. Auto-refreshes every 60s.

### "I want a daily standup in my standup.md"

```bash
node scripts/sprint-standup.mjs
```

Appends today's entry: yesterday's commits, today's next AC, blockers (open questions + recent drift events). Or set up daemon's `document` worker to call this daily.

### "I want metrics on how my sprints are trending"

After each sprint:

```bash
node scripts/sprint-velocity.mjs <slug>
```

Look across `docs/sprints/*/metrics.json` for trends.

---

## File map — what lives where

```
docs/sprints/                              ← all sprint state
├── README.md                              ← architecture overview
├── USAGE.md                               ← this file
├── _template/spec.md                      ← canonical spec template
└── <slug>/                                ← per-sprint dir
    ├── spec.md                            ← THE source of truth
    ├── spec.partial.json                  ← wizard state (resumable)
    ├── wizard-transcript.md               ← full Q&A log
    ├── recalled-patterns.json             ← memory recalls + acceptance
    ├── .baseline-embedding.json           ← drift baseline
    ├── state.json                         ← phase, gates, drift, ACs
    ├── hill-chart.md                      ← Shape Up hill chart
    ├── check-in-day5.md                   ← mid-cycle check-in
    ├── design.md                          ← SPARC output
    ├── solution-sketches.md               ← Phase 1 alternatives
    ├── architect-review.md                ← Phase 1 architect agent
    ├── security-review.md                 ← Phase 1 security agent
    ├── consensus-spec.json                ← Phase 1 hive-mind result
    ├── standup.md                         ← daily auto-summary
    ├── retro.md                           ← end-of-sprint retro
    ├── metrics.json                       ← velocity + success criteria
    ├── daa-feedback.json                  ← DAA reviewer batched feedback
    └── dashboard.html                     ← local sprint dashboard

scripts/sprint-*.{sh,mjs}                  ← 18 scripts
.claude/skills/sprint-orchestrator/        ← protocol skill (the brain)
.claude/skills/sprint-spec-wizard/         ← wizard skill
.claude/skills/sprint-spec-wizard/sections/ ← 10 section fragments (A-J)
.claude/helpers/sprint-hook.cjs            ← PreToolUse enforcement
.claude/helpers/statusline-sprint.cjs     ← statusline fragment
.claude-flow/autopilot/*.json              ← 3 autopilot configs
docs/workflows/lifeos-*.yaml               ← 4 sprint workflows
.github/workflows/sprint-pr-body.yml       ← PR body auto-fill
.husky/pre-commit                          ← drift check wired here
```

---

## Configuration & environment

### Environment variables

```bash
# Sprint behavior
SPRINT_DRIFT_THRESHOLD=0.75    # default; lower = looser
SPRINT_DRIFT_BYPASS=1          # bypass drift check + scope check (emergency)

# Ruflo (per LifeOS conventions)
AWS_PROFILE=lifeos             # NOT default; LifeOS account is 816975651861
CLAUDE_FLOW_ENCRYPTION_KEY=<see .env.local>
```

### Adjusting the drift threshold

Default is 0.75 (industry baseline for paraphrase acceptance per 2026 research).

If you find false positives: try `SPRINT_DRIFT_THRESHOLD=0.65` (looser).
If you want stricter: `SPRINT_DRIFT_THRESHOLD=0.82` (paraphrase-tight).

Tune over the first 3 sprints based on actual drift event count.

### Adjusting complexity keywords (pair-mode trigger)

Edit `.claude/skills/sprint-spec-wizard/sections/I-acceptance.md` "Complex AC auto-detection" list. Currently:

```
auth, authentication, authorization, payment, billing, charge, RLS,
row-level, policy, migration, schema change, drop table, JWT, token,
secret, credential, key, delete, password, hash, encrypt, decrypt
```

### Daemon workers during sprint

Auto-paused at sprint-start (drift risk): `refactor`, `document`.
Auto-re-enabled at sprint-end.

Always-on: `audit`, `optimize`, `consolidate`, `testgaps`, `predict`, `map`.

---

## Troubleshooting

### "`timeout` command not found" on macOS

macOS doesn't ship the GNU `timeout` command. If you're wrapping our scripts with `timeout`, install `coreutils` (`brew install coreutils`) and use `gtimeout`, OR drop the wrapper — our scripts already have per-tool timeouts internally.

### "sprint-status.sh shows nothing but I started a sprint"

State file might be missing/corrupt. Check:

```bash
ls docs/sprints/<slug>/state.json
node -e "JSON.parse(require('fs').readFileSync('docs/sprints/<slug>/state.json'))"
```

If JSON is broken, fix it manually or:

```bash
rm -rf docs/sprints/<slug>
bash scripts/sprint-start.sh <slug>
```

### "Drift check fails with 'could not compute score'"

`sprint-drift-score.mjs` exits 2 on configuration error and the husky hook allows the commit. Check:

```bash
test -f docs/sprints/<slug>/.baseline-embedding.json
# If missing, you're pre-spec-lock — drift check skips correctly
# If present, check:
node scripts/sprint-drift-score.mjs docs/sprints/<slug>/.baseline-embedding.json /tmp/some-text-file
```

### "Hook blocks a legitimate `git push` outside any sprint"

Hooks only fire when `docs/sprints/<slug>/state.json` has `phase != "done"` and `phase != "paused"`. If no sprint is active, the hook returns 0 immediately.

If you're seeing a false-positive block, an old sprint may be stuck mid-phase. Run:

```bash
bash scripts/sprint-status.sh
# Identifies the active sprint
# Either: bash scripts/sprint-end.sh <slug>  # to close it
# Or:     bash scripts/sprint-pause.sh       # to suspend enforcement
```

### "Wizard skipped a section I wanted answered"

Skip rules come from `sections_answers.A.flags`. If those flags got set wrong, edit `spec.partial.json`:

```bash
# Open partial state
$EDITOR docs/sprints/<slug>/spec.partial.json
# Edit sections_answers.A.flags
# Then re-emit the section:
node scripts/sprint-spec-wizard.mjs section <slug> <X>
```

### "PR body auto-fill didn't run"

`.github/workflows/sprint-pr-body.yml` only runs when:

- Branch matches `sprint/*`
- `docs/sprints/<slug>/spec.md` exists

Check GH Actions tab. If workflow is disabled, enable it. Manual:

```bash
node scripts/sprint-pr-body.mjs <slug> --pr <number>
```

### "Daemon workers not running"

```bash
ruflo daemon status
# If "Stopped":
ruflo daemon start --workspace .
```

Currently 7 of 12 documented workers actually implement in v3.7.0-alpha.42 (build limitation). The rest fall back to manual invocation.

### "I can't get past spec-lock"

Hive-mind consensus may have failed. Check `docs/sprints/<slug>/consensus-spec.json`. If dissenting reasoning is there, address it and re-run:

```bash
# Edit spec.md based on dissent
# Then:
bash scripts/sprint-amend-spec.sh --lock
```

Or bypass the hive-mind step (less safe — solo dev judgment):

```bash
bash scripts/sprint-amend-spec.sh --lock
```

(`--lock` writes baseline + advances phase regardless of hive-mind state.)

---

## Multiple sprints in one workdir (parallel single-operator)

The original design assumed one sprint per machine. **2026-05-17 update:** the harness supports multiple parallel sprints in the same working directory.

**How it works (default 2026-05-17+):** `sprint-start.sh` stays on the current git branch. Multiple sprints can co-exist on the same branch. Sprint context is selected explicitly via `--slug` or `SPRINT_SLUG_OVERRIDE` env var. Branch-aware lookup is still available as a fallback for the legacy `sprint/<slug>` workflow.

**Parallel workflow (single branch — preferred):**

```bash
git switch main   # or whatever working branch
bash scripts/sprint-start.sh feature-a    # creates docs/sprints/feature-a, stays on branch
bash scripts/sprint-start.sh feature-b    # creates docs/sprints/feature-b, stays on branch

# Pick sprint context per command via --slug or env:
bash scripts/sprint-status.sh --slug feature-a
SPRINT_SLUG_OVERRIDE=feature-b bash scripts/sprint-amend-spec.sh --add-file <path>

# Per-terminal context (no branch switching needed):
# Terminal 1:  export SPRINT_SLUG_OVERRIDE=feature-a
# Terminal 2:  export SPRINT_SLUG_OVERRIDE=feature-b
# Each terminal's hooks now fire against its sprint
```

**Legacy workflow (branch-per-sprint — opt-in via `--with-branch`):**

```bash
bash scripts/sprint-start.sh feature-a --with-branch    # creates + checks out sprint/feature-a
git switch sprint/feature-b                              # if it exists
```

**Resolution order** (in `sprint-status.sh` + `.claude/helpers/sprint-hook.cjs`):

1. `--slug <name>` CLI arg (explicit, no fallback to session-file)
2. `SPRINT_SLUG_OVERRIDE=<slug>` env var (audit-logged to retro.json with ppid + tty + timestamp)
3. `~/.claude/sessions/<session-id>/sprint-slug` file — stale if `phase === "done"` → auto-cleaned + fall-through to step 4
4. Current git branch matches `sprint/<slug>` → use `<slug>` (legacy fallback)
5. **RETURN NULL** — no mtime fallback. Callers decide fallback behavior. This is by design (AC-2).

### Technical contracts (parallel-safety v2)

**atomic-state.sh** (`scripts/lib/atomic-state.sh`):

```bash
source scripts/lib/atomic-state.sh
atomic_update_state <slug> '<jq-filter-expression>'
```

Contract: acquires per-slug flock (10s timeout) → mktemp in same dir as state.json → jq filter → validate → atomic rename. Returns 0 on success, 1 on timeout/jq-error. Recovery: if state.json missing, `recover_state_from_bak <slug>` restores from `state.json.bak`.

**Lock directory** (`scripts/lib/lock-dir.sh`):

```bash
export LOCK_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache/lifeos/locks}"
mkdir -p "$LOCK_DIR"  # 0700, umask 077
```

Git operations are serialized via `$LOCK_DIR/git-index.lock`. Per-slug state locks use `$LOCK_DIR/state-<slug>.lock`.

**session-file.sh** (`scripts/lib/session-file.sh`):

```bash
source scripts/lib/session-file.sh
write_session_slug <session-id> <slug>   # atomic mkdir + write
rm_session_slug <session-id>             # cleanup on sprint end/done
get_session_slug <session-id>             # read, returns empty if absent
```

Pattern: `~/.claude/sessions/<session-id>/sprint-slug`. Atomic (no partial writes on concurrent reads).

**Migration claims** (`scripts/lib/session-file.sh`):

```bash
claim_migration <slug> <nnnn>            # mkdir .claims/<NNNN> atomically
release_migration <slug> <nnnn>          # rmdir .claims/<NNNN>
list_migrations <slug>                   # list held claims
```

Claim dirs: `docs/sprints/<slug>/.claims/<NNNN>`. Created atomically with `mkdir -p` (which is idempotent/atomic on POSIX). Used by build orchestrator to assign AC ranges to agents without collision.

**flock pattern** for git operations:

```bash
LOCK_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache/lifeos/locks}"
mkdir -p "$LOCK_DIR"  # 0700, umask 077
exec 9>"$LOCK_DIR/git-index.lock"
flock -w 30 9 || { echo "git lock timeout"; exit 1; }
# ... git operations ...
flock -u 9
```

**List all active sprints:**

```bash
$ bash scripts/sprint-status.sh --list
  feature-a    phase=building    branch=main
  feature-b    phase=spec-wizard branch=main
```

**Caveats:**

- Default behavior is stay-on-branch; use `--with-branch` for the legacy sprint/<slug> mode
- Daemon workers fire globally — outputs are per-sprint via slug argument
- Drift baseline + scope hook resolve via SPRINT_SLUG_OVERRIDE or current branch
- The "another sprint is active" hard block is removed; only "sprint with this slug already exists" still blocks
- Each sprint commit on the shared branch should reference the sprint slug in the message so retro can attribute correctly

---

## Inject-violation-catch-restore methodology

After sprint-system-100 over-claimed at 99/99 file-presence tests, every gate this directory ships is proven by injecting a known violation and observing the gate catch it. Use `scripts/sprint-inject-violation.sh` to run the standard pattern:

```bash
PROOF_FILE=docs/sprints/<slug>/proof/AC-N.md \
AC_ID=AC-N \
GATE_NAME="<gate name>" \
ASSERT_PATTERN="<output substring to match for caught>" \
  bash scripts/sprint-inject-violation.sh <fixture> "<gate command>"
```

Fixtures live in `scripts/violation-fixtures/`. The helper does:

1. Run gate on clean main (baseline)
2. `git apply` the fixture
3. Re-run gate, assert catch
4. `git apply -R` to restore
5. Write proof file

Exit 0 = gate caught the injection. Exit 1 = real bug in the gate.

**Two-verdict policy:** Production or Broken-with-followup-AC. No "Scaffolded" middle bucket. "File exists + script runs" is not Production.

## Real production findings caught by gates (2026-05-17 harness-full-coverage)

These survived as next-sprint TODOs because gates caught them on real code (not injected):

- **AC-11 bundle-budget**: ai-scheduler 5.20MB + auth 7.99MB over 5MB budget
- **AC-10 audit-deps**: 25 high + 1 critical CVE in transitive deps (after parser fix)
- **AC-62 deadcode-delete**: 34 knip-flagged unused files
- **AC-62 claude-md-check**: 9 stale CLAUDE.md references
- **AC-67 cross-pattern audit**: 7 memory patterns never recalled
- **AC-69 sprint-system-test**: 2 syntactic-test failures

## Worker integration (on-demand, sprint-protocol-driven)

> **Updated 2026-05-19.** ruflo daemon workers used to fire on hardcoded 10–30 min intervals (`worker-daemon.js` `DEFAULT_WORKERS`), burning ~9 h Sonnet/day silently against the operator's Claude Code OAuth subscription. Reports rotted in `.claude-flow/metrics/`; nothing read them. Now workers fire ONLY at known sprint-protocol checkpoints where their output is consumed by a gate or surfaced in a deliverable.

### How workers authenticate

Workers shell out to `claude --print` (line 862 of `headless-worker-executor.js`), which uses the operator's Claude Code OAuth session — NOT a separate API key. Every fire consumes the same Pro/Max subscription quota Claude Code uses for interactive work. In CI without OAuth, worker gates **hard-fail** with a clear message; sprint-verify must run locally before pushing.

### Mapping — worker × sprint stage

| Sprint stage                        | Worker(s)                                                                                                                                             | Trigger                                    | Gate                                                                    |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ----------------------------------------------------------------------- |
| Day 0 — `sprint-start.sh`           | `map` (local, free)                                                                                                                                   | automatic at sprint start                  | advisory                                                                |
| Day 1–2 — `sprint-design-lock.sh`   | `ultralearn` (opus) IFF `spec.partial.json §B.flags.architecture==true`; `deepdive` (opus) IFF any AC has complexity keyword (auth/RLS/migration/JWT) | automatic at design-lock                   | advisory; feeds design.md                                               |
| Per-wave kickoff during build       | `predict` (haiku)                                                                                                                                     | `bash scripts/sprint-wave-start.sh <wave>` | advisory; preload hints                                                 |
| Day 5 — `sprint-checkin.sh`         | `consolidate` (local, free)                                                                                                                           | automatic at check-in                      | free; memory dedup                                                      |
| Day 11 — `sprint-cleanup-launch.sh` | `refactor` (sonnet) IFF spec mentions "refactor"                                                                                                      | automatic during cleanup                   | advisory                                                                |
| Day 11–12 — `sprint-verify.sh`      | `audit` (sonnet, **BLOCKING any finding**) + `testgaps` (sonnet, **BLOCKING files-touched untested**) + `optimize` (sonnet, advisory)                 | `bash scripts/sprint-verify.sh`            | audit + testgaps fail the gate                                          |
| Day 14 — `sprint-end.sh`            | `document` (sonnet) + `consolidate` (local)                                                                                                           | automatic at sprint-end                    | document proposals appended to `retro.md §"CLAUDE.md updates proposed"` |

### Per-sprint outputs

Each worker writes to `docs/sprints/<slug>/worker-output/<worker>.{json,md}` (committed to git per Q7 — audit trail). The default `.claude-flow/metrics/<basename>.json` location is also written but git-ignored.

### Verify gate behavior (Day 11–12)

Run `bash scripts/sprint-verify.sh` from the sprint dir. It:

1. Runs the existing `typecheck → lint → tests` chain (skippable via `--workers-only`).
2. Fires `audit + testgaps + optimize` in parallel.
3. Polls `.claude-flow/metrics/*.json` for output (10 min timeout per worker).
4. Copies outputs to `docs/sprints/<slug>/worker-output/`.
5. Runs gates: **audit blocks on ANY finding** (zero-tolerance per spec audit Q2); **testgaps blocks on any route in `## Files touched` with zero coverage**; **optimize advisory only**.
6. Records the run to `state.json.verify_runs[]`.

Local sprint-test-hardening.mjs still runs as a free, deterministic file-scan supplement — testgaps is the LLM-backed gate on top of it.

### Worker invocation cost model

Per 14-day sprint:

- Day 0: map (local, free)
- Day 1–2: deepdive/ultralearn only on complex sprints (~10–15 min opus)
- Build waves: predict per wave (~20 s haiku each × ~5 waves)
- Day 5: consolidate (local, free)
- Day 11: refactor only on refactor-flagged sprints (~5 min sonnet)
- Day 11–12: audit + testgaps + optimize (~30 min sonnet total)
- Day 14: document + consolidate (~5 min sonnet)

**Total: ~50 min Sonnet per sprint** vs the previous ~126 h Sonnet over 14 days of scheduled workers — **>99 % reduction**.

### Daemon state

Run `ruflo daemon status` — expect `RUNNING (background)` with `Workers Enabled: 0`. The daemon stays warm so `ruflo daemon trigger -w <worker>` is fast; no worker fires on its own schedule.

To re-enable a scheduled worker (NOT recommended): `ruflo daemon enable -w <worker>`. To disable one: `ruflo daemon enable -w <worker> --disable`.

### 2026-05-19 audit fixes — ruflo CLI drift caught

| Fix                          | File:line                                                               | Bug                                                                                                                                            |
| ---------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Variadic atomic_update_state | `scripts/lib/atomic-state.sh:55`                                        | Didn't forward `--arg`/`--argjson` to jq → broke 11+ callers (drift-check, amend-spec, hive-mind, pre-merge-gate, start, cleanup-launch, etc.) |
| hive-mind consensus action   | `scripts/sprint-hive-mind-spec-lock.sh:84`                              | `-a submit` invalid (CLI errors with "Must be one of: propose, vote, status, list") → `-a propose`                                             |
| embeddings subcommand        | `scripts/sprint-drift-score.mjs:46` + `scripts/sprint-rebaseline.sh:99` | `embeddings encode --text` doesn't exist → `embeddings generate -t -o json`                                                                    |
| neural train flag echo       | `scripts/sprint-end.sh:307`                                             | Echoed `neural train --type coordination --epochs 50` (wrong flags) → `-p coordination -e 50`                                                  |

Reported-as-broken items that were actually already-working:

- `hive-mind spawn`: file uses `-n 4 -r specialist` (already migrated off deprecated `--queen X --workers N`)
- `sprint-daa-feedback.sh:37`: uses valid `ruflo agent list --all -t reviewer` (not deprecated `daa list`)
- `sprint-train.sh:72`: uses valid `neural train -p coordination -e 50 --learning-rate 0.001`
- `run-workflow.sh:115`: `ruflo swarm init --topology hierarchical-mesh --max-agents 8` IS still valid (swarm namespace not removed)

Methodology: every ruflo call validated against `ruflo <cmd> --help` actual output; behavior-audit agent invoked top-20 scripts against the paused harness-parallel-safety-v2 sprint to verify against docstring claims.

---

## What this system does NOT do

Honest scope limits:

- **Does not write LifeOS code itself.** During build phase, Claude delegates to coder/tester/architect agents. The orchestrator is the protocol; agents do the work.
- **Does not deploy without your approval.** Even when fully automated, the deploy workflow ALWAYS pauses at `pulumi preview` for human review.
- **Does not push to main.** PR flow only. `git push` is hook-blocked during sprint.
- **Does not run during sprint:** daemon's `refactor` and `document` workers (drift risk). They're paused at sprint-start, re-enabled at sprint-end.
- **Does not auto-update CLAUDE.md.** Doc-sweep autopilot PROPOSES changes; you approve before commit.
- **Does not enforce drift during wizard phase.** Drift baseline doesn't exist until spec-lock.
- **Does not work without git.** Sprint branches + state.json are git-tracked. Bare directory won't work.
- **Does not work offline forever.** Memory recall + DAA + neural training need ruflo daemon running.

---

## Maintenance habits

### After every sprint

- Review retro.md, ensure 3-5 patterns extracted to memory
- Check CLAUDE.md proposals; commit if pattern is repo-wide
- Look at metrics.json — any criterion failing? what changed?

### Weekly (Sundays, ~10 min)

- `ruflo memory` — review consolidation suggestions
- `cat .claude-flow/security/*.json | jq .` — check audit findings
- `ruflo verify` — supply-chain integrity

### Monthly

- Review `docs/sprints/*/metrics.json` for trends (drift count over time, time-to-design-lock trending?)
- Prune stale memory entries via `mcp__claude-flow__agentdb_hierarchical-delete`
- If you've done 20+ sprints: `bash scripts/sprint-train.sh --force`

### When something's wrong

- Re-read `docs/sprints/README.md` for architecture
- Re-read this file (USAGE.md) for procedure
- Check `~/.claude/plans/hazy-gathering-kettle.md` for the design rationale
- Read individual SKILL.md files for what each component does

---

## Mini cookbook — copy-paste recipes

### Recipe: First sprint, never used the system before

```bash
# 1. Verify install
bash scripts/setup-ruflo.sh

# 2. Make sure daemon is up
ruflo daemon status   # if stopped: ruflo daemon start --workspace .

# 3. Start sprint
bash scripts/sprint-start.sh first-sprint-test

# 4. Tell Claude: "start the spec wizard"
#    Pick a SMALL real feature (e.g., "add typing indicator to chat")
#    Run through wizard fully (~20-40 min)

# 5. After wizard, tell Claude: "do the spec-lock review chain"
#    Review the 4 outputs

# 6. Sign off, then:
bash scripts/sprint-amend-spec.sh --lock

# 7. Tell Claude: "do the SPARC design phase"

# 8. After design lock:
bash scripts/sprint-build-launch.sh

# 9. ... build happens, you intervene at drift pauses ...

# 10. Day 5:
bash scripts/sprint-checkin.sh

# 11. Day 11-12: tell Claude "verify the sprint"

# 12. Day 12: tell Claude "pre-deploy review"

# 13. Day 13: tell Claude "deploy"
#     Workflow pauses at pulumi preview; you say "proceed"

# 14. Day 14:
bash scripts/sprint-end.sh first-sprint-test
#     Tell Claude "walk me through the retro"
```

### Recipe: Resume a sprint after a few days off

```bash
bash scripts/sprint-status.sh
# Reports current phase

node scripts/sprint-dashboard.mjs <slug> --open
# Visual catch-up: hill chart, ACs, drift events

cat docs/sprints/<slug>/standup.md | tail -50
# Recent days' standup entries

# Then tell Claude:
#   "give me a 2-minute brief on where we are with <slug>"
```

### Recipe: Quick sprint (backend-only refactor, 3 days, not 14)

```bash
# Start as usual
bash scripts/sprint-start.sh backend-refactor

# Tell Claude: "start the spec wizard. This is a backend-only refactor,
#               no UI change, no schema change, just internal cleanup.
#               Appetite 3 days."

# Wizard will skip §C (no schema), §E §F §G (no UI), and ask shorter
# question sets per section. ~10-15 minutes total.

# Proceed normally through the rest. The protocol doesn't change shape,
# just compresses.
```

### Recipe: Multiple concurrent attempts (worktree per sprint)

```bash
# Sprint A in main worktree
bash scripts/sprint-start.sh feature-a

# Sprint B in a worktree (no enforcement collision)
git worktree add ../lifeos-b sprint/feature-b
cd ../lifeos-b
bash scripts/sprint-start.sh feature-b --no-branch  # branch already exists

# Note: the sprint system currently assumes ONE active sprint per worktree.
# Each worktree's docs/sprints/<slug>/state.json is independent.
```

---

## Quick reference card

```
START         bash scripts/sprint-start.sh <slug>
STATUS        bash scripts/sprint-status.sh
PAUSE         bash scripts/sprint-pause.sh "reason"
RESUME        bash scripts/sprint-resume.sh
AMEND         bash scripts/sprint-amend-spec.sh
              bash scripts/sprint-amend-spec.sh --lock          # spec-lock gate
              bash scripts/sprint-amend-spec.sh --cut AC-3      # cut AC
              bash scripts/sprint-amend-spec.sh --add-file <p>  # widen scope
CHECK-IN      bash scripts/sprint-checkin.sh
END           bash scripts/sprint-end.sh <slug>

WIZARD        node scripts/sprint-spec-wizard.mjs status <slug>
              node scripts/sprint-spec-wizard.mjs section <slug> A
              node scripts/sprint-spec-wizard.mjs assemble <slug>

HILL CHART    node scripts/sprint-hillchart.mjs <slug> --refresh
PAIR CHECK    node scripts/sprint-pair-check.mjs <slug>
DASHBOARD     node scripts/sprint-dashboard.mjs <slug> --open
STANDUP       node scripts/sprint-standup.mjs <slug>
PR BODY       node scripts/sprint-pr-body.mjs <slug>
VELOCITY      node scripts/sprint-velocity.mjs <slug>
GH PROJECT    bash scripts/sprint-gh-project-sync.sh

NEURAL        bash scripts/sprint-train.sh                 # gated
              bash scripts/sprint-train.sh --force         # force
DAA           bash scripts/sprint-daa-feedback.sh

BYPASS DRIFT  SPRINT_DRIFT_BYPASS=1 git commit ...

TALK TO ME    "start a sprint for <X>"
              "show me the spec so far"
              "redo §C"
              "walk me through the day-5 check-in"
              "engage pair mode for AC-3"
              "deploy"
              "walk me through the retro"
```

---

## Where to go next

- [`README.md`](./README.md) — architecture overview, dir layout
- [`_template/spec.md`](./_template/spec.md) — the canonical spec template
- [`../../.claude/skills/sprint-orchestrator/SKILL.md`](../../.claude/skills/sprint-orchestrator/SKILL.md) — the 14-day protocol Claude follows
- [`../../.claude/skills/sprint-spec-wizard/SKILL.md`](../../.claude/skills/sprint-spec-wizard/SKILL.md) — the adaptive wizard
- [`../../.claude/skills/sprint-spec-wizard/sections/`](../../.claude/skills/sprint-spec-wizard/sections/) — per-section question banks
- [`../ruflo-sessions/ruflo-for-lifeos.md`](../ruflo-sessions/ruflo-for-lifeos.md) — full ruflo feature map
- [`~/.claude/plans/hazy-gathering-kettle.md`](file:///Users/gio/.claude/plans/hazy-gathering-kettle.md) — original design plan with 36 captured decisions

---

**Last refreshed:** 2026-05-17

If something in this guide is wrong, the source of truth is the SKILL.md files and the plan doc. PRs welcome.
