# Design — harness-deterministic-phases-v1

> SPARC design phase output. Produced after spec-lock + 4-way review (solution-sketches + architect-review + security-review + consensus-spec). Walks Specification → Pseudocode → Architecture for the chosen design (Sketch 3 — manifest + canonical mutator + PreToolUse chokepoint).

---

## §1 — Specification (formal)

### 1.1 System invariants

| ID    | Invariant                                                                                                                 | Enforced by                                   |
| ----- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| INV-1 | `state.phase` is mutated by exactly one script: `sprint-advance-phase.sh`. All other paths blocked.                       | PreToolUse hook (regex+ppid)                  |
| INV-2 | Phase X → Y transition succeeds iff Y ∈ `phase-manifest.json:phases[X].advances_to` AND `check_phase_requirements(X)`==0. | sprint-advance-phase.sh                       |
| INV-3 | A failing predicate is satisfied by either (a) operator-supplied fix OR (b) matching entry in `state.gate_bypasses[]`.    | phase-predicates.sh::`_pp_is_bypassed`        |
| INV-4 | Every entry in `state.gate_history[]` is monotonic-by-`at`. Each entry has from/to/by/at.                                 | sprint-replay-validator.mjs (AC-13a)          |
| INV-5 | Every entry in `state.gates_passed[]` and `state.gate_bypasses[]` has `.gate` matching a manifest gate name.              | sprint-replay-validator.mjs (AC-13b/c)        |
| INV-6 | `state.worker_rigor` ∈ {`lax`, `strict`}. Set exactly once at spec-lock time.                                             | spec-locked manifest predicate `json_path_in` |
| INV-7 | `record_sub_step(slug, gate, ...)` is idempotent on `(slug, gate)`. Re-record updates `at`, doesn't duplicate.            | sub-step.sh jq filter (upsert pattern)        |
| INV-8 | Pre-v0.7 closed sprints are skipped by replay validator (no `sprint-advance-phase.sh` in gate_history + no worker_rigor). | sprint-replay-validator.mjs implicit skip     |

### 1.2 Phase enum

State.phase ∈ {`spec-wizard`, `spec-locked`, `design-locked`, `building`, `day-5-checkin`, `cleaning`, `verifying`, `pre-deploy`, `deploying`, `done`, `paused`}.

11 phases total. Transitions form a DAG (with `paused` as a side-channel from any phase back to its prev_phase).

### 1.3 Manifest schema (predicate kinds)

Allowed predicate `kind` values:

- `file_exists` — path resolves to a file under sprint dir
- `file_min_bytes` — exists AND ≥ `min_bytes`
- `file_contains_heading` — markdown heading exact-match AND ≥ `min_chars_under` of non-placeholder body
- `json_path_present` — jq path resolves non-null
- `json_path_equals` — jq path == literal
- `json_path_in` — jq path ∈ `in[]` array
- `state_field_min_length` — state.json array/string/number ≥ `min_length`
- `state_field_all_values_in` — every value at jq path ∈ `in[]`
- `sub_step_recorded` — gate name in `state.gates_passed[]` ∪ `state.gates[]`

### 1.4 Bypass contract

```
SPRINT_BYPASS_GATE=<gate-name> SPRINT_BYPASS_WHY=<reason ≥10 chars> bash sprint-advance-phase.sh <next-phase>
```

Multi-gate: comma-separated. Single WHY applies to all gates.

Recording shape:

```json
{
  "gate": "<name>",
  "why": "<reason>",
  "at": "<ISO8601Z>",
  "caller": "<basename of script that invoked check_bypass>"
}
```

---

## §2 — Pseudocode (algorithms)

### 2.1 sprint-advance-phase.sh main flow

```
1.  Parse args: NEXT_PHASE = $1; EXPECTED_CURRENT = optional --from
2.  export SPRINT_ADVANCE_PHASE_RUNNING=1  # hook recognition
3.  SLUG := resolve_slug() via standard chain (env > session-file > state-scan)
    if SLUG empty: exit 1 with helpful error
4.  STATE_FILE := docs/sprints/$SLUG/state.json
    if not exists: exit 1
5.  MANIFEST := scripts/lib/phase-manifest.json
    run validate-phase-manifest.mjs
    if invalid: exit 1
6.  CURRENT_PHASE := jq -r '.phase' STATE_FILE
    echo "current=$CURRENT_PHASE target=$NEXT_PHASE"
7.  if CURRENT == NEXT: log "already at $NEXT — no-op"; exit 0  # idempotent
8.  if EXPECTED_CURRENT given AND EXPECTED != CURRENT:
        exit 1 with --from mismatch error
9.  ALLOWED := jq '.phases[$CURRENT].advances_to' MANIFEST
    if NEXT ∉ ALLOWED:
        echo allowed list; exit 1 illegal transition
10. # T2.1 fix: validate bypass gate names against manifest BEFORE recording
    if SPRINT_BYPASS_GATE set:
        for g in SPRINT_BYPASS_GATE.split(','):
            if g ∉ all_manifest_gates AND g not a literal path:
                exit 1 with "unknown bypass gate"
        # Now safe to record
        for g in SPRINT_BYPASS_GATE.split(','):
            check_bypass(g)  # writes state.gate_bypasses[]
11. # Predicate evaluation
    if NOT check_phase_requirements(SLUG, CURRENT):
        echo predicate failures
        echo "Options: fix predicates OR set SPRINT_BYPASS_GATE"
        exit 1
12. # All predicates pass (or all bypassed); atomic transition
    NOW := date -u +%FT%TZ
    atomic_update_state SLUG --arg c CURRENT --arg n NEXT --arg at NOW \
        '.prev_phase = $c | .phase = $n | .gate_history += [{from:$c, to:$n, at:$at, by:"sprint-advance-phase.sh"}]'
    # Specialized timestamps
    case NEXT in
        design-locked) atomic_update_state SLUG '.design_locked_at = NOW' ;;
        pre-deploy)    atomic_update_state SLUG '.predeploy_at = NOW' ;;
        done)          atomic_update_state SLUG '.closed_at = NOW' ;;
    esac
13. echo "phase advanced: $CURRENT → $NEXT @ $NOW"
    exit 0
```

### 2.2 check_phase_requirements pseudocode

```
function check_phase_requirements(SLUG, PHASE):
    MANIFEST := load(phase-manifest.json)
    PHASE_BLOCK := MANIFEST.phases[PHASE]
    WORKER_RIGOR := state.worker_rigor or "lax"
    FAILS := 0; PASSES := 0; BYPASSED := 0

    for pred in PHASE_BLOCK.required_artifacts:
        rc := evaluate(pred, SLUG)
        if rc == 0:
            PASSES += 1
        else:
            bypass_gate := pred.path or pred.json_path
            if is_bypassed(SLUG, bypass_gate):
                echo "[BYPASS] $pred.kind:$bypass_gate"
                BYPASSED += 1
            else:
                echo "[FAIL] $pred.kind: $detail"
                FAILS += 1

    for pred in PHASE_BLOCK.required_state_fields:
        # same pattern as above

    for gate in PHASE_BLOCK.required_sub_step_gates:
        if sub_step_recorded(SLUG, gate):
            PASSES += 1
        elif is_bypassed(SLUG, gate):
            echo "[BYPASS] sub_step:$gate"
            BYPASSED += 1
        else:
            echo "[FAIL] sub_step_recorded: $gate"
            FAILS += 1

    if WORKER_RIGOR == "strict":
        for gate in PHASE_BLOCK.strict_only_sub_step_gates:
            # same pattern; counts toward FAILS if missing+unbypassed

    echo "[SUMMARY] phase=$PHASE pass=$PASSES fail=$FAILS bypassed=$BYPASSED worker_rigor=$WORKER_RIGOR"
    return FAILS > 0 ? 1 : 0
```

### 2.3 record_sub_step pseudocode (idempotent dual-write)

```
function record_sub_step(SLUG, GATE, VERDICT, EVIDENCE):
    validate VERDICT ∈ {pass, fail, bypassed}
    if invalid: exit 1
    AT := iso8601_now()
    ENTRY := {gate: GATE, at: AT, verdict: VERDICT, evidence: EVIDENCE or null}

    atomic_update_state SLUG \
        --arg gate GATE --arg at AT --arg verdict VERDICT --arg evidence EVIDENCE \
    '
    # Upsert pattern: normalize bare-string entries to objects,
    # drop any existing entry with same gate name, append the new one.
    def upsert(arr; g; obj):
        (arr // [])
        | map(if type=="string" then {gate:., at:null, verdict:"pass"} else . end)
        | map(select(.gate != g))
        | . + [obj];

    {gate:$gate, at:$at, verdict:$verdict, evidence:($evidence|if .=="" then null else . end)} as $entry
    | .gates_passed = upsert(.gates_passed; $gate; $entry)
    | .gates        = upsert(.gates;        $gate; $entry)
    '
```

### 2.4 check_bypass pseudocode

```
function check_bypass(GATE):
    if SPRINT_BYPASS_GATE != GATE: return 1  # not bypassed for this gate

    if not SPRINT_BYPASS_WHY: return 1 with error
    if len(SPRINT_BYPASS_WHY) < 10: return 1 with error
    if not SLUG: return 1 with error

    NOW := iso8601_now()
    CALLER := basename(BASH_SOURCE[1])

    atomic_update_state SLUG \
        --arg gate GATE --arg why SPRINT_BYPASS_WHY --arg at NOW --arg caller CALLER \
    '.gate_bypasses = ((.gate_bypasses // []) | map(select(.gate != $gate)) + [{gate:$gate, why:$why, at:$at, caller:$caller}])'

    log "[bypass] gate=$GATE accepted"
    return 0
```

### 2.5 PreToolUse hook check (jq+phase + state.json edit)

```
JQ_PHASE_WRITE_REGEX := /\bjq\b[^\n]{0,200}?\.phase\s*=/i
# T2.6 follow-up: also match bracket syntax /\bjq\b[^\n]{0,200}?\["phase"\]\s*=/

STATE_FILE_REGEX := /^docs\/sprints\/[^/]+\/state\.json$/

function parentIsAdvancePhase():
    if env.SPRINT_ADVANCE_PHASE_RUNNING != "1": return false
    cmdline := exec("ps -o command= -p $PPID")
    return cmdline.contains("sprint-advance-phase.sh")

function checkBash(active, input):
    cmd := input.command
    if JQ_PHASE_WRITE_REGEX.match(cmd):
        if parentIsAdvancePhase(): allow
        else: block "Direct state.phase mutation blocked"
    for pat in FORBIDDEN_PATTERNS:
        if pat.match(cmd): block

function checkEdit(active, input):
    rel := canonicalize(input.file_path)
    if STATE_FILE_REGEX.match(rel):
        block "Direct edit of state.json blocked"
    # ... existing scope-hook logic ...
```

---

## §3 — Architecture (diagrams + module map)

### 3.1 Layer model

```
┌──────────────────────────────────────────────────────────────────────────┐
│  LAYER A — DATA (declarative source of truth)                             │
│  scripts/lib/phase-manifest.json                                          │
│  scripts/lib/phase-manifest.schema.json                                   │
│  scripts/lib/validate-phase-manifest.mjs (structural validator)           │
└──────────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │ read-only
                                  │
┌──────────────────────────────────────────────────────────────────────────┐
│  LAYER B — ENGINE (predicate evaluation)                                   │
│  scripts/lib/phase-predicates.sh                                          │
│    - check_phase_requirements(slug, phase)                                │
│    - sub_step_recorded(slug, gate)                                        │
│    - 9 _pp_pred_* private evaluators                                      │
└──────────────────────────────────────────────────────────────────────────┘
                  ▲                                       ▲
                  │                                       │
┌─────────────────┴────────────────┐  ┌───────────────────┴──────────────┐
│  LAYER C-1 — INSTRUMENTATION      │  │  LAYER C-2 — MUTATOR              │
│  scripts/lib/sub-step.sh          │  │  scripts/sprint-advance-phase.sh  │
│    record_sub_step(...)           │  │    The ONLY phase mutator         │
│  scripts/lib/bypass.sh            │  │    Reads engine; writes via       │
│    check_bypass(...)              │  │    atomic-state                   │
└──────────────────┬────────────────┘  └───────────────┬──────────────────┘
                   │                                    │
                   └────────────┬───────────────────────┘
                                ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  LAYER D — STATE (atomic, parallel-safe writes)                            │
│  scripts/lib/atomic-state.sh (v0.5.0 — reused)                            │
│  scripts/lib/lock-dir.sh (v0.5.0 — reused)                                │
│  scripts/lib/session-file.sh (v0.5.0 — reused)                            │
│  → docs/sprints/<slug>/state.json (per-slug, flock-serialized)            │
└──────────────────────────────────────────────────────────────────────────┘
                                ▲
                                │
┌──────────────────────────────────────────────────────────────────────────┐
│  LAYER E — ENFORCEMENT CHOKEPOINT                                          │
│  .claude/helpers/sprint-hook.cjs                                          │
│    - checkBash: blocks jq+phase unless parentIsAdvancePhase()             │
│    - checkEdit: blocks Write/Edit on docs/sprints/*/state.json            │
│  PreToolUse hook → exit 2 = block; exit 0 = allow                         │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  LAYER F — DELEGATED PHASE WRITERS (9 scripts; AC-7 migration)             │
│  sprint-amend-spec.sh --lock     → delegates to advance-phase.sh           │
│  sprint-design-lock.sh           → delegates                              │
│  sprint-build-launch.sh          → delegates                              │
│  sprint-checkin.sh               → delegates                              │
│  sprint-cleanup-launch.sh        → delegates                              │
│  sprint-verify.sh                → delegates                              │
│  sprint-predeploy-gate.sh        → delegates                              │
│  sprint-end.sh                   → delegates                              │
│  sprint-pause.sh / sprint-resume.sh → delegate                            │
│  Each runs its own artifact-build code first, THEN delegates phase write.  │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  LAYER G — CI / REPLAY (audit trail validation)                            │
│  scripts/sprint-replay-validator.mjs                                       │
│    - walks every docs/sprints/<slug>/state.json with phase=done            │
│    - asserts: monotonic gate_history + per-phase coverage + bypass valid   │
│    - asserts: doc-vs-manifest drift (USAGE.md gates ⊆ manifest gates)      │
│  scripts/sprint-system-test.sh --replay-gate-history → delegates           │
│  .github/workflows/test.yml → PR gate                                      │
└──────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Phase transition graph

```
           sprint-start.sh
                │
                ▼
         ┌──────────────┐
         │ spec-wizard  │
         └──────┬───────┘
                │ sprint-amend-spec.sh --lock
                │ (advances after 4-way review docs land + worker_rigor set)
                ▼
         ┌──────────────┐
         │ spec-locked  │◀──┐
         └──────┬───────┘   │
                │           │ sprint-resume.sh
                │ sprint-design-lock.sh
                ▼
         ┌──────────────┐
         │ design-locked│
         └──────┬───────┘
                │ sprint-build-launch.sh
                ▼
         ┌──────────────┐──────────────┬───────────┐
         │  building    │              │           │
         └──────┬───────┘              │           │
                │                      │           │
                │ sprint-checkin.sh    │           │
                ▼                      │           │
         ┌──────────────┐              │           │
         │ day-5-checkin│──────────────┘           │
         └──────────────┘ (back to building)       │
                                                   │ sprint-pause.sh
                ┌──────────────────────────────────┤
                ▼                                   │
         ┌──────────────┐                          │
         │  cleaning    │   sprint-cleanup-launch  │
         └──────┬───────┘                          │
                │                                   │
                ▼                                   │
         ┌──────────────┐                          │
         │  verifying   │   sprint-verify.sh       │
         └──────┬───────┘                          │
                │                                   │
                ▼                                   │
         ┌──────────────┐                          │
         │  pre-deploy  │   sprint-predeploy-gate  │
         └──────┬───────┘                          │
                │                                   │
                ▼                                   │
         ┌──────────────┐                          │
         │  deploying   │   ruflo workflow deploy  │
         └──────┬───────┘                          │
                │                                   │
                ▼                                   │
         ┌──────────────┐                          │
         │   done       │  sprint-end.sh            │
         └──────────────┘                          │
                                                   │
         ┌──────────────┐                          │
         │   paused     │◀─────────────────────────┘
         └──────────────┘
            (resume → prev_phase)
```

### 3.3 Data flow per advance

```
operator/caller invokes sprint-advance-phase.sh <next-phase>
                                  │
                                  ▼
                  ┌───────────────────────────────────┐
                  │  validate-phase-manifest.mjs       │  ← Layer A
                  │  (structural check ~50ms)          │
                  └───────────────────┬───────────────┘
                                      │ pass
                                      ▼
                  ┌───────────────────────────────────┐
                  │  resolve_slug (env > session-file)│  ← Layer D primitive
                  └───────────────────┬───────────────┘
                                      │
                                      ▼
                  ┌───────────────────────────────────┐
                  │  T2.1: validate bypass gate names  │
                  │  against manifest (reject typos)   │
                  └───────────────────┬───────────────┘
                                      │
                                      ▼
                  ┌───────────────────────────────────┐
                  │  if SPRINT_BYPASS_GATE set:        │
                  │    check_bypass(g) for each gate   │  ← Layer C-1
                  │  (writes state.gate_bypasses[])    │
                  └───────────────────┬───────────────┘
                                      │
                                      ▼
                  ┌───────────────────────────────────┐
                  │  check_phase_requirements(...)     │  ← Layer B
                  │  walks manifest, evaluates each    │
                  │  predicate against fs + state      │
                  └───────────────────┬───────────────┘
                                      │
                       fail/predicate │ pass (all predicates OR all-bypassed)
                         exits 1      │
                                      ▼
                  ┌───────────────────────────────────┐
                  │  atomic_update_state               │  ← Layer D
                  │    .phase = $next                  │
                  │    .prev_phase = $current          │
                  │    .gate_history += [...]          │
                  │    .design_locked_at/predeploy_at  │
                  │      /closed_at (if applicable)    │
                  └───────────────────┬───────────────┘
                                      │
                                      ▼
                  echo "phase advanced: $current → $next @ $at"
```

### 3.4 Hook block scenarios

```
SCENARIO A — model writes inline jq:
  Bash: jq '.phase="done"' state.json > /tmp/x && mv /tmp/x state.json
       │
       ▼
  PreToolUse hook (sprint-hook.cjs):
       - cmd matches JQ_PHASE_WRITE_REGEX
       - parentIsAdvancePhase() returns FALSE (no env, ps shows bash)
       - exit 2 — Claude Code aborts the tool call
       - operator sees: "Direct state.phase mutation blocked"

SCENARIO B — model uses Edit tool:
  Edit: file_path = docs/sprints/X/state.json
       │
       ▼
  PreToolUse hook:
       - rel matches STATE_FILE_REGEX
       - exit 2 — block

SCENARIO C — sprint-advance-phase.sh writes legitimately:
  bash sprint-advance-phase.sh design-locked
       │
       ▼ (script exports SPRINT_ADVANCE_PHASE_RUNNING=1 then runs)
       │
       ├─→ bash subprocess inside atomic_update_state:
       │    jq '.phase = "design-locked"' state.json > /tmp/x
       │
       ▼ PreToolUse hook (called by Claude Code for child Bash):
       - SPRINT_ADVANCE_PHASE_RUNNING=1 ✓
       - ps -o command= -p $PPID → ".../sprint-advance-phase.sh ..." ✓
       - allow

SCENARIO D — env spoof attempt:
  Bash: SPRINT_ADVANCE_PHASE_RUNNING=1 jq '.phase="done"' state.json
       │
       ▼
  PreToolUse hook:
       - env says yes ✓
       - ps shows "bash" not "sprint-advance-phase.sh" ✗
       - exit 2 — block

SCENARIO E (T2.6 known gap — to be fixed before ship):
  Bash: jq '.["phase"]="done"' state.json
       │
       ▼
  PreToolUse hook:
       - JQ_PHASE_WRITE_REGEX does NOT match (no .phase, only .["phase"])
       - allows ⚠️ KNOWN GAP

  Fix planned in T2.6: extend regex to /\bjq\b[^\n]{0,200}?(\.phase|\["phase"\])\s*=/

SCENARIO F (T2.7 known gap — to be fixed before ship):
  Bash: sed -i 's/"phase": "X"/"phase": "done"/' state.json
       │
       ▼
  No JQ_PHASE_WRITE match; no Edit/Write so STATE_FILE_REGEX not triggered.
  Allows ⚠️ KNOWN GAP

  Fix planned in T2.7: add Bash regex /\b(sed -i|>|>>).*state\.json/ to FORBIDDEN_PATTERNS
```

---

## §4 — Files in scope of this design

(Same as spec §H1. Listed here for cross-reference.)

| New                                        | Modified                                                                                                                                                                                                               |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| scripts/sprint-advance-phase.sh            | scripts/sprint-amend-spec.sh, sprint-design-lock.sh, sprint-build-launch.sh, sprint-checkin.sh, sprint-cleanup-launch.sh, sprint-verify.sh, sprint-predeploy-gate.sh, sprint-end.sh, sprint-pause.sh, sprint-resume.sh |
| scripts/sprint-replay-validator.mjs        | scripts/sprint-spec-wizard.mjs, sprint-wizard-assemble.mjs, sprint-system-test.sh                                                                                                                                      |
| scripts/lib/phase-manifest.json            | .claude/helpers/sprint-hook.cjs (+ JQ_PHASE_WRITE_REGEX, parentIsAdvancePhase(), state.json edit block)                                                                                                                |
| scripts/lib/phase-manifest.schema.json     | .claude/skills/sprint-spec-wizard/sections/J-risks.md (+ §J5 worker_rigor)                                                                                                                                             |
| scripts/lib/phase-predicates.sh            | docs/sprints/USAGE.md (+ ## Phase enforcement section)                                                                                                                                                                 |
| scripts/lib/sub-step.sh                    | docs/sprints/DEVELOPER.md (+ Extending phase-manifest guide — T3.1 follow-up)                                                                                                                                          |
| scripts/lib/bypass.sh                      | docs/sprints/\_guides/bypass-cheatsheet.md (T3.2 follow-up — rewrite)                                                                                                                                                  |
| scripts/lib/validate-phase-manifest.mjs    | .github/workflows/test.yml (+ 2 CI steps)                                                                                                                                                                              |
| docs/sprints/\_guides/sub-step-coverage.md | .claude/skills/sprint-orchestrator/SKILL.md (T3.3 follow-up — call advance-phase between phases)                                                                                                                       |

---

## §5 — Verification plan (echo of spec §I)

End-to-end smoke (dogfooded during sprint):

1. Hook block: jq+phase write → exit 2 ✓ AC-5 proof
2. Hook block: state.json Edit → exit 2 ✓ AC-5 proof
3. Predicate fail → exit 1 with `[FAIL]` lines ✓ AC-2 proof
4. Advance happy path: spec-locked → design-locked ✓ AC-4 proof
5. Multi-gate bypass with WHY ≥10 chars ✓ AC-4/AC-6 proof
6. Bypass refusal with WHY missing or short ✓ AC-6 proof
7. Sub-step idempotency: same gate recorded twice → length 1, updated `at` ✓ AC-3 proof
8. Day-5 sentinel: missing `### Cut` → exit 1 ✓ AC-11 proof
9. Retro completeness: missing patterns → advance-phase refuses → exit 1 ✓ AC-12 proof
10. Replay validator: synthetic incomplete sprint → exit 1 ✓ AC-13 proof
11. Doc-vs-manifest drift: gate in USAGE.md not in manifest → exit 1 ✓ AC-13d proof

KNOWN UNVERIFIED (follow-ups before v0.7.0 ship):

- T2.5: AC-5 hook in real Claude Code invocation flow (not synthetic stdin)
- T2.6: jq bracket syntax regex match
- T2.7: sed/redirect Bash forbidden-action regex

---

## §6 — Rollback (echo of spec §J)

Per-AC reverts via `git revert <sha>`. Each commit is atomic per-AC. Schema is fully additive — state.json gains new fields but no field removed. Pre-v0.7 sprints continue to read/write the same shape; new fields default to `null` / `undefined` on read.

`gates` ↔ `gates_passed` dual-write deprecated in v0.8.0. v0.7.x keeps both. Replay validator's union-read preserves backward compatibility.
