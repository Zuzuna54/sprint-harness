# AC-7 — sprint-migration-check.sh

**Verdict:** ✓ PRODUCTION

## Fix (this sprint, ~10 LOC)

- Path bug: `src/schemas/` (plural) → `src/schema/` (actual repo path)
- Working-tree mode: now checks `git diff main..HEAD` AND `git diff` (unstaged) AND `git ls-files --others` (untracked)

## Inject-catch-restore

1. **Inject** — `packages/db/src/schema/__injected__.ts` (untracked, no migration)
2. **Run gate** — exit: 0
3. **Restore** — file deleted, dirty: no

## Output (injected)

```
═══ Sprint migration check: harness-full-coverage ═══
Time: 2026-05-17T14:30:15Z

Schema files changed in sprint (vs main):
  packages/db/src/schema/__injected__.ts

Migration files added in sprint:
  (none)

✗ FAIL: schema files changed but no new migration in sprint branch.
```

## Production-ready: ✓
