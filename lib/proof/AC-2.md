# AC-2 — sprint-lint-check.sh

**Verdict:** ✓ PRODUCTION

## Inject-catch-restore (full)

1. **Baseline** `bash scripts/sprint-lint-check.sh playbook` exit 0
2. **Inject** `playbook/__lint_inject__.mjs` with `var x = ...` → exit 1
3. **Restore** rm injection → clean

## Output (injected)

```
  1 error and 0 warnings potentially fixable with the `--fix` option.

✗ lint errors found (exit 1)
```

## Known limitation

Shim covers .js/.mjs only (root workspace ESLint can't parse .ts without TS parser). TS lint runs in apps/web via `next lint` (interactive — separate concern). Filed as next-sprint follow-up: install @typescript-eslint/parser at workspace root.

## Production-ready: ✓ for .js/.mjs scope; .ts scope is documented gap
