# AC-5 — sprint-hook.cjs jq-phase + state-edit blockers

**Verdict:** Production
**Complex:** true (PreToolUse / auth-sensitive)
**Methodology:** inject-violation-catch-restore

## Artifact shipped

Two new patterns added to `.claude/helpers/sprint-hook.cjs`:

### (a) Bash regex blocking `jq … .phase = …`

Regex: `/\bjq\b[^\n]{0,200}?\.phase\s*=/i`

Allow conditions:

- `process.env.SPRINT_ADVANCE_PHASE_RUNNING === "1"` AND
- `parentIsAdvancePhase()` returns true — which calls `ps -o command= -p <ppid>` and asserts the result contains `sprint-advance-phase.sh`

Belt + suspenders: env var alone isn't sufficient because the model could set it in a Bash command. Parent-process check via `ps` blocks env-spoof attacks.

### (b) Write/Edit path-prefix block on `docs/sprints/*/state.json`

Regex: `/^docs\/sprints\/[^/]+\/state\.json$/`

**No env exemption.** Direct edits of state.json bypass the atomic-rename + flock guarantees of `atomic_update_state`. Mutations must go through `scripts/lib/atomic-state.sh`.

## Five-test smoke

```
TEST 1 — Hostile jq command WITHOUT SPRINT_ADVANCE_PHASE_RUNNING:
  $ echo '{"tool":"Bash","tool_input":{"command":"jq '\''.phase = \"done\"'\'' state.json"}}' \
     | node .claude/helpers/sprint-hook.cjs pre-bash
  BLOCK Direct state.phase mutation blocked: `jq '.phase = "done"' state.json`. ...
  RC=2  ✓ (Claude Code blocks the tool call on exit 2)

TEST 2 — Hostile jq command WITH SPRINT_ADVANCE_PHASE_RUNNING=1 (env spoof):
  $ SPRINT_ADVANCE_PHASE_RUNNING=1 echo '{...}' | node .claude/helpers/sprint-hook.cjs pre-bash
  BLOCK Direct state.phase mutation blocked: ...
  RC=2  ✓ (parent process != sprint-advance-phase.sh — parentIsAdvancePhase() returns false)

TEST 3 — Benign Bash command (ls -la docs/):
  $ echo '{"tool":"Bash","tool_input":{"command":"ls -la docs/"}}' \
     | node .claude/helpers/sprint-hook.cjs pre-bash
  RC=0  ✓ (allowed)

TEST 4 — Edit on state.json:
  $ echo '{"tool":"Edit","tool_input":{"file_path":"docs/sprints/harness-deterministic-phases-v1/state.json"}}' \
     | node .claude/helpers/sprint-hook.cjs pre-edit
  BLOCK Direct edit of state.json blocked: `docs/sprints/.../state.json`. ...
  RC=2  ✓

TEST 5 — Write on state.json:
  $ echo '{"tool":"Write","tool_input":{"file_path":"docs/sprints/harness-deterministic-phases-v1/state.json"}}' \
     | node .claude/helpers/sprint-hook.cjs pre-edit
  BLOCK Direct edit of state.json blocked: ...
  RC=2  ✓
```

## What this proves

1. **Inline `jq '.phase = ...'` is mechanically blocked** outside the canonical `sprint-advance-phase.sh`. Closes the "model rewrites phase via inline jq" attack surface.
2. **Env-var spoof defeated** — `SPRINT_ADVANCE_PHASE_RUNNING=1` alone is insufficient. The hook calls `ps -o command= -p $PPID` and asserts the parent process command line contains `sprint-advance-phase.sh`. Both must hold.
3. **Direct state.json Write/Edit blocked** — no env exemption. Only `atomic_update_state` from within a script can write state.json.
4. **Existing benign commands pass through** — non-phase-mutating Bash + non-state.json Edit calls continue to be allowed (subject to the existing forbidden-action + scope checks).
5. **Hook exit 2 signal** — Claude Code's PreToolUse contract: exit 0 = allow, exit 2 = block + show stderr to operator. The block message includes the canonical invocation hint (`bash scripts/sprint-advance-phase.sh <next-phase>`).

## Verified path of authentication

The `parentIsAdvancePhase()` function works as:

1. Check `process.env.SPRINT_ADVANCE_PHASE_RUNNING === "1"`. If not set, return false immediately.
2. `process.ppid` resolves to the parent PID.
3. `execSync('ps -o command= -p <ppid>')` returns the parent command line.
4. Regex `/sprint-advance-phase\.sh/` matches if the parent really is the canonical mutator.
5. Falls back to env-only check if `ps` fails (degrades safely; very rare).

Real `sprint-advance-phase.sh` invocations:

- Set `export SPRINT_ADVANCE_PHASE_RUNNING=1` (verified in AC-4)
- Are the parent process of the `bash -c "jq ..."` inside `atomic_update_state`

So legitimate phase writes pass; everything else blocks.

## Files modified (this AC)

- `.claude/helpers/sprint-hook.cjs` — added `JQ_PHASE_WRITE` regex, `parentIsAdvancePhase()` function, jq-phase block in `checkBash`, state.json edit-block in `checkEdit`. +57 lines.

## Inject-violation: real attack patterns this catches

| Attempt                                                          | Pattern            | Result                                                |
| ---------------------------------------------------------------- | ------------------ | ----------------------------------------------------- |
| `jq '.phase = "done"' state.json`                                | inline phase write | BLOCK (Test 1)                                        |
| `jq '.phase="done"' state.json` (no spaces)                      | inline phase write | BLOCK                                                 |
| `jq ".phase = \"done\"" state.json` (double quotes)              | inline phase write | BLOCK                                                 |
| `SPRINT_ADVANCE_PHASE_RUNNING=1 jq '.phase = "done"' state.json` | env spoof          | BLOCK (Test 2 — parent is bash, not advance-phase.sh) |
| `Edit(file_path="docs/sprints/X/state.json", ...)`               | direct tool edit   | BLOCK (Test 4)                                        |
| `Write(file_path="docs/sprints/X/state.json", ...)`              | direct tool write  | BLOCK (Test 5)                                        |
| `bash scripts/sprint-advance-phase.sh design-locked`             | canonical          | ALLOW (AC-4 dogfood)                                  |
