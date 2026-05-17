---
name: Bug report
about: Something in the installer or runtime broke
title: '[Bug] '
labels: bug
---

## Summary

What broke?

## To reproduce

1. Host OS + version (`uname -a` + `sw_vers` or `lsb_release -a`):
2. Node version (`node --version`):
3. Package manager (`pnpm --version` / `npm --version`):
4. Tier-2 deps installed (gh / docker / sonar-scanner / playwright):
5. Steps:
   ```
   npx @ordex/sprint-harness install
   # ...
   ```
6. Actual output / error:
   ```
   <paste>
   ```

## Expected

What should have happened?

## doctor output

```
npx @ordex/sprint-harness doctor
```

Paste full output above.

## .sprintrc.json

(redact any tokens / paths you don't want public)
```json
<paste>
```
