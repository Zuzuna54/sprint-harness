# AC-1 — pnpm turbo typecheck

**Verdict:** ✓ PRODUCTION

## Phase 1 — baseline (clean main)

`pnpm turbo run typecheck --filter='@lifeos/utils' --force` → exit 0

## Phase 2 — injected violation

Fixture: `scripts/violation-fixtures/typecheck-bad-type.patch` prepends:

```ts
const __injected_violation_bad_type: number = 'not a number'
```

Re-run output:

```
@lifeos/utils:typecheck: src/macros.ts(2,7): error TS2322: Type 'string' is not assignable to type 'number'.
@lifeos/utils:typecheck:  ELIFECYCLE  Command failed with exit code 2.
Failed:    @lifeos/utils#typecheck
```

Caught: ✓ yes (exit 2, specific TS2322 error)

## Phase 3 — restore

`git apply -R` clean; `git status --porcelain packages/utils/src/macros.ts` empty.

## Production-ready: ✓
