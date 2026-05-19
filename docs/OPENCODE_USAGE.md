# Sprint System — opencode Usage Guide

> **For:** anyone running LifeOS sprints with opencode instead of Claude Code
> **What this is:** adapted usage guide for the sprint system without ruflo

---

## Overview

The sprint harness system works with opencode. All sprint scripts are bash-based with no ruflo dependency. You run sprints manually instead of through ruflo workflows.

**What still works:**

- `bash scripts/sprint-start.sh <slug>` — creates sprint dir, writes state
- `bash scripts/sprint-status.sh` — prints phase/day/drift
- `bash scripts/sprint-end.sh <slug>` — retro + close
- All 51 sprint scripts (`sprint-*.sh` / `sprint-*.mjs`)
- Drift control via husky hooks (`.husky/pre-commit`)
- Pre-tool-use scope enforcement (adapted below)
- Sprint state machine (11 phases)
- All 71 harness ACs

---

## opencode vs Claude Code + ruflo

| Feature               | Claude Code + ruflo                                                                      | opencode                                             |
| --------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| Sprint resolution     | session-file (`~/.claude/sessions/<id>/sprint-slug`), `SPRINT_SLUG_OVERRIDE`, git branch | `--slug` flag or `SPRINT_SLUG_OVERRIDE` env var only |
| Hook system           | Claude Code hooks (`.claude/helpers/sprint-hook.cjs`)                                    | opencode hooks (`~/.opencode/hooks/`)                |
| Daemon workers        | ruflo daemon with 7+ workers (audit, optimize, testgaps, etc.)                           | Not available                                        |
| Agent teams           | ruflo swarm (`8-agent hierarchical-mesh`)                                                | Manual task assignment                               |
| Memory                | ruflo memory store (`ruflo memory store --vector --upsert`)                              | `/lifeos-ref` skill for reference; manual memory     |
| Sprint orchestrator   | `ruflo workflow execute lifeos-sprint-build`                                             | Manual execution                                     |
| Sprint spec wizard    | `sprint-spec-wizard` skill (LLM-driven)                                                  | Manual spec writing                                  |
| Workflows             | `lifeos-build`, `lifeos-verify`, `lifeos-deploy`, `lifeos-cleanup`                       | Run scripts individually; no workflow chaining       |
| Trajectory tracking   | `ruflo hooks pre-task` → ReasoningBank                                                   | Not available                                        |
| Pattern extraction    | Auto-stored to ruflo memory at retro                                                     | Manual or write to `~/.claude/journal/`              |
| Session file          | `~/.claude/sessions/<id>/sprint-slug`                                                    | Not used; `--slug` / `SPRINT_SLUG_OVERRIDE` only     |
| DAA reviewer feedback | `sprint-daa-feedback.sh` → ruflo daemon queue                                            | Manual or skip                                       |
| Neural training       | `bash scripts/sprint-train.sh` (ruflo-trained)                                           | Not available                                        |
| Auto-memory-hook      | Session start/end auto-memory updates                                                    | Manual invocation of `/lifeos-ref`                   |

---

## How to run sprints with opencode

### 1. Set context

```bash
export SPRINT_SLUG_OVERRIDE=<slug>
# OR use --slug flag on individual scripts
bash scripts/sprint-start.sh <slug> --no-branch
```

### 2. Start sprint

```bash
bash scripts/sprint-start.sh my-feature
```

This creates `docs/sprints/my-feature/`, initializes `state.json`, creates GH issue (if `gh` available). No ruflo daemon needed.

### 3. Write spec

The sprint-spec-wizard skill runs the 10-section discovery process. With opencode, you write the spec manually or use the wizard logic as a guide:

```bash
# Check wizard state (if partial answers exist from prior session)
node scripts/sprint-spec-wizard.mjs status <slug>
node scripts/sprint-spec-wizard.mjs section <slug> A
node scripts/sprint-spec-wizard.mjs assemble <slug>

# See partial spec so far
node scripts/sprint-wizard-assemble.mjs <slug> --partial --dry-run
```

Write spec to `docs/sprints/<slug>/spec.md` directly if preferred.

### 4. Spec lock

```bash
bash scripts/sprint-amend-spec.sh --lock
```

Writes `.baseline-embedding.json`. Drift control arms.

### 5. Build

```bash
# Manual build — run scripts individually
bash scripts/sprint-build-launch.sh  # sets up context, shows what to run

# Check AC status
node scripts/sprint-pair-check.mjs <slug>

# Manual drift check
bash scripts/sprint-drift-check.sh
```

No swarm, no autopilot side-cars. You drive the build.

### 6. Verify

```bash
bash scripts/run-workflow.sh docs/workflows/lifeos-verify.yaml slug=<slug>
```

Or run chains manually:

```bash
pnpm typecheck && pnpm lint && pnpm test
```

### 7. Pre-deploy

```bash
bash scripts/run-workflow.sh docs/workflows/lifeos-deploy.yaml slug=<slug>
```

**Manual approval at pulumi preview:** review the output, then run `pulumi up` yourself if approved.

### 8. End sprint

```bash
bash scripts/sprint-end.sh <slug>
```

### Day-5 check-in

```bash
bash scripts/sprint-checkin.sh
node scripts/sprint-hillchart.mjs <slug> --refresh
```

---

## Hook adaptation

opencode hooks live at `~/.opencode/hooks/`. The sprint system's PreToolUse drift control + forbidden-action blocks need to be adapted.

### opencode hook format

```json
{
  "type": "command",
  "command": "sh -c '...'",
  "timeout": 5000,
  "matcher": "Bash"
}
```

`matcher` selects when the hook fires: `Bash`, `Edit`, `Write`, `Read`, `Glob`, `Grep`.

### Drift control hook

Create `~/.opencode/hooks/sprint-drift.js`:

```js
#!/usr/bin/env node
// sprint-drift.js — opencode PreToolUse hook for sprint drift control
// Usage: invoke via opencode.json hooks on Bash/Edit/Write tools

const fs = require('fs')
const path = require('path')

const REPO_ROOT = process.cwd()
const SPRINT_SLUG = process.env.SPRINT_SLUG_OVERRIDE

function getActiveSprint() {
  if (!SPRINT_SLUG) return null
  const stateFile = path.join(REPO_ROOT, 'docs/sprints', SPRINT_SLUG, 'state.json')
  if (!fs.existsSync(stateFile)) return null
  const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'))
  if (state.phase === 'done' || state.phase === 'paused') return null
  return state
}

function getSpecScope() {
  if (!SPRINT_SLUG) return null
  const specFile = path.join(REPO_ROOT, 'docs/sprints', SPRINT_SLUG, 'spec.md')
  if (!fs.existsSync(specFile)) return null
  return fs.readFileSync(specFile, 'utf8')
}

// Block patterns
const FORBIDDEN = [
  'git push',
  'pulumi up',
  'pulumi destroy',
  'rm -rf /',
  'DROP TABLE',
  'DELETE FROM',
]

function checkForbidden(command) {
  for (const pattern of FORBIDDEN) {
    if (command.includes(pattern)) {
      console.error(`[!] Forbidden action blocked: ${pattern}`)
      console.error('    Override: SPRINT_DRIFT_BYPASS=1 <command>')
      return false
    }
  }
  return true
}

function checkScope(filePath) {
  if (!filePath || !SPRINT_SLUG) return true
  const scope = getSpecScope()
  if (!scope) return true
  // Files in docs/, test files, sprint dir always allowed
  if (/^(docs\/|test\//.test(filePath)) return true
  const sprintDir = `docs/sprints/${SPRINT_SLUG}/`
  if (filePath.startsWith(sprintDir)) return true
  // Check if file is in spec's ## Files touched list
  // (simplified — full impl would parse spec.md §H)
  return true
}

// Main: read input from stdin (opencode passes tool args as JSON)
try {
  const input = JSON.parse(fs.readFileSync('/dev/stdin', 'utf8'))
  const tool = input.tool || ''
  const args = input.args || {}

  const state = getActiveSprint()
  if (!state) process.exit(0) // no active sprint

  if (tool === 'Bash') {
    if (!checkForbidden(args.command || '')) process.exit(1)
  }

  if (tool === 'Edit' || tool === 'Write') {
    const filePath = args.filePath || ''
    if (!checkScope(filePath)) {
      console.error(`[!] Out-of-scope edit: ${filePath}`)
      console.error(`    Add to spec: bash scripts/sprint-amend-spec.sh --add-file ${filePath}`)
      process.exit(1)
    }
  }

  process.exit(0)
} catch (e) {
  // If parsing fails, allow (fail open)
  process.exit(0)
}
```

Register in `~/.opencode/opencode.json`:

```json
{
  "hooks": {
    "preToolUse": [
      {
        "type": "command",
        "command": "node ~/.opencode/hooks/sprint-drift.js",
        "timeout": 5000,
        "matcher": "Bash"
      },
      {
        "type": "command",
        "command": "node ~/.opencode/hooks/sprint-drift.js",
        "timeout": 5000,
        "matcher": "Edit"
      },
      {
        "type": "command",
        "command": "node ~/.opencode/hooks/sprint-drift.js",
        "timeout": 5000,
        "matcher": "Write"
      }
    ]
  }
}
```

**Note:** The hook receives tool args as JSON on stdin. Verify the exact input shape matches your opencode version's hook protocol.

### Husky drift check (still works)

The `.husky/pre-commit` hook embeds commit messages + diffs and computes cosine similarity against the baseline. This is entirely shell-based and works without ruflo:

```bash
# Manual drift check
bash .husky/pre-commit
```

### Session hook (not available)

opencode doesn't use `~/.claude/sessions/<id>/sprint-slug`. Use `SPRINT_SLUG_OVERRIDE` instead. Scripts that check session-file (like `scripts/lib/session-file.sh`) will skip — use `--slug` or `SPRINT_SLUG_OVERRIDE` explicitly.

---

## What's different / not available

### Not available

- **ruflo workflows** — run scripts individually instead of `ruflo workflow execute lifeos-build`
- **Agent swarms** — manually assign tasks; no 8-agent hierarchical-mesh
- **Autopilot side-cars** — lint-fix, test-backfill, doc-sweep loops run manually
- **Daemon workers** — no audit/optimize/consolidate/testgaps/predict/map workers
- **Trajectory tracking** — ReasoningBank not available; manual pattern capture
- **H瞒e-mind consensus** — spec-lock review chain is manual (you read + decide)
- **Pattern memory** — write patterns to `~/.claude/journal/` at retro instead of `ruflo memory store`
- **Auto-memory-hook** — invoke `/lifeos-ref` skill manually when you need context
- **Neural training** — `sprint-train.sh` not functional without ruflo

### What's the same

- All bash scripts (`sprint-*.sh`, `sprint-*.mjs`) — no ruflo dependency
- `atomic-state.sh` helper
- Husky hooks (`.husky/pre-commit`, `pre-push`, `post-commit`) — shell-based
- Sprint state machine (11 phases) — `state.json` is the source of truth
- Drift control via `.baseline-embedding.json` + cosine similarity
- Sprint resolution via `--slug` / `SPRINT_SLUG_OVERRIDE`
- All 71 harness ACs (mostly shell-based)
- `scripts/run-workflow.sh` YAML runner (minimal shim, no ruflo)
- All env vars (`SPRINT_DRIFT_THRESHOLD`, `SPRINT_DUP_BYPASS`, etc.)
- Parallel sprints support (same resolution chain)

---

## Quick reference

```bash
# Start
bash scripts/sprint-start.sh <slug> [--with-branch] [--no-issue]

# Status
bash scripts/sprint-status.sh
bash scripts/sprint-status.sh --slug <name>
bash scripts/sprint-status.sh --json
bash scripts/sprint-status.sh --list

# Context (opencode doesn't use session-file)
export SPRINT_SLUG_OVERRIDE=<slug>

# Spec
bash scripts/sprint-amend-spec.sh              # amend
bash scripts/sprint-amend-spec.sh --lock       # spec-lock
bash scripts/sprint-amend-spec.sh --cut AC-3   # cut scope
bash scripts/sprint-amend-spec.sh --add-file <path>  # widen scope

# Build
bash scripts/sprint-build-launch.sh            # sets up build context
bash scripts/sprint-drift-check.sh             # manual drift check

# Verify
bash scripts/run-workflow.sh docs/workflows/lifeos-verify.yaml slug=<slug>
bash scripts/run-workflow.sh docs/workflows/lifeos-cleanup.yaml slug=<slug>
bash scripts/run-workflow.sh docs/workflows/lifeos-deploy.yaml slug=<slug>
# Note: deploy pauses at pulumi preview — approve manually

# Lifecycle
bash scripts/sprint-pause.sh "reason"
bash scripts/sprint-resume.sh
bash scripts/sprint-checkin.sh
bash scripts/sprint-end.sh <slug>

# Reporting
node scripts/sprint-hillchart.mjs <slug> --refresh
node scripts/sprint-dashboard.mjs <slug> --open
node scripts/sprint-standup.mjs <slug>
node scripts/sprint-pr-body.mjs <slug>
node scripts/sprint-velocity.mjs <slug>

# Bypass
SPRINT_DRIFT_BYPASS=1 git commit ...   # skip drift check
SPRINT_DUP_BYPASS=1 git commit ...    # skip jscpd block

# Context when stuck
bash scripts/sprint-status.sh --slug <slug>
node scripts/sprint-dashboard.mjs <slug> --open
cat docs/sprints/<slug>/standup.md | tail -50

# Reference
node scripts/sprint-spec-wizard.mjs status <slug>   # wizard progress
node scripts/sprint-spec-wizard.mjs section <slug> A  # re-emit section
```

---

## Neural Patterns (Advanced)

The sprint-harness supports neural pattern training for behavioral similarity recall.

### How It Works

1. **Trajectories accumulate** — Each sprint records a trajectory (phase walk, AC outcomes, drift events)
2. **Training triggers** — When ≥20 trajectories exist, `sprint-end.sh` auto-runs `ruflo neural train`
3. **Patterns stored** — Trained patterns saved to `.claude-flow/neural/patterns.json`

### Usage

```bash
# Run from the project directory (e.g., LifeOS)
cd ~/Desktop/lifeos

# List trained patterns
ruflo neural patterns --action list

# Analyze patterns
ruflo neural patterns --action analyze --query "sprint planning"

# Check neural status
ruflo neural status
```

### Behavioral vs Content Similarity

| Type | What it finds | Used in |
|------|---------------|---------|
| **Content similarity** | "Sprints with similar spec content" | Wizard recall (default) |
| **Behavioral similarity** | "Sprints that walked like this one" | Pattern-based recall (opt-in) |

The wizard uses `--smart` flag for SmartRetrieval (query expansion + RRF + MMR). Pattern-based recall requires explicit wiring.

### Requirements

- ruflo installed (`npm install -g ruflo`)
- ≥20 trajectories in `.swarm/memory.db`
- Run from project root (not sprint-harness package directory)

---

## See also

- [`docs/sprints/USAGE.md`](./USAGE.md) — full usage guide (ruflo-specific sections still apply for workflow concepts)
- [`docs/sprints/README.md`](./README.md) — architecture overview
- [`docs/sprints/_guides/troubleshooting.md`](./_guides/troubleshooting.md) — operational recovery
- [`docs/sprints/_guides/bypass-cheatsheet.md`](./_guides/bypass-cheatsheet.md) — all env vars + escape hatches
- `/lifeos-ref` skill — project reference for opencode sessions

---

**Last refreshed:** 2026-05-18

For ruflo-specific documentation, see [`../ruflo-sessions/ruflo-for-lifeos.md`](../ruflo-sessions/ruflo-for-lifeos.md).
