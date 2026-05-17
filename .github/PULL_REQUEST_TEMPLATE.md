## Summary

<!-- 1-3 bullet points. Link the AC or issue this closes. -->

## Test plan

- [ ] `npm test` (install-smoke + matrix + 71-ACs all green)
- [ ] `node tests/install-smoke.mjs` (specific path)
- [ ] Fresh-machine simulation: `node bin/sprint-harness.mjs install --target /tmp/sh-fresh` succeeds, then `doctor` reports all surfaces green
- [ ] If touching installer prompts: tested interactive path with yes to optional prompts (Sonar / Playwright)
- [ ] If touching template files (`lib/templates/`): brand-substitution still emits clean output (no `<BRAND_*>` tokens left)
- [ ] CHANGELOG.md entry added under `[Unreleased]` (or next version)

## Verdict bar

Each AC must be **Production** (inject-violation-catch-restore verified) or **Broken-with-followup-AC**. No "Scaffolded" middle bucket.
