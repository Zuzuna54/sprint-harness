# @ordex/sprint-harness

> Shape Up + SPARC sprint harness with drift control, inject-violation-catch-restore methodology, multi-sprint parallel support, and full Claude Code + ruflo integration.

Drop-in 14-day sprint protocol for any TypeScript/Node project. Brings:

- **Adaptive spec wizard** (10 sections, memory-recall augmented, branching by sprint type)
- **Drift control** (cosine-similarity baseline, blocks off-topic commits, scope hook)
- **5 workflow YAMLs** (build / verify / cleanup / deploy / retro) with `cmd` + `type:skill` + `type:mcp` dispatch
- **Inject-violation-catch-restore methodology** — every capability proven via real injection, not file presence
- **Hooks** — husky pre-commit / post-commit / pre-push / post-merge + Claude Code PreToolUse (Bash, Edit, WebSearch)
- **Multi-sprint parallel-safe** — session-file resolution chain v2, atomic `state.json` writes (`flock` + `mktemp` same-FS + `.bak` recovery), `XDG_RUNTIME_DIR` lock dir for git index serialization
- **GitHub integration** — PR body auto-fill, rebase-check warnings, Project board sync
- **On-demand daemon workers** — `audit` / `optimize` / `consolidate` / `testgaps` / `predict` / `document` / `map` fire at sprint-protocol checkpoints only, **not on schedule** (cuts ~9h/day silent Sonnet burn to ~50min per sprint, v0.6.0)
- **65+ helper scripts** — full state machine, drift, hill chart, dashboard, velocity, harness-readiness aggregator, atomic-state helpers, worker triggers + gates, mirror-parity check, ruflo trigger-race patch

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
7. Scaffold `docs/sprints/{README,USAGE,DEVELOPER,QUICKSTART}.md`
8. Write `<target>/.sprintrc.json` with brand config you choose during install
9. Verify dependencies (ruflo, jq, gh, pnpm/npm, optional: sonar-scanner, docker)

## Quick start (after install)

```bash
bash scripts/sprint-start.sh first-sprint --no-issue
# tell Claude: "start the spec wizard"
```

See `docs/sprints/QUICKSTART.md` (installed into your repo) for the 5-minute walkthrough.

## What problems this solves

| Without sprint harness | With sprint harness |
|---|---|
| "Hey Claude, build X" → ad-hoc work | Structured 14-day cycle with deterministic phases |
| Scope drifts during build | Drift score on every commit; hard pause below 0.75 |
| Claude edits files outside the intended scope | PreToolUse hook blocks out-of-scope edits |
| No record of why a decision was made | Wizard transcript + recalled patterns + retro |
| Building the same thing twice in 3 months | Memory recall surfaces prior patterns at spec time |
| Push to main by accident | Husky hook blocks `git push` during sprint |
| Lost track of what's done | Hill chart + dashboard + GitHub PR auto-fill |
| Patterns never re-used | Retro extracts 3-5 patterns → stored to ruflo memory |
| "Did the gate catch the bug?" → guessing | Inject-violation-catch-restore proof per AC |

## Methodology — Inject-violation-catch-restore

After early sprints over-claimed at 99/99 file-presence tests, every capability shipping in this harness is proven by:

1. Run gate against clean main (baseline)
2. `git apply` a known-violation fixture
3. Re-run gate; assert it CATCHES the violation
4. `git apply -R` to restore
5. Write proof markdown documenting all three

The `scripts/sprint-inject-violation.sh` helper is the standard runner. Fixtures live in `scripts/violation-fixtures/`.

**Two-verdict policy:** Production OR Broken-with-followup-AC. No "Scaffolded" middle bucket — that's how false-victory closes happen.

## Architecture (3 layers)

```
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
│  • State machine (sprint-start/status/end/pause/resume)  │
│  • Wizard (sprint-spec-wizard + 4 helpers)               │
│  • Drift detection (sprint-drift-check + sprint-drift-score) │
│  • Phase scripts (build-launch/checkin/cleanup/retro)    │
│  • QA tools (sonar-parse/migration-check/cycle-check/    │
│    audit-deps/bundle-budget/coverage-delta/perf-check)   │
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
└──────────────────────────────────────────────────────────┘
```

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

## Documentation

| Doc | Lives at (after install) | Audience |
|---|---|---|
| Quick start (5-min) | `docs/sprints/QUICKSTART.md` | First-time users |
| Full usage guide | `docs/sprints/USAGE.md` | All users |
| Developer guide | `docs/sprints/DEVELOPER.md` | Extending the system |
| Capability catalog | `docs/sprints/_index/capabilities.md` | Cross-sprint reference |
| Bypass cheatsheet | `docs/sprints/_guides/bypass-cheatsheet.md` | Escape hatches |
| Troubleshooting | `docs/sprints/_guides/troubleshooting.md` | Symptom-indexed lookup |

## Provenance

Extracted from an internal product codebase where the harness was developed across four sprints and proven against 71 acceptance criteria via inject-violation-catch-restore. See [HISTORY.md](./docs/HISTORY.md) for the audit trail.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). PRs welcome at the SKILL.md and section markdown level (highest ROI per change). Lower layers (scripts, hooks) require more care + an `inject-catch-restore` proof.

## License

MIT — see [LICENSE](./LICENSE).
