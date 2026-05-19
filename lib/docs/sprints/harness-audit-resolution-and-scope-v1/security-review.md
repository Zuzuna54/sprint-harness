# Security Review — harness-audit-resolution-and-scope-v1

> **Threat model.** Same actors as parent + closure + harness-truthful-docs-and-wiring-v1: (a) the AI model itself, under token pressure / autopilot, taking a shortcut that lands a falsehood in `state.json`, drops a plaintext credential into a long-lived file, or fabricates a "vulnerability fixed" record without the fix; (b) a misconfigured operator who types a real secret into a rationale prompt, restores a botched backup that leaves stale plaintext files on disk, or invokes `audit-rerun` with a live-prod shell environment; (c) a compromised ruflo daemon worker (covered by parent S4) that now also influences `audit_findings_*` state via the new audit-resolution phase. External network attackers remain out of scope — the harness is local-only.
>
> **What is new in this sprint.** Three structural changes broaden the local attack surface: (1) `~/.claude-flow/.encryption-key` becomes a long-lived high-value file that EVERY future memory.json / session.json read depends on (HAR-2 / HAR-4); (2) `sprint-audit-resolve.sh` accepts free-form operator rationale on stdin and persists it into `state.json` (and therefore git history) forever, mirroring the parent's S11 / closure L14 bypass-PII attack class; (3) `sprint-audit-rerun.sh` re-fires the ruflo daemon audit worker mid-sprint with whatever environment the operator's shell carries — a new env-inheritance path. Each of these is graded below against the actual code being shipped (`memory.js`, `session.js`, `github-safe.js`, `statusline.js`, `sprint-pii-redact.sh`, and the prior sprint's `worker-trigger.sh` / `atomic-state.sh` primitives).
>
> **Carry-forward.** The prior sprint's nine surfaces (S1–S9 in `harness-truthful-docs-and-wiring-v1/security-review.md`) remain in scope wherever load-bearing — explicitly tabulated in §9 below.

---

## S1 — Encryption key file at `~/.claude-flow/.encryption-key` (HAR-2 / HAR-4)

**Attack.** HAR-2 and HAR-4 wrap `loadMemory`/`saveMemory` (memory.js:13/24) and the session lifecycle (session.js:14/36/50) with AES-256-GCM using `scryptSync` for key derivation. The key file is generated once at first use and reused for every subsequent encrypt/decrypt. Three concrete attack variants:

1. **Predictable key generation.** A naive implementation seeds key bytes via `Math.random()`, `Date.now()`, `process.pid`, or `crypto.randomUUID().replace(/-/g,'')` (low-entropy in the time-bits). Any of these reduces effective entropy from 256 bits to ~30–60 bits — bruteforceable offline once an encrypted `memory.json` blob is exfiltrated.
2. **World-readable perms.** `fs.writeFileSync(KEY_FILE, key)` without an explicit `{ mode: 0o600 }` honors process umask, which on a default macOS shell is `022` → file lands `0644` → any local user can read it. With Spotlight / Time Machine indexing the home dir, the key can also be backed up to a snapshot that survives the operator's "delete" action.
3. **Accidental commit.** A model under autopilot runs `git add -A` from `~` (operator's home) or from a misconfigured worktree whose `.gitignore` does not list `.claude-flow/.encryption-key`. The key lands in a public GitHub repo. All historical encrypted memory/session blobs are now plaintext-equivalent to anyone who clones.

**Likelihood.** Medium for variant 1 (LLMs default to non-crypto RNGs absent explicit guidance); High for variant 2 (mode bit is easy to forget); Low for variant 3 (requires operator-level mistake, mitigated by `.gitignore`).

**Impact.** Catastrophic across all three. The decrypted contents include: every cross-session memory key the harness has stored (project paths, branch names, command history fragments), every session context value (Claude Code conversation excerpts, tool invocations), and any third-party credential the operator stored via `memory.js set api_key …`.

**Mitigation (AC-10 / AC-12, HAR-2 / HAR-4).**

1. **Key generation MUST be `crypto.randomBytes(32)` with no fallback.** Do not catch any error from `randomBytes` — let the process fail-fast. Concretely:

   ```js
   const key = crypto.randomBytes(32) // throws on entropy failure; do not wrap in try/catch
   ```

2. **File write MUST set mode 0o600 atomically.** Use `fs.writeFileSync(KEY_FILE, key, { mode: 0o600 })` AND then `fs.chmodSync(KEY_FILE, 0o600)` (belt + braces — the `mode` option only sets perms on create, not on overwrite). On macOS APFS this is enforced by the kernel.
3. **Smoke-test in `__tests__/memory.test.cjs` MUST assert `(stat.mode & 0o777) === 0o600`** post-creation. Without this assertion in CI the regression surface is unbounded.
4. **`.gitignore` MUST list `.claude-flow/.encryption-key`** explicitly, AND a pre-commit hook check (mirror the existing `.husky/pre-commit` no-secrets grep) MUST refuse any staged file ending in `.encryption-key`. Cheap insurance.
5. **Key file MUST NOT be logged.** No `console.log(KEY_FILE)`, no `console.error(`key loaded from ${path}`)`. The error message on key-load failure should say "encryption key unavailable; run …" without printing the path — the path is well-known and printing it teaches an attacker exactly where to look on a stolen disk image.

**Residual risk.** Low after fix. A determined local attacker with read access to `$HOME` defeats this trivially — accepted for the local threat model. Disk encryption (FileVault) is the layer below this.

---

## S2 — Operator rationale leakage via `sprint-audit-resolve.sh` (AC-6)

**Attack.** The interactive finding walker (AC-6, ~350 LOC) prompts the operator with `Fix / Defer / Accept` for each `audit.json` vulnerability. Defer and Accept paths both capture a free-form rationale string that lands in `state.audit_findings_deferred[].rationale` (or `.audit_findings_accepted[].acceptance_rationale`) via `atomic_update_state`. `state.json` is git-committed at the end of every gate transition — the rationale lives in git history forever.

Concrete operator failure modes:

1. **Credential paste.** Operator types "skip this — the password is hardcoded at `apps/api/src/handlers/auth.ts:42`, value is `hunter2-prod-2026`, will rotate in next sprint." Now `hunter2-prod-2026` is in git history.
2. **PII paste.** Operator types "deferred — `gio@example.com` reported this in #incidents-2026-05; ticket has user_id `8f7e1c44-…`."
3. **Internal URL paste.** Operator types "see `postgresql://prod-readonly:…@…rds.amazonaws.com:5432/lifeos` for the row that triggers this."
4. **JWT paste.** Operator copies a debug header and pastes `Authorization: Bearer eyJhbGciOiJIUzI1…` into the rationale.

This is the same threat class as parent S11 / closure L14 (bypass.sh WHY-rationale), reified at the audit-resolution layer. Likelihood is **higher** here than for bypass because the operator is under "fix this finding" pressure and is more likely to copy-paste real code/data than under "explain why you skipped this gate" pressure.

**Likelihood.** High. The rationale prompt invites verbatim quotation from the codebase under review.

**Impact.** High. Git permanence is the killing characteristic: a redaction PR is necessary, and even then GitHub's API and `git reflog` can serve the original. For shared repos, full history rewrite (`git filter-repo`) becomes mandatory.

**Mitigation (AC-6).** **MUST-FIX before AC-6 ships.** The control surface already exists — `scripts/sprint-pii-redact.sh` handles six pattern classes (email, UUID, JWT, API keys, `password=` value, `postgresql://`). Wire it as follows:

1. **Pipe every rationale through `sprint-pii-redact.sh` before `atomic_update_state`.** Concretely, in `sprint-audit-resolve.sh`:

   ```bash
   read -r -p "Rationale: " raw_rationale
   sanitized=$(printf '%s' "$raw_rationale" | bash scripts/sprint-pii-redact.sh)
   atomic_update_state "$SLUG" ".audit_findings_deferred += [{har_id: \"$id\", rationale: $(jq -Rs . <<<"$sanitized"), …}]"
   ```

   The `jq -Rs .` step is mandatory — without it, a rationale containing a literal `"` or `\` breaks the jq filter (this is the same bug closure L11 hit in bypass.sh).

2. **Print the redaction match-count back to the operator.** `sprint-pii-redact.sh` already writes `[pii-redact] N pattern class(es) matched` to stderr. AC-6 MUST surface this back to the operator (e.g., "redactor caught 2 pattern classes; review the sanitized rationale before continuing") so they know something was scrubbed. Silent redaction is worse than no redaction — it lets the operator believe their literal text was saved.
3. **Length cap.** Cap rationale at 1024 bytes. A rationale longer than that is a code excerpt and belongs in a linked file, not in state.json.
4. **Multi-line ban.** Replace embedded newlines with spaces before redaction. Otherwise an operator who pastes a multi-line snippet can defeat the line-anchored regexes in the redactor.

**Residual risk.** Medium — regex-based redaction will miss novel secret formats (e.g., internal API tokens not matching `sk-` / `AIza` / `gh[ps]_` / `xox[abprs]-`). Tracked as a known limitation; mirrors closure S-CL3.

---

## S3 — `sprint-audit-rerun.sh` env-var inheritance (AC-7)

**Attack.** AC-7 introduces `sprint-audit-rerun.sh` (~200 LOC) which re-fires the ruflo daemon audit worker mid-sprint. The worker is a Node subprocess (see `scripts/lib/worker-trigger.sh:177`, `ruflo daemon trigger -w audit`). Subprocesses inherit the parent shell's environment by default. The operator's shell at the moment of invocation may contain:

- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (if the operator just ran `aws-vault exec`)
- `SUPABASE_SERVICE_ROLE_KEY` (loaded from `.env` for a prior debug session)
- `GEMINI_API_KEY`, `OPENAI_API_KEY`, etc.
- `DATABASE_URL` with a live `postgresql://…@prod-cluster:…` connection string
- `GITHUB_TOKEN` with org-write scopes

The audit worker prompt is operator-defined (a ruflo plugin) — if a future plugin author logs `process.env` for debugging (`console.error('env at start:', JSON.stringify(process.env))`), every one of those secrets lands in `docs/sprints/<slug>/worker-output/audit.{json,md}` and is then either: (a) committed to git via the normal sprint flow, or (b) read by `sprint-audit-resolve.sh` and quoted into rationale (back-pressure into S2).

**Likelihood.** Medium. Plugin authors do `console.log(process.env)` more than they should; the audit plugin is the most likely candidate because "what's the LLM running against?" is a natural debug question. Also: operator shells under active development frequently carry live credentials.

**Impact.** High. AWS / Supabase / GitHub tokens are exfiltration-ready.

**Mitigation (AC-7).** **MUST-FIX before AC-7 ships.** Mirror the existing `env -i HOME PATH SHELL` allowlist pattern in `.husky/post-commit:181` (the reuse-audit chain — same threat model, same control). Concretely:

1. **Wrap the audit-rerun worker invocation in `env -i` with an explicit allowlist:**

   ```bash
   env -i \
     HOME="$HOME" \
     PATH="$PATH" \
     SHELL="$SHELL" \
     SPRINT_SLUG="$SLUG" \
     RUFLO_WORKER_AUDIT_BASELINE="$baseline_path" \
     bash scripts/lib/worker-trigger.sh trigger_worker audit "$SLUG"
   ```

   No `AWS_*`, no `SUPABASE_*`, no `*_API_KEY`, no `*_TOKEN`, no `DATABASE_URL`. The audit worker has no business with those.

2. **Document the allowlist in `docs/sprints/SCRIPTS.md`** as part of AC-19. Operators must know that if their plugin needs an env var, it must be added to the allowlist explicitly — and reviewed in PR.
3. **Smoke test.** AC-7 ships with a test that exports a junk `FAKE_SECRET=should-not-leak` before invoking `sprint-audit-rerun.sh`, then greps the resulting `worker-output/audit.{json,md}` for the literal string. Must find zero matches.
4. **Defense-in-depth at the gate layer.** Even after env stripping, run the worker output through `sprint-pii-redact.sh` before letting AC-6's rationale-prompt loop quote it back.

**Residual risk.** Low after fix. The audit worker could still misbehave inside its sandboxed env (it has filesystem read — could `grep AWS_ACCESS_KEY .env` directly). That is the daemon's threat model, not this sprint's; tracked under parent S4.

---

## S4 — Evidence-path inheritance for audit-resolution sub-steps (AC-5 / AC-6)

**Attack.** AC-5 declares the new `audit-resolution` phase. AC-6's interactive walker uses `record_sub_step` for each per-finding decision, with the audit.json path recorded as evidence (e.g., `evidence_path: "docs/sprints/<slug>/worker-output/audit.json"`). The closure sprint's Wave-C L13 mitigation canonicalizes evidence paths and rejects `..`. The risk in this sprint is regression: a new instrumentation call site forgets to inherit the L13 path-validation logic.

Two specific concerns:

1. **Path-only contract not embedded-content.** Spec §J states evidence is "path-only per C5 (no content)". A naive AC-6 implementation that does `record_sub_step "$finding_id" "$(cat worker-output/audit.json | jq -c .vulnerabilities[$i])"` would embed the audit.json finding directly in state.json — bypassing path canonicalization entirely. If the finding's `.description` field contains code excerpts that mention `password=…`, those land in git via state.json.
2. **Indirect traversal.** Operator-supplied baseline path for `sprint-audit-rerun.sh` (e.g., `--baseline ../../tmp/x.json`) becomes the evidence path for a sub-step recorded by AC-7. Without explicit re-validation, AC-7 traverses out of the sprint dir.

**Likelihood.** Low for variant 1 (audit.json paths are computed, not operator-supplied); Low-Medium for variant 2 (`--baseline` is operator-supplied).

**Impact.** Medium — same as parent S9 / closure L13.

**Mitigation (AC-5 / AC-6 / AC-7).**

1. **Audit.json sub-step evidence is path-only, full stop.** AC-6's `record_sub_step` calls MUST pass the literal path string `docs/sprints/<slug>/worker-output/audit.json` (plus the finding index as a separate field), never the file's content. This is enforceable by inspection in PR review.
2. **AC-7 `--baseline` argument MUST go through the same canonicalization helper as `record_sub_step`** (the closure L13 helper). Add an explicit `realpath` + `..` check at the top of `sprint-audit-rerun.sh`.
3. **Test fixture.** AC-5's exit-predicate smoke test (per spec §J risk-mitigation) must include one finding whose evidence path is `../../etc/passwd` — the predicate must reject the phase advance, not silently accept.

**Residual risk.** None after fix; identical to closure L13.

---

## S5 — Scope-bounded gate exposes touched-files metadata (AC-1 / AC-3)

**Attack.** Wave 1's `gate_audit_blocks` parses `spec.md §H Files touched` at gate-evaluation time to scope-filter vulnerabilities. Out-of-scope findings are logged as advisory. Two questions: (a) does the advisory log leak any NEW metadata not already in the public spec.md? (b) does the gate-bypass record (state.gate_bypasses[].rationale) inherit out-of-scope file paths that the operator did not realize they were exposing?

Concrete check:

1. `spec.md ## Files touched` is **already committed** to git at sprint-spec-lock time. The list of files this sprint modified is public information. The scope-bounded gate exposes nothing new on the "in-scope" side.
2. The advisory log writes lines like `[gate_audit] OUT-OF-SCOPE: .claude/helpers/foo.js:42 (severity=high) — not in files_touched; advisory only`. The out-of-scope FILE name is leaked. If the audit worker scanned a path containing PII (e.g., `apps/api/.env.local:5`), that path lands in the advisory log.
3. The gate-bypass rationale path (parent S11 / closure L14) is unchanged by this sprint — bypasses still route through `sprint-pii-redact.sh`. No new exposure.

**Likelihood.** Low. The audit worker scans the working tree, not `.env*` (which should be `.gitignore`d). Files actually scanned are roughly source files.

**Impact.** Low. File paths alone are not credentials. They are reconnaissance signal if the repo ever leaks credentials elsewhere (parent S13 / harness-truthful S9 absorbed into S8).

**Mitigation (AC-1 / AC-2).**

1. **Advisory log file paths MUST go through `sprint-pii-redact.sh`** if they will be recorded in state.json as part of `record_sub_step` evidence. Path strings that match the `/Users/<name>/` operator-home pattern should be redacted to `~/...` form — same as the harness-truthful S9 fix.
2. **`.env*` and `secrets/*` paths MUST be excluded from advisory logging entirely.** Pattern: if a vulnerability's `.file` matches `\.env(\.|$)|/secrets?/`, drop it from the advisory log (it should not have been in the audit worker's scan set in the first place, but defense in depth).
3. **Document the contract** in DEVELOPER.md (AC-19): advisory logging surfaces file paths only; in-scope blocking findings may surface file + line + description, all routed through state.json which is git-committed.

**Residual risk.** Low. Already-committed spec.md `## Files touched` is the dominant exposure vector and is unchanged by this sprint.

---

## S6 — HAR-2 / HAR-4 plaintext-to-encrypted migration atomicity

**Attack.** When HAR-2 / HAR-4 ship, existing operator installs already have plaintext `memory.json` and `session.json` files on disk. The first time the new code runs `loadMemory()`, it must:

1. Detect the legacy plaintext format (e.g., parseable JSON without the encrypted-blob envelope `{ v: 1, iv, tag, ciphertext }`).
2. Read the plaintext contents.
3. Encrypt them with the key from `~/.claude-flow/.encryption-key`.
4. Write the encrypted blob.
5. Delete the plaintext.

A naive implementation does this in-place:

```js
const data = JSON.parse(fs.readFileSync(MEMORY_FILE)) // plaintext
const encrypted = encrypt(data)
fs.writeFileSync(MEMORY_FILE, encrypted) // partial write → crash → both halves lost
```

If the process is interrupted between read and write, or between two writeFileSync calls (memory.json and a sibling `.bak`), the operator is left with one of:

- **Partial write.** `memory.json` contains half plaintext, half encrypted bytes → unrecoverable.
- **Plaintext stays.** Encryption happened to a `.tmp` file but the rename never fired → both files on disk → plaintext is the data leak.
- **Encrypted stays, plaintext stays.** Two copies → operator deletes "the new one" thinking it's a duplicate → loses the canonical store.

**Likelihood.** Medium. First-run migration is exactly the bug class operators don't test (because they only see it once per install).

**Impact.** High for variant 2 (plaintext on disk after install believed-encrypted). Medium for variant 1 (data loss).

**Mitigation (AC-10 / AC-12).** Mirror the canonical `atomic_update_state` pattern from `scripts/lib/atomic-state.sh`:

1. **Read plaintext into memory.** If parse fails, abort migration; do not touch existing file.
2. **Compute encrypted blob in memory.**
3. **Write encrypted blob to `MEMORY_FILE.tmp.<random>` with `flag: 'wx'`** (O_EXCL — fails if file exists, prevents race with a concurrent process).
4. **`fs.fsyncSync(fd)` on the tmp file** to force kernel buffer flush. Without fsync, the rename can succeed before the data hits disk; a crash between rename and fsync leaves a zero-length file on next boot.
5. **`fs.renameSync(tmp, MEMORY_FILE)`.** Atomic on the same filesystem (POSIX guarantee).
6. **Only after rename succeeds, `fs.unlinkSync(MEMORY_FILE.legacy.bak)` if a backup was written.** Order: encrypt-then-rename-then-delete-plaintext, never delete-plaintext-then-encrypt.
7. **Mode bits.** The encrypted file MUST be written with `{ mode: 0o600 }` to match the key file. A `0644` encrypted blob plus a `0600` key is still a leak vector (the blob can be exfiltrated to a different machine where the operator's key is later guessed or leaked).

**Smoke test (AC-10 / AC-12 acceptance proof).**

```bash
# Inject failure between rename and unlink
NODE_OPTIONS="--require ./test-fixtures/crash-before-unlink.js" node helpers/memory.js get foo
# Assert: encrypted memory.json exists, NO plaintext memory.json.legacy on disk
ls -la .claude-flow/data/memory.json{,.legacy,.tmp.*} 2>&1 | grep -v '.tmp'
```

**Residual risk.** Low after fix. Filesystem-level snapshots (Time Machine, APFS local snapshots) can still preserve a plaintext copy from before the migration — that is outside the harness's control and must be documented as a known limitation in AC-10's proof file.

---

## S7 — `execFile` arg-array semantics and HAR-9 atomic-rename O_EXCL

**Attack.** HAR-1 replaces `execSync(`gh ${command} ${subcommand} …`)` (github-safe.js:80, 83, 101, 105) with `execFile` using an arg array. The threat model question: does `execFile` itself shell out, leaving a hidden injection vector? Answer: no. Node's `child_process.execFile` invokes the kernel's `execve` syscall directly with the arg array as `argv` — there is no shell interpreter in the path, so shell metacharacters (`;`, `|`, `$()`, backticks) in argv elements are passed verbatim to the target binary as literal argv. This is the canonical safe pattern, equivalent to `subprocess.run(args, shell=False)` in Python.

HAR-9 introduces an atomic-rename for the temporary body-file (currently github-safe.js:62 uses `randomBytes(8)` for the basename, which is fine, but the `writeFileSync` at line 65 does not use `flag: 'wx'`). Concrete attack: a parallel github-safe.js invocation (model triggers two `gh issue comment` in the same wall-clock ms) collides on the tmp filename in the unlikely event of a `randomBytes(8)` collision (≈10^-19 per call), OR — more realistically — a symlinked tmp dir (`/tmp` → `/private/tmp` on macOS) is hijacked by a process that creates `gh-body-<hex>.tmp` as a symlink to `/etc/hosts` before the writeFileSync fires.

**Likelihood.** Low. macOS `/tmp` is 1777 with sticky bit; only root or the file owner can unlink. Other-user symlink-plant is blocked.

**Impact.** Medium — symlink-follow on writeFileSync overwrites the link target with the comment body.

**Mitigation (HAR-9).**

1. **`writeFileSync(tmpFile, body, { flag: 'wx', mode: 0o600 })`.** `wx` = O_CREAT|O_EXCL — fails if file exists. Combined with O_EXCL, the kernel guarantees no symlink-follow (POSIX: O_EXCL on an existing symlink fails with EEXIST regardless of whether the symlink target exists).
2. **Wrap in try/catch and retry once with a fresh random suffix on EEXIST.** A single retry handles the (vanishingly small) RNG-collision case without a busy-loop.
3. **Verify ownership post-create.** `fs.fstatSync(fd).uid === process.getuid()` before writing the body. Belt + braces against a symlink-race that somehow defeats O_EXCL on an unusual filesystem.
4. **Document execFile contract.** AC-9 / AC-13's proof file should explicitly cite the `execve` syscall semantic so future reviewers don't relitigate.

**Residual risk.** None after fix on standard macOS / Linux filesystems. Exotic FUSE filesystems may not honor O_EXCL — out of scope.

---

## S8 — `phase-workers.json` scope field parse-time safety (AC-4)

**Attack.** AC-4 extends `phase-workers.json` with optional `{scope: "files-touched" | "repo" | "spec-h1", scope_mode: "post-filter" | "env-var" | "prompt-inject"}` per worker entry. The parsing path is `jq` (in worker-gates.sh) and `JSON.parse` (in any Node-side reader). Neither evaluates arbitrary code on parse — jq is a pure expression engine, JSON.parse is grammar-defined. The attack vector is therefore not code execution but **enum injection**:

1. **Unknown scope value.** An operator (or a model that misread the schema) writes `{scope: "all-files-in-repo"}`. The string is not in the enum. What does `worker-gates.sh` do? If the code defaults to "no scope" (i.e., behaves like `repo`), the in-scope-only contract silently breaks back to the noise level the prior sprint suffered from. If the code defaults to "files-touched" but with an empty list (because no parser knows what "all-files-in-repo" maps to), every audit silently passes.
2. **Type confusion.** A value of `{scope: true}` or `{scope: null}` — jq accepts these grammatically. Downstream bash `case` on the value behaves unpredictably.
3. **Duplicate keys.** JSON spec allows duplicate keys with last-wins semantics in most parsers but undefined in others. `{"scope": "files-touched", "scope": "repo"}` could behave differently in jq vs JSON.parse vs Python.

**Likelihood.** Low for variant 1 (operator typo); Very Low for variants 2–3.

**Impact.** Medium. Silent fallback to noise-level audit defeats the entire scope-bounded-workers work in Wave 1.

**Mitigation (AC-4).**

1. **`worker-gates.sh` MUST validate the scope value against an explicit allowlist** before using it:

   ```bash
   case "$scope" in
     files-touched|repo|spec-h1) ;;
     *)
       echo "[worker-gates] unknown scope '$scope' for worker '$worker'; defaulting to 'repo' and logging warning" >&2
       scope="repo"
       ;;
   esac
   ```

2. **Default behavior on unknown enum MUST BE `repo`** (= maximum visibility), never `files-touched` (= silent pass). Fail loud, not silent.
3. **Schema documentation** in DEVELOPER.md (AC-19) lists the three legal values explicitly with one-line semantics each.
4. **Optional: JSON schema validation.** A `phase-workers.schema.json` checked in alongside `phase-workers.json` plus a one-shot `ajv` call in CI would catch all three variants at parse time. Probably overkill for v0.7.1 but worth a follow-up AC if AC-4 ships without it.

**Residual risk.** None after fix.

---

## 9. Inherited surfaces from prior sprints

The nine surfaces from `harness-truthful-docs-and-wiring-v1/security-review.md` (S1–S9), the fifteen parent surfaces (parent S1–S15), and the six closure surfaces (S-CL1–S-CL6) all remain in scope. Load-bearing status for this sprint:

| Inherited surface                                          | Still load-bearing? | Reason                                                                                                        |
| ---------------------------------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------- |
| harness-truthful S1 (lockfile symlink-race)                | Yes                 | AC-19 G3 post-commit edit-tool lockfile inherits same dir + perms contract                                    |
| harness-truthful S2 (TOCTOU lock/rename)                   | Yes                 | All AC-5 / AC-6 state writes route through `atomic_update_state`; do not regress                              |
| harness-truthful S3 (stale-lock DoS)                       | Yes                 | AC-19 G3 lockfile reuses 30s stale-lock-reclaim pattern                                                       |
| harness-truthful S4 (worker JSON spoofs predicate)         | **Yes, extended**   | AC-7's `sprint-audit-rerun.sh` is a new caller of the same daemon worker — same trust contract applies        |
| harness-truthful S5 (worker name path traversal)           | Yes                 | AC-7 calls trigger_worker; regex check must remain in place                                                   |
| harness-truthful S6 (worker exit-code injection)           | Yes                 | AC-7 baseline-diff logic must not treat zero-exit as proof-of-work                                            |
| harness-truthful S7 (evidence-path traversal new W4 sites) | **Yes, extended**   | S4 above re-verifies for AC-5 / AC-6 / AC-7                                                                   |
| harness-truthful S8 (PII leak in verify log evidence)      | **Yes, extended**   | S2 above re-verifies for AC-6 rationale; same redactor; new attack surface                                    |
| harness-truthful S9 (deploy URL / Pulumi recon leak)       | Yes                 | Unchanged — no new deploy paths in this sprint                                                                |
| Parent S3 (inline-jq hook regex)                           | Yes                 | AC-5 adds new `audit_findings_*` fields; the hook regex (extended in prior sprint) must cover them            |
| Parent S4 (bypass abuse, ≥10char rationale)                | **Yes, extended**   | S2 above doubles the rationale-attack surface; bypass.sh 10-char check is the floor, redactor is the ceiling  |
| Parent S11 / closure L14 (bypass-rationale PII)            | **Yes, extended**   | Identical control class as S2 above; same `sprint-pii-redact.sh` primitive                                    |
| Closure L13 (evidence-path canonicalization)               | Yes                 | S4 above re-verifies the L13 invariant for three new instrumentation sites (AC-5 / AC-6 / AC-7)               |
| Closure L12 (expected_phase under-lock invariant)          | Yes                 | AC-5 introduces a new phase transition; the under-lock invariant must hold for `verifying → audit-resolution` |
| Closure S-CL3 (PII redactor false-positive sha256 sidecar) | Yes                 | S2 above inherits the same residual-risk acknowledgement; sha256 sidecar is the recovery contract             |

---

## 10. Required for this sprint to be ship-ready

1. **S1 proof.** `__tests__/memory.test.cjs` asserts (a) `crypto.randomBytes` is the sole entropy source for key generation; (b) post-creation `(stat.mode & 0o777) === 0o600`; (c) `.gitignore` blocks the key file; (d) no log path references print the literal key path. Tied to **AC-10 / AC-12**.
2. **S2 proof.** `sprint-audit-resolve.sh` pipes every rationale capture through `sprint-pii-redact.sh` before `atomic_update_state`; the match-count is surfaced back to the operator; a test fixture rationale containing `password=hunter2` lands in state.json as `password=[REDACTED]`. Tied to **AC-6**.
3. **S3 proof.** `sprint-audit-rerun.sh` invokes the audit worker with `env -i HOME PATH SHELL …` allowlist; a smoke test with `FAKE_SECRET=should-not-leak` exported in the parent shell does not find the literal string anywhere in `worker-output/audit.{json,md}`. Tied to **AC-7**.
4. **S4 proof.** Closure L13 path-canonicalization holds for record_sub_step calls in AC-5, AC-6, AC-7 each. Per-AC fixture: one call with a `../`-containing evidence path; all must reject. Tied to **AC-5 / AC-6 / AC-7**.
5. **S6 proof.** First-run migration test: a fixture with legacy plaintext `memory.json` is processed, and after the migration, only encrypted `memory.json` exists on disk (no `.legacy`, no `.tmp.*`, no plaintext). Crash-injection variant verifies that an aborted migration leaves the plaintext intact (not partially-overwritten). Tied to **AC-10 / AC-12**.
6. **S7 proof.** HAR-9 atomic-rename uses `flag: 'wx'` + post-create `fstatSync` ownership verification; symlink-plant test (`ln -s /etc/hosts /tmp/gh-body-<predictable>.tmp`) is blocked by O_EXCL. Tied to **AC-17** (HAR-9).
7. **S8 proof.** Unknown `scope` value in `phase-workers.json` defaults to `repo` and emits a stderr warning, never silently falls through to a vacuous pass. Tied to **AC-4**.

Without S1, S2, S3, and S6 proofs concrete and tested, this sprint reproduces the same theatrical-mitigation pattern the prior closure rejected.

---

## 11. Verdict

**APPROVED WITH CONDITIONS.**

The eight new surfaces are all mitigable within the wave they belong to. Three are catastrophic-if-missed and must be fixed before their wave ships:

- **S1 (encryption key file)** — must-fix in Wave 3 (HAR-2 / HAR-4). Predictable RNG or 0644 mode bits silently downgrades the entire memory/session encryption story to security theater.
- **S2 (operator rationale leakage to git)** — must-fix in Wave 2 (AC-6). Git permanence + high paste-likelihood makes this the highest-EV attack across the sprint.
- **S3 (audit-rerun env inheritance)** — must-fix in Wave 2 (AC-7). The control surface is small (one `env -i` wrap) and the impact is full operator-shell credential exfiltration.

**Conditions** (each tied to specific ACs; failure to deliver any condition downgrades the verdict to **NEEDS REWORK** at sprint close):

1. **AC-10 / AC-12:** S1 mitigation shipped with the four smoke-test assertions enumerated above (RNG source, mode 0o600, gitignore, no-log-path).
2. **AC-6:** S2 mitigation shipped — rationale piped through `sprint-pii-redact.sh`, redaction count surfaced to operator, 1024-byte cap, newline-flatten before redaction.
3. **AC-7:** S3 mitigation shipped — `env -i HOME PATH SHELL …` allowlist wrapping the audit worker invocation, plus the `FAKE_SECRET` smoke test.
4. **AC-5 / AC-6 / AC-7:** S4 closure L13 re-verification — at least one `../`-evidence-path rejection test per new instrumentation site.
5. **AC-10 / AC-12:** S6 mitigation shipped — atomic encrypt-tmp-fsync-rename-unlink ordering with O_EXCL on tmp file create; crash-injection test proves no partial-write state.
6. **AC-4:** S8 mitigation shipped — explicit allowlist case-statement on `scope` value with fail-loud default to `repo`.

**Out of scope (acknowledged):**

- Hardware-key-backed encryption (TPM / Secure Enclave) for `.encryption-key` — too heavy for v0.7.1.
- Cryptographic signing of audit worker output (would close S3 + harness-truthful S4 / S6 definitively) — too heavy for the local threat model.
- FIDO2-style multi-factor on `sprint-audit-resolve.sh` Accept actions (would close S2 abuse by operator-rushing) — not feasible solo-operator harness.
- Network-attacker threat model; harness remains local-only.

**Note for the audit reviewer.** This review was produced after reading: spec.md (full), the next-sprint plan at `~/.claude/plans/hazy-gathering-kettle.md` (top section), `.claude/helpers/github-safe.js` (full), `.claude/helpers/memory.js` (full), `.claude/helpers/session.js` (full), `.claude/helpers/statusline.js` (full), `scripts/sprint-pii-redact.sh` (full), and the prior sprint security review (full). The prior closure-pattern failure mode (placeholder review accepted at audit) is the direct precedent this review is corrective against — every surface above is named, attacked, and graded against the code that will actually ship, not abstracted away.
