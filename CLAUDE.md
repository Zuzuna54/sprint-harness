# sprint-harness

> Extracted sprint-orchestration tooling from LifeOS (Ordex). Ships as a standalone npm package (`sprint-harness`) for teams adopting the Shape Up + SPARC + ruflo sprint system.

## Brand

- **Package:** `sprint-harness` (npm), `Zuzuna54/sprint-harness` (GitHub)
- **Product brand in copy:** `Sprint Harness`
- **Codebase identifier in code:** `sprint-harness`

---

## Quick start

```bash
npm install @lifeos/sprint-harness
npx sprint-init  # interactive setup
bash node_modules/.bin/sprint-start.sh my-sprint
```

Or from repo clone:
```bash
npm install
cp lib/templates/.claude/settings.json .claude/settings.json
bash scripts/sprint-start.sh <slug>
```

---

## What this ships

| Path | Purpose |
|------|---------|
| `scripts/sprint-*.sh` | Bash sprint scripts (start, end, status, etc.) |
| `scripts/sprint-*.mjs` | Node.js sprint scripts (wizard, dashboard, etc.) |
| `lib/scripts/lib/` | Shared shell libs: `atomic-state.sh`, `lock-dir.sh`, `session-file.sh` |
| `lib/templates/.claude/` | Template `.claude/` directory (copy to project root) |
| `lib/templates/.claude/helpers/` | Template helpers: `hook-handler.cjs`, `sprint-hook.cjs` |
| `lib/templates/.claude/settings.json` | Template settings (teammateMode=manual, 4 daemon workers) |
| `docs/sprints/` | Sprint state.json schema docs |

---

## Ruflo activation — when to use what

Full docs: [`docs/sprints/USAGE.md`](./docs/sprints/USAGE.md).

| User says | I invoke |
|-----------|----------|
| "start a sprint" / "/sprint <slug>" | `sprint-orchestrator` skill → `bash scripts/sprint-start.sh` |
| "show me the spec so far" | `node scripts/sprint-wizard-assemble.mjs <slug> --partial --dry-run` |
| "sprint status" | `bash scripts/sprint-status.sh` |
| "pause / resume" | `bash scripts/sprint-pause.sh` / `bash scripts/sprint-resume.sh` |

---

## CLAUDE.md for downstream projects

This repo ships a template `CLAUDE.md` in `lib/templates/CLAUDE.md`. Copy it to project root when adopting the sprint system.

The template is intentionally lightweight — token-efficient patterns from LifeOS Phase 2 optimization.

---

## Key constraints

- **TDD-first**: write failing tests before implementation
- **RLS on all tables**: SELECT/INSERT/UPDATE/DELETE policies
- **Soft delete**: use `deleted_at` timestamp, never hard DELETE
- **Auth on every route**: validate every request
- **No secrets in code**: env vars / SSM Parameter Store
- **Validation everywhere**: Zod schemas on all inputs

---

## Development

```bash
npm test
bash scripts/sprint-smoke-validate.sh
bash scripts/sprint-system-audit.sh
```

---

## Spec References

- Architecture: `docs/sprints/README.md`
- Quick start: `docs/sprints/QUICKSTART.md`
- Full usage: `docs/sprints/USAGE.md`
- Developer guide: `docs/sprints/DEVELOPER.md`