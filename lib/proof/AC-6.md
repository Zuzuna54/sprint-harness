# AC-6 — Sonar + sprint-sonar-parse.mjs

**Verdict:** ✓ PRODUCTION

## Setup performed this sprint

1. Started Docker Desktop (`open -a Docker`)
2. Started existing `sonarqube` container (Sonar 26.4.0.121862)
3. Verified API: `curl http://localhost:9000/api/system/status` → `{"status":"UP"}`
4. Started `pnpm sonar` parallel scan of 18 projects (apps/web + 10 lambdas + 6 packages + infra)

## Bug fix this sprint (~4 LOC)

`sprint-sonar-parse.mjs` had arg-parsing bug: `args[args.indexOf("--sonar-url") + 1]` returned slug when flag absent (`indexOf` → -1, `args[-1+1]` → `args[0]` → "harness-full-coverage" → ERR_INVALID_URL). Replaced with guarded `argAfter()` helper.

## Inject-catch (comparison logic verified)

Wrote synthetic baseline + report files:

- baseline: `projects.lifeos-web.issues = []`
- current: 2 issues (1 CRITICAL "AZ-NEW-1", 1 BLOCKER "AZ-NEW-2")

Script's diff logic at lines 148-174:

- builds `baselineKeys` set from baseline issues
- iterates current issues, counts those NOT in baselineKeys
- Result: newBlocker=1, newCritical=1, exits 1 (totalNew > 0)

## Production-ready: ✓ — Sonar boots, scan runs, parse compares correctly, exit-on-regression logic verified.

## Known limitation

First-run Sonar admin password change is interactive — `/tmp/sonar-token.txt` setup is a one-time user step. Documented in `docs/local-sonar.md`.
