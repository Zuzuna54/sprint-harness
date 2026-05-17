# Contributing to @ordex/sprint-harness

Thanks for considering a contribution. Three rules before you start:

## Rules

1. **Production verdict requires inject-violation-catch-restore proof.** File presence + "didn't crash" is not enough. Every PR that adds a new capability needs a `proof/AC-N.md` showing:
   - Baseline run on clean main (exit 0)
   - Inject known violation
   - Re-run, observe catch
   - Restore, observe clean
2. **Two terminal verdicts only:** Production OR Broken-with-followup-issue. No "Scaffolded" middle bucket.
3. **All edits in `lib/`** are templates with `<TOKEN>` placeholders. Don't hardcode brand names — let the installer substitute.

## Highest-ROI areas (lowest-risk changes)

- `lib/skills/sprint-spec-wizard/sections/*.md` — wizard section question banks. Tweaks here improve every sprint's spec quality.
- `lib/templates/sprints/_guides/*.md` — operational recipes. Add a troubleshooting entry for any new failure mode you encounter.
- `docs/PREREQUISITES.md` — keep the dependency matrix accurate.

## Higher-risk areas (more care required)

- `lib/scripts/sprint-*.{sh,mjs}` — require an inject-catch-restore proof
- `lib/helpers/*.cjs` — these are PreToolUse hooks; broken hooks block all Claude Code edits
- `bin/sprint-harness.mjs` — the installer; tested via `tests/install-smoke.mjs`

## Dev setup

```
git clone <repo-url>      # e.g. https://github.com/<your-org>/sprint-harness.git
cd sprint-harness
# No build step — bin/ is plain mjs.
# Test installer in a scratch dir:
node bin/sprint-harness.mjs install --non-interactive --target /tmp/sh-test
node bin/sprint-harness.mjs verify --target /tmp/sh-test
node bin/sprint-harness.mjs uninstall --target /tmp/sh-test
rm -rf /tmp/sh-test
```

## PR checklist

- [ ] Inject-catch-restore proof file under `proof/AC-N.md` (if new capability)
- [ ] `bin/sprint-harness verify` passes after change
- [ ] No hardcoded brand strings — uses `<BRAND_NAME>`, `<BRAND_SLUG>`, `<NAMESPACE>`, `<GITHUB_ORG>`, `<AWS_PROFILE_NAME>`, `<REPO_ROOT>` tokens
- [ ] `docs/PREREQUISITES.md` updated if a new dep was added
- [ ] CHANGELOG entry under the next-version section

## Commit message format

```
<type>(<scope>): <subject>

<body>
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.
Scope: `installer`, `skills`, `scripts`, `hooks`, `workflows`, `docs`.

## Reporting violations

If you find a pipeline-skip violation (silent `|| true`, missing `on_failure`, unlogged bypass, pipe-RC trap, set -e gap), open an issue with the `violation` label. We'll add a regression proof and fix.

## License

By contributing, you agree your code is MIT-licensed.
