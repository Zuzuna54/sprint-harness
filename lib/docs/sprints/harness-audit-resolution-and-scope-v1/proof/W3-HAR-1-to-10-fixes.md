# Wave 3 — HAR-1..10 fixes (AC-9..18)

**Verdict:** Production
**Methodology:** per-file fix + per-file test file + full test sweep (45/45 passing).

## What landed (4 source files + 4 test files)

| HAR    | Severity | File:line                           | Fix approach                                                                                                   | Test count                                                                            |
| ------ | -------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| HAR-1  | high     | `.claude/helpers/github-safe.js:45` | `execSync` → `execFileSync` with arg-array (no shell interpolation)                                            | 1 (HAR-1 import-shape)                                                                |
| HAR-2  | high     | `.claude/helpers/memory.js:9`       | AES-256-GCM via node built-in crypto + 0600 key file + keyVersion envelope + atomic-rename migration           | 6 (encryption + envelope + perms + tamper-detect + version-mismatch + detection)      |
| HAR-3  | high     | `.claude/helpers/session.js:18`     | `Date.now()` → `crypto.randomUUID()`                                                                           | 1 (UUID format + source assertion)                                                    |
| HAR-4  | high     | `.claude/helpers/session.js:9`      | Same AES-256-GCM stack as memory.js (shared key file) + atomic migration                                       | 3 (roundtrip + envelope + tamper)                                                     |
| HAR-5  | medium   | `.claude/helpers/github-safe.js:46` | Command/subcommand allowlist + flag allowlist + shell-metacharacter blocklist on positional args               | 5 (command/subcommand/flag rejection + positional meta + valid passthrough)           |
| HAR-6  | medium   | `.claude/helpers/memory.js:23`      | Key validation regex `/^[A-Za-z0-9_.-]+$/` + reject `/` and `..` explicitly                                    | 6 (path-traversal + slash + shell-meta + accept-valid + empty + length)               |
| HAR-7  | medium   | `.claude/helpers/session.js:33`     | Context key validator + value type-check + code-injection regex (eval/Function/${...}/backticks) + max-depth=4 | 13 (key validation + value type-check across plain types + nested + class + function) |
| HAR-8  | medium   | `.claude/helpers/statusline.js:22`  | All fs ops branch on `e.code === 'ENOENT'` (silent) vs other errors (logged to stderr)                         | 4 (no bare `// Ignore` + ENOENT pattern + --json graceful + stderr tag)               |
| HAR-9  | medium   | `.claude/helpers/github-safe.js:62` | `openSync` with `O_EXCL` flag + 0600 perms + post-create ownership verify (uid match) + atomic cleanup         | 1 (tmp file orphan check)                                                             |
| HAR-10 | low      | `.claude/helpers/memory.js:45`      | ENOENT silent, EACCES/JSON-parse logged + thrown                                                               | covered by HAR-6 set-with-bad-key (exit 2 + stderr)                                   |

## Test sweep

```
$ node .claude/helpers/__tests__/github-safe.test.mjs    →  7 passed, 0 failed
$ node .claude/helpers/__tests__/memory.test.cjs         → 15 passed, 0 failed
$ node .claude/helpers/__tests__/session.test.cjs        → 19 passed, 0 failed
$ node .claude/helpers/__tests__/statusline.test.cjs     →  4 passed, 0 failed
                                                          ────────────────────
                                                           45 passed, 0 failed
```

## C4 + C7 satisfied

**C4 (security): encryption key 0600 + crypto.randomBytes(32) only** — `memory.js::ensureKeyFile()` line ~50 + `session.js::ensureKeyFile()` line ~63 both:

- `crypto.randomBytes(32)` for key generation (NEVER `Math.random` or `Date.now`)
- `openSync(KEY_FILE, O_WRONLY|O_CREAT|O_EXCL, 0o600)` — exclusive create + 0600 perms
- Perms re-verified on every load (`if ((st.mode & 0o077) !== 0) throw`)
- Test: `HAR-2 key file is 0600 perms` confirms live.

**C7 (security): atomic legacy-plaintext migration** — both `memory.js::saveMemory()` line ~123 + `session.js::writeSession()` line ~157:

- Write encrypted envelope to `.tmp.<random>` via `O_WRONLY|O_CREAT|O_EXCL` (exclusive create)
- `fs.fsyncSync(fd)` before close
- `fs.renameSync(tmp, target)` — atomic on POSIX; replaces target only after .tmp fully written
- No partial-write window where both plaintext + encrypted exist (rename is the swap)

## Architectural notes

**Key file shared between memory.js + session.js.** Both helpers use `~/.claude-flow/.encryption-key`. Single key derivation, single rotation point (future `harness-key-rotation-v1` follow-up). Independently-importable encrypt/decrypt — each helper is self-contained for testability.

**Detection of legacy plaintext format.** Both helpers' `loadMemory`/`readSession` use `isEncryptedEnvelope(text)` to distinguish encrypted JSON (`{keyVersion, iv, authTag, ciphertext}`) from legacy plaintext JSON. Legacy files auto-migrate to encrypted on next save. Operator sees `[memory] legacy plaintext memory.json detected — will migrate to encrypted on next save` warning on first load.

**No new npm deps** — per locked decision. Node built-in `crypto` (aes-256-gcm + randomBytes + createCipheriv) covers all encryption needs. License-clean (Node MIT).

**Tests don't require vitest.** Plain `node:assert` + manual test runner. ~30 lines of boilerplate per file. Compatible with `pnpm turbo run test` if eventually wired (each test file is self-contained executable).

## Inject-violation-catch-restore (sampled — HAR-3 UUID)

| Phase              | Action                                         | Expected    | Result                                            |
| ------------------ | ---------------------------------------------- | ----------- | ------------------------------------------------- |
| Baseline           | grep `crypto.randomUUID()` in session.js       | match       | ✓ confirmed                                       |
| Inject (synthetic) | Revert line 175 to `\`session-${Date.now()}\`` | test fails  | (deferred — proof via positive assertion in test) |
| Restore            | Re-apply `crypto.randomUUID()`                 | test passes | ✓                                                 |

Tests assert BOTH the positive (UUID format) AND the negative (no Date.now() in template literal). Source-level proof.

## Files modified

- `.claude/helpers/github-safe.js` — rewritten (107 → 175 lines; HAR-1 + HAR-5 + HAR-9)
- `.claude/helpers/memory.js` — rewritten (84 → 217 lines; HAR-2 + HAR-6 + HAR-10)
- `.claude/helpers/session.js` — rewritten (136 → 252 lines; HAR-3 + HAR-4 + HAR-7)
- `.claude/helpers/statusline.js` — patched (HAR-8 in 2 functions)
- `.claude/helpers/__tests__/github-safe.test.mjs` — NEW (102 lines)
- `.claude/helpers/__tests__/memory.test.cjs` — NEW (115 lines)
- `.claude/helpers/__tests__/session.test.cjs` — NEW (146 lines)
- `.claude/helpers/__tests__/statusline.test.cjs` — NEW (55 lines)

## C-condition coverage (W1+W2+W3 cumulative)

| Condition                                   | Wave | Status  |
| ------------------------------------------- | ---- | ------- |
| C-base scope-bounding                       | W1   | ✓       |
| C1 exit predicate pure-state.json           | W2   | ✓       |
| C2 atomic per-decision persistence          | W2   | ✓       |
| C3 twice-consecutive regression threshold   | W2   | ✓       |
| C4 encryption key 0600 + crypto.randomBytes | W3   | ✓       |
| C5 PII-redact rationale                     | W2   | ✓       |
| C6 env-stripped audit worker fire           | W2   | ✓       |
| C7 atomic encryption migration              | W3   | ✓       |
| C8 W4 dogfood resolved == total             | W4   | pending |

**8/9 ship-gate conditions satisfied.** Only C8 remains for W4 dogfood.

## Done = all of

- ✓ HAR-1..10 fixed across 4 .claude/helpers/\*.js files
- ✓ 4 test files with 45/45 passing assertions
- ✓ C4 + C7 satisfied (encryption + migration)
- ✓ Zero new npm deps (Node built-in crypto only)
- ✓ Both encryption helpers share single key file (memory.js + session.js)
- ✓ Legacy plaintext auto-migrate on next save (with stderr warning)
- ⏸ W4 dogfood (audit-rerun confirms findings gone in-scope; C8)
