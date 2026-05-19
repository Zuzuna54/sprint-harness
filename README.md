# @ordex/sprint-harness

> Shape Up + SPARC sprint harness with deterministic phase enforcement, unified review-resolution, drift control, inject-violation-catch-restore methodology, multi-sprint parallel support, and full Claude Code + ruflo integration.

**v0.7.3** — 13-phase manifest with mechanical predicate enforcement; audit + knip + sonar review-resolution phase; per-slug advance mutex; deterministic spec-lock consensus replacing broken upstream ruflo CLI; wizard state-sync to `state.json`.

Drop-in 14-day sprint protocol for any TypeScript/Node project.

---

## At a glance — what makes this different

- **Phases are mechanical, not aspirational.** `scripts/lib/phase-manifest.json` declares 13 phases × 72 sub-step gates × 0 deferred. `scripts/sprint-advance-phase.sh` is the sole sanctioned writer of `state.phase` — every other phase-writer delegates to it. The PreToolUse hook blocks all other paths (jq inline writes, sed redirects, python/awk/perl mutations, rm/mv of state.json).
- **One bypass UX, ≥10 char rationale required.** `SPRINT_BYPASS_GATE=<gate> SPRINT_BYPASS_WHY='<reason>'`. Works for sub-step gates AND daemon worker names (since v0.7.3). All 9 legacy `SPRINT_*_BYPASS=1` envs auto-translate with a stderr deprecation warning. Removal in v0.8.0.
- **Inject-violation-catch-restore** — every capability shipping here is proven by a real injected fixture, not file presence.
- **Multi-sprint parallel-safe** — session-file resolution chain, atomic `state.json` writes (flock when available, portable `set -C` noclobber fallback for macOS), per-slug `.advance.lock` mutex, `XDG_RUNTIME_DIR` lock dir for git index serialization.
- **Two-verdict policy** — Production OR Broken-with-followup-AC. No "Scaffolded" middle bucket.

---

## Install

```bash
npx @ordex/sprint-harness install
```

This will:

1. Detect existing husky / `.claude/settings.json` / `docs/sprints/` — merge, never overwrite
2. Copy `scripts/sprint-*` to `<target>/scripts/`
3. Copy 5 workflow YAMLs to `<target>/docs/workflows/`
4. Copy sprint-orchestrator + sprint-spec-wizard skills to `<target>/.claude/skills/`
5. Append PreToolUse hooks to `<target>/.claude/settings.json` (Bash forbidden + Edit scope + WebSearch PII redact)
6. Install husky hooks (drift-check, dup-check, reuse-audit, review-gate, DAA dispatch)
7. Scaffold `docs/sprints/{README,USAGE,DEVELOPER,QUICKSTART,SCRIPTS}.md`
8. Write `<target>/.sprintrc.json` with brand config you choose during install
9. Verify dependencies (ruflo, jq, gh, pnpm/npm, optional: sonar-scanner, docker)

## Quick start (after install)

```bash
bash scripts/sprint-start.sh first-sprint --no-issue
# tell Claude: "start the spec wizard"
```

See `docs/sprints/QUICKSTART.md` (installed into your repo) for the 5-minute walkthrough.

---

## The 13-phase state machine

| #   | Phase                | Day      | Operator action                              | Required artifacts + gates                                                                                  |
| --- | -------------------- | -------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| 1   | `spec-wizard`        | 0        | `sprint-start.sh <slug>` + tell Claude wizard| `spec.md` ≥500B, `wizard-transcript.md`, 14 wizard sub-step gates                                          |
| 2   | `spec-locked`        | ½        | spec-lock 4-way review                       | `solution-sketches.md`, `architect-review.md`, `security-review.md`, `consensus-spec.json` (verdict ∈ pass/pass-with-notes), `.baseline-embedding.json` |
| 3   | `design-locked`      | 1–2      | SPARC design                                 | `design.md` ≥300B, `state.design_locked_at`                                                                |
| 4   | `building`           | 3–11     | `sprint-build-launch.sh` + TDD swarm         | `build-launched` gate, drift score per commit, hooks active                                                |
| 5   | `day-5-checkin`      | 5        | `sprint-checkin.sh` + Cut/Push/Pivot         | `check-in-day5.md` with ≥30 chars under each H3, `hill-chart.md`                                          |
| 6   | `cleaning`           | 11       | `sprint-cleanup-launch.sh`                   | deadcode + lint + claude-md cleanup sub-step gates                                                         |
| 7   | `verifying`          | 11–12    | `sprint-verify.sh`                           | 18 verify sub-step gates + daemon workers (audit + testgaps BLOCKING, optimize advisory)                  |
| 8   | `audit-resolution`   | 12–13    | `sprint-audit-resolve.sh` (legacy v0.7.2)    | _Legacy alias_ — superseded by `review-resolution` (kept for back-compat)                                  |
| 9   | `review-resolution`  | 12–13    | `sprint-review-resolve.sh` _(v0.7.3)_        | `review-resolutions.md` ≥1KB, `review_resolution_complete` predicate (audit + knip + sonar union)        |
| 10  | `pre-deploy`         | 13       | reviewer + security-architect sub-agents     | `pre-deploy-review.md` ≥200B, `state.predeploy_at`                                                         |
| 11  | `deploying`          | 13–14    | `sprint-deploy.sh`                           | 5 deploy gates (pulumi preview/up, human gate, smoke, vercel)                                              |
| 12  | `done`               | 14       | `sprint-end.sh`                              | `retro.md` (6 H2 headings + ≥3 patterns), `metrics.json`, `dashboard.html`, 11 retro gates                |
| 13  | `paused`             | anywhere | `sprint-pause.sh` / `sprint-resume.sh`       | `state.prev_phase` set                                                                                     |

---

## Review-resolution (v0.7.3 — supersedes audit-resolution)

Three producer streams under one phase, one walker, one exit predicate.

```text
verifying phase entry
├── audit worker fires    → worker-output/audit.json    (security + correctness, scope-bounded)
├── knip --check --json   → worker-output/knip.json     (dead-code)
└── sonar --json          → worker-output/sonar.json    (code quality; vacuous PASS when token absent)
            ↓
sprint-review-resolve.sh aggregates findings into state.review_findings[] with global HAR-N namespace
            ↓
operator Fix / Defer / Accept per finding (producer-agnostic)
            ↓
exit predicate review_resolution_complete: resolved + deferred + accepted == total ✓
            ↓
pre-deploy phase
```

**Back-compat**: `audit-resolution` phase + `audit_resolution_complete` predicate retained as legacy aliases. The new predicate transparently consumes legacy `audit_findings_*` fields via union jq, so v0.7.2 sprints walk through it without amending state.json.

**Producers**:

| Producer | Source                                                | Severity                          | Vacuous PASS condition                |
| -------- | ----------------------------------------------------- | --------------------------------- | ------------------------------------- |
| audit    | `ruflo daemon trigger -w audit` (env-stripped, C6)    | critical / high / medium / low    | 0 in-scope findings post scope-filter |
| knip     | `node scripts/sprint-deadcode-delete.mjs --check --json` | medium (advisory)               | 0 unused files outside sprint scope   |
| sonar    | `node scripts/sprint-sonar-parse.mjs --json`          | BLOCKER+CRITICAL → high, MAJOR → medium, MINOR+INFO → low | SONAR_TOKEN absent                |

---

## Spec-lock consensus (v0.7.3 — replaces broken ruflo hive-mind CLI)

`scripts/sprint-consensus-deterministic.sh` runs 5 heuristic checks against `spec.md`:

| Vote | Check                       | Threshold                                                |
| ---- | --------------------------- | -------------------------------------------------------- |
| 1    | AC-N reference count        | 3–100                                                    |
| 2    | §H Integration Points       | ≥1 bullet entry                                          |
| 3    | No unresolved markers       | zero TODO / FIXME / TBD / XXX / TKTK                     |
| 4    | §J Risks section            | ≥100 chars of content                                    |
| 5    | Verification mentions       | ≥2 of Verify / Verification / Given/When/Then / Manual QA |

Tally: ≥4/5 = `pass`, 3/5 = `pass-with-notes`, ≤2/5 = `dissent` (blocks spec-lock). Emits `consensus-spec.json` with the same `{verdict, outcome}` shape the phase-manifest predicate expects. Runs in <1s, no daemon dependency.

`sprint-hive-mind-spec-lock.sh` defaults to this path. Escape hatch for the day ruflo upstream is fixed: `RUFLO_CONSENSUS_USE_BROKEN_CLI=1`.

---

## Worker scope (v0.7.2+, retained in v0.7.3)

`audit` and `testgaps` workers post-filter findings against `state.files_touched[]` at gate-eval time (mirrors the `gate_testgaps_blocks` reference pattern). Out-of-scope findings logged as `[OUT/<severity>]` advisory; in-scope findings still block (zero-tolerance preserved within scope).

Declared in `scripts/lib/phase-workers.json::worker_scope` per phase per worker. Three strategies: `files-touched` (post-filter, only mode implemented), `repo` (default for back-compat), `spec-h1` (placeholder for env-var / prompt-inject delivery).

---

## Architecture (3 layers + state)

```text
┌──────────────────────────────────────────────────────────┐
│  LAYER 1 — Skills (.claude/skills/)                      │
│  • sprint-orchestrator/SKILL.md   ← THE 14-day protocol  │
│  • sprint-spec-wizard/SKILL.md    ← adaptive wizard      │
│  • sprint-spec-wizard/sections/   ← 10 section banks     │
└─────────────┬────────────────────────────────────────────┘
              │ Claude invokes scripts per protocol
              ▼
┌──────────────────────────────────────────────────────────┐
│  LAYER 2 — Scripts (scripts/sprint-*.{sh,mjs})           │
│  • Phase mutator (sprint-advance-phase.sh — SOLE writer) │
│  • State machine (sprint-start/status/end/pause/resume)  │
│  • Wizard (sprint-spec-wizard + 4 helpers, state-sync v0.7.3) │
│  • Drift detection (sprint-drift-check + sprint-drift-score) │
│  • Phase scripts (build-launch/checkin/cleanup/verify)   │
│  • Review-resolution (sprint-review-resolve/-rerun, v0.7.3) │
│  • Deterministic consensus (sprint-consensus-deterministic, v0.7.3) │
│  • Predicates + worker triggers + worker gates           │
│  • QA tools (sonar-parse / deadcode-delete / migration-check / cycle-check / audit-deps / bundle-budget / coverage-delta / perf-check) │
│  • Replay validator (sprint-replay-validator.mjs)        │
│  • Inject-violation helper + fixtures                    │
└─────────────┬────────────────────────────────────────────┘
              │ Scripts read/write state + invoke hooks
              ▼
┌──────────────────────────────────────────────────────────┐
│  LAYER 3 — Hooks (Claude Code + husky)                   │
│  • .claude/helpers/sprint-hook.cjs   ← PreToolUse        │
│  • .claude/helpers/websearch-pii-redact.cjs              │
│  • .husky/pre-commit  ← drift + dup BLOCK                │
│  • .husky/post-commit ← pair-mode + reuse audit          │
│  • .husky/pre-push    ← review-gate                      │
│  • .husky/post-merge  ← DAA feedback queue               │
└─────────────┬────────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────┐
│  STATE — docs/sprints/<slug>/                            │
│  • state.json          (canonical; only writer: advance-phase) │
│  • spec.md / spec.partial.json                           │
│  • design.md / architect-review.md / security-review.md  │
│  • consensus-spec.json (verdict ∈ pass / pass-with-notes / dissent) │
│  • check-in-day5.md / hill-chart.md                      │
│  • worker-output/{audit,testgaps,optimize,knip,sonar}.json │
│  • review-resolutions.md (v0.7.3)                        │
│  • retro.md (6 H2 headings + ≥3 patterns)                │
│  • metrics.json / dashboard.html                         │
│  • proof/ (inject-violation-catch-restore evidence)      │
│  • .advance.lock (per-slug mutex, v0.7.3)                │
└──────────────────────────────────────────────────────────┘
```

---

## Methodology — Inject-violation-catch-restore

After early sprints over-claimed at 99/99 file-presence tests, every capability shipping here is proven by:

1. Run gate against clean main (baseline)
2. `git apply` a known-violation fixture
3. Re-run gate; assert it CATCHES the violation
4. `git apply -R` to restore
5. Write proof markdown documenting all three

The `scripts/sprint-inject-violation.sh` helper is the standard runner. Fixtures live in `scripts/violation-fixtures/`.

---

## What problems this solves

| Without sprint harness                       | With sprint harness                                       |
| -------------------------------------------- | --------------------------------------------------------- |
| "Hey Claude, build X" → ad-hoc work          | Structured 14-day cycle with deterministic phases         |
| Scope drifts during build                    | Drift score on every commit; hard pause below 0.75        |
| Claude edits files outside the intended scope| PreToolUse hook blocks out-of-scope edits                 |
| Phase advance with missing requirements      | `phase-manifest.json` predicates BLOCK advance + bypass UX|
| Audit findings noise from unrelated files    | Scope-bounded workers post-filter against `files_touched`|
| audit / knip / sonar each ignored separately | Unified `review-resolution` phase, one walker, one exit   |
| Broken upstream consensus CLI silently passes| Deterministic 5-vote heuristic (v0.7.3)                  |
| State.json races under concurrent advances   | Per-slug `.advance.lock` mutex (v0.7.3)                   |
| Wizard state never reaches state.json        | `syncWizardStateToStateJson` on every section (v0.7.3)   |
| No record of why a decision was made         | Wizard transcript + recalled patterns + retro             |
| Building the same thing twice in 3 months    | Memory recall surfaces prior patterns at spec time        |
| Push to main by accident                     | Husky hook blocks `git push` during sprint                |
| Lost track of what's done                    | Hill chart + dashboard + GitHub PR auto-fill              |
| Patterns never re-used                       | Retro extracts 3-5 patterns → stored to ruflo memory      |
| "Did the gate catch the bug?" → guessing     | Inject-violation-catch-restore proof per AC               |

---

## Exemplar sprints (under `sprints/`)

Closed sprints that built this harness. Walk-through evidence with full spec / design / retro / proof artifacts.

| Slug                                        | Closes        | Topic                                                                  |
| ------------------------------------------- | ------------- | ---------------------------------------------------------------------- |
| `audit-driven-fidelity-v1`                  | pre-v0.7      | Early audit-as-fidelity pattern (predecessor to scope-bounded audit)   |
| `harness-deterministic-phases-v1`           | v0.7.0        | Phase manifest + advance-phase + hook chokepoint + single bypass UX    |
| `harness-deterministic-phases-v1-closure`   | v0.7.0 closure| 53 leftover items from the deterministic-phases sprint                 |
| `harness-truthful-docs-and-wiring-v1`       | v0.7.1        | Wired the 43 deferred gates + state.json race fix + worker wiring      |
| `harness-audit-resolution-and-scope-v1`     | v0.7.2        | audit-resolution phase + scope-bounded workers + HAR-1..10 fixes       |
| `harness-review-resolution-v1`              | v0.7.3        | Unified review-resolution (audit + knip + sonar) + 4 follow-ups inline |
| `w2-smoke-fixture`                          | (test)        | Test fixture for W2 worker-recording smoke                             |

Each sprint dir contains: `spec.md`, `architect-review.md`, `security-review.md`, `consensus-spec.json`, `design.md`, `state.json`, `retro.md`, `worker-output/`, and `proof/` (inject-violation evidence).

---

## Configuration (`.sprintrc.json` in your target repo)

```json
{
  "brand": "MyProduct",
  "codebaseIdentifier": "myproduct",
  "memoryNamespace": "myproduct",
  "gitHubOrg": "your-username",
  "awsProfile": null,
  "supabaseAssumptions": false,
  "packageManager": "pnpm",
  "deployTarget": null,
  "customizations": {}
}
```

The installer prompts for these at first install. Edit anytime to re-customize.

---

## Documentation

| Doc                                                                  | Lives at (after install)                  | Audience                  |
| -------------------------------------------------------------------- | ----------------------------------------- | ------------------------- |
| Quick start (5-min)                                                  | `docs/sprints/QUICKSTART.md`              | First-time users          |
| Full usage guide (14-day flow, phase enforcement, worker arch, bypass, troubleshooting) | `docs/sprints/USAGE.md` | All users    |
| Developer guide (terminology contract, extension recipes, state.json schema) | `docs/sprints/DEVELOPER.md`       | Extending the system      |
| Script reference (canonical inventory of every harness script)       | `docs/sprints/SCRIPTS.md`                 | Operators                 |
| Capability catalog                                                   | `docs/sprints/_index/capabilities.md`     | Cross-sprint reference    |
| Bypass cheatsheet                                                    | `docs/sprints/_guides/bypass-cheatsheet.md` | Escape hatches          |
| Sub-step coverage map                                                | `docs/sprints/_guides/sub-step-coverage.md` | Gate enforcement detail |
| Troubleshooting                                                      | `docs/sprints/_guides/troubleshooting.md` | Symptom-indexed lookup    |
| Resolution templates                                                 | `docs/sprints/_templates/{review,audit}-resolutions.md` | Finding triage         |

In this repo, the canonical scaffold lives at `lib/templates/sprints/` (mirrored on every release).

---

## Version history

See [CHANGELOG.md](./CHANGELOG.md). Highlights:

- **v0.7.3** (2026-05-19) — review-resolution phase (audit + knip + sonar unified) + deterministic spec-lock consensus + per-slug advance mutex + wizard state-sync.
- **v0.7.2** (2026-05-19) — audit-resolution phase + scope-bounded workers + AES-256-GCM at-rest encryption for `.claude/helpers/{memory,session}.js`.
- **v0.7.1** (2026-05-19) — wired the 43 deferred gates + state.json race fix + worker wiring.
- **v0.7.0** (2026-05-19) — deterministic phase enforcement + manifest + hook chokepoint + single bypass UX.
- **v0.6.0** — on-demand daemon workers (cuts ~9h/day silent Sonnet burn to ~50min per sprint).

---

## Provenance

Extracted from the LifeOS (codebase identifier) / Ordex (product brand) internal codebase. Developed across 7 closed harness sprints (now living under `sprints/` in this repo as walk-through exemplars) and proven against 100+ acceptance criteria via inject-violation-catch-restore. See [HISTORY.md](./docs/HISTORY.md) for the original audit trail.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). PRs welcome at the SKILL.md and section markdown level (highest ROI per change). Lower layers (scripts, hooks) require more care + an inject-catch-restore proof.

## License

MIT — see [LICENSE](./LICENSE).
