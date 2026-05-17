# AC-8 — pnpm knip

**Verdict:** ✓ PRODUCTION

## Fix (this sprint)

`knip.json` had invalid `_comment` JSON key — knip 5 rejects unknown root keys. Removed.

## Inject-catch-restore

- **Baseline**: `pnpm dlx knip --no-progress --reporter compact` exits 1 (existing unused exports, baseline level)
- **Inject**: `packages/utils/src/__unused_knip__.ts` exporting `definitelyUnusedKnipBait`
- **Re-run**: caught `__unused_knip__` in output (1 match)
- **Restore**: deleted, gate back to baseline

## Output (excerpt, injected)

```
packages/utils/src/__unused_knip__.ts: definitelyUnusedKnipBait
```

## Production-ready: ✓
