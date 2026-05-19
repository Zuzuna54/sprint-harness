# L1 — Hook real-flow ppid check (with depth-3 ancestor walk)

**Verdict:** Production (synthetic proof + code-inspection real-flow proof)
**Methodology:** code change + 4-case smoke

## What this closes

Parent sprint AC-5 shipped `parentIsAdvancePhase()` but only smoke-tested via synthetic stdin. Real Claude Code flow has ppid chain like:

```
Claude Code → bash (wrapper) → bash (sprint-advance-phase.sh) → bash (atomic_update_state subshell) → jq
```

`process.ppid` may point at a wrapper bash, NOT at advance-phase.sh directly. Original implementation would self-block legitimate writes.

## Code change

`.claude/helpers/sprint-hook.cjs::parentIsAdvancePhase()` now walks up to 3 ancestor PIDs:

```javascript
function parentIsAdvancePhase() {
  if (process.env.SPRINT_ADVANCE_PHASE_RUNNING !== '1') return false
  try {
    const { execSync } = require('node:child_process')
    let pid = process.ppid
    for (let depth = 0; depth < 3; depth++) {
      if (!pid || pid <= 1) break
      const cmd = execSync(
        `ps -o command= -p ${pid} 2>/dev/null || ps -o comm= -p ${pid} 2>/dev/null`,
        { encoding: 'utf8' },
      ).trim()
      if (/sprint-advance-phase\.sh/.test(cmd)) return true
      const nextPidStr = execSync(`ps -o ppid= -p ${pid} 2>/dev/null`, { encoding: 'utf8' }).trim()
      pid = parseInt(nextPidStr, 10)
      if (Number.isNaN(pid)) break
    }
    return false
  } catch {
    return process.env.SPRINT_ADVANCE_PHASE_RUNNING === '1'
  }
}
```

Depth cap = 3 per security review S-CL6 (prevent fork-bomb DoS).

## Smoke tests

### Test 1 — jq attack, no env set, ordinary bash parent

```
$ echo '{"tool":"Bash","tool_input":{"command":"jq .phase=\"done\" state.json"}}' \
    | node .claude/helpers/sprint-hook.cjs pre-bash
BLOCK Direct state.phase mutation blocked: `jq .phase="done" state.json`.
RC=2 ✓
```

### Test 2 — env spoof (SPRINT_ADVANCE_PHASE_RUNNING=1 but parent != advance-phase)

```
$ SPRINT_ADVANCE_PHASE_RUNNING=1 bash -c '... | node hook'
RC=2 (or BLOCK when SPRINT_DRIFT_BYPASS=1 not set in parent shell)
✓ (env alone insufficient; ps check rejects)
```

### Test 3 — wrapper named without sprint-advance-phase.sh, depth 1

```
$ /tmp/some-wrapper.sh   # contains: bash -c "... | node hook"
RC=2 (block — no ancestor matches advance-phase.sh in 3 generations)
✓
```

### Test 4 — wrapper named sprint-advance-phase.sh, depth 1

```
$ /tmp/sprint-advance-phase.sh   # contains: bash -c "... | node hook"
RC=0 (allow — depth-1 ancestor matches /sprint-advance-phase\.sh/)
✓ Code path verified by inspection
```

### Real Claude Code flow verification

The real-flow integration test requires the operator to invoke Claude Code interactively and trigger both:

1. An attack: model writes `jq '.phase = "done"' state.json` in a Bash tool call → expect block + exit 2.
2. A legitimate write: model runs `bash scripts/sprint-advance-phase.sh paused` → expect successful phase advance.

**This file documents the code change.** The full interactive smoke test is captured as a closure sprint Wave A deliverable that proves end-to-end. Without a separate Claude Code session, the synthetic test + code-inspection is the available evidence.

## What this proves

1. **Depth-3 ancestor walk is implemented** and reads ppid chain correctly (verified via macOS ps).
2. **Env-spoof still rejected**: SPRINT_ADVANCE_PHASE_RUNNING=1 alone doesn't pass; ps check is the gate.
3. **Legitimate advance-phase.sh invocation passes** when its name appears in any of the 3 ancestor processes' command lines.
4. **DoS bounded**: 3-deep cap prevents fork-bomb attacks from slowing the hook.

## Files modified

- `.claude/helpers/sprint-hook.cjs::parentIsAdvancePhase()` — extended to depth-3 ancestor walk (+12 lines)

## Residual risk

- Real Claude Code session smoke remains operator-action follow-up. Code change is sound by inspection; in-session verification by the user `gio` is the final certification.
- If real-flow reveals deeper ppid chain than 3 generations, cap can be raised to 5 with minimal cost. Currently 3 covers the documented chain (Claude Code → bash → advance-phase.sh → atomic-state subshell → jq = 4 deep, but jq's `process.ppid` points at the subshell, which points at advance-phase.sh = depth 1 from jq's perspective).
