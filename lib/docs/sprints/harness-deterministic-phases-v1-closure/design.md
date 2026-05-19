# Design — harness-deterministic-phases-v1-closure

> SPARC design phase output. Produced after spec-lock + 4-way review. Walks Specification → Pseudocode → Architecture for the 6-wave closure work.

---

## §1 — Specification

### 1.1 Goals + invariants

| ID    | Goal/invariant                                                                    | Verified by                    |
| ----- | --------------------------------------------------------------------------------- | ------------------------------ |
| G-1   | All 53 leftover items reach a terminal status (done OR explicitly deferred)       | retro.md + replay validator    |
| G-2   | Parent sprint reaches `phase=done` with `closed_at` set                           | Wave F + jq verification       |
| G-3   | Sprint-harness mirrored to v0.7.0 (package.json + CHANGELOG + git tag)            | Wave D + version check         |
| G-4   | Every L-item has a per-L proof file under `proof/L<N>-<short-name>.md`            | Manual grep + replay validator |
| INV-1 | No L-item closed Production without proof file                                    | Wave F validation pass         |
| INV-2 | Every bypass against parent sprint (Wave F) has `why` ≥10 chars                   | gate_bypasses[] inspection     |
| INV-3 | Sprint-harness `lib/docs/` stays gitignored (mirror writes don't break it)        | Wave D commit smoke            |
| INV-4 | NO push to remote without explicit user `gio` chat confirmation                   | Org policy enforcement         |
| INV-5 | L17 gate-names.json generated FROM manifest, then validator goes strict in v0.7.1 | Documented in DEVELOPER.md     |

### 1.2 Wave entry/exit predicates

| Wave | Entry predicate                   | Exit predicate                                                                                         |
| ---- | --------------------------------- | ------------------------------------------------------------------------------------------------------ |
| A    | spec-locked phase reached         | L1-L4 all have proof files; parent sprint NOT yet walked (just unblocked for Wave F)                   |
| B    | Wave A complete                   | L5-L11 all proven; replay validator passes on all sprints                                              |
| C    | Wave A complete (parallel with B) | L12-L20 all implemented + proven; security-review.md residual risks updated                            |
| D    | Waves A+B+C complete              | Sprint-harness at v0.7.0 with CHANGELOG + tag; awaiting push approval                                  |
| E    | Wave D complete                   | All docs aligned with v0.7.0 reality; sub-step-coverage.md accurate                                    |
| F    | All other waves done              | Parent sprint state.phase=done; replay-validator --only-sprint harness-deterministic-phases-v1 exits 0 |

---

## §2 — Pseudocode (per-wave algorithms)

### 2.1 Wave A pseudocode

```
WAVE A — Ship-blockers

L1 hook real-flow:
  1. Read current sprint-hook.cjs to confirm parentIsAdvancePhase() exists
  2. Construct fixture: jq attack command + advance-phase legitimate command
  3. Invoke hook with each + capture exit codes
  4. If parentIsAdvancePhase returns false on legit (ppid issue), implement pgrep fallback:
     - Cap depth to 3 generations
     - Match /sprint-advance-phase\.sh/ in any ancestor's command line
  5. Write proof/L1-real-flow.md with both test outputs

L2 jq variant regex:
  1. Extend JQ_PHASE_WRITE in sprint-hook.cjs to broader pattern:
     /\b(jq|python|python3|node|awk|gawk|perl|ruby)\b[^\n]{0,200}?(>|--in-place|-i)[^\n]{0,200}?docs\/sprints\/[^\s]+state\.json/
  2. Smoke-test 4 attack patterns: jq -f, python -c, awk redirect, perl -i
  3. Verify legit advance-phase still passes (no false-positive)
  4. Write proof/L2-regex-variants.md

L3 9-script audit:
  1. For each of 9 phase-writer scripts:
     a. grep delegation pattern: `bash "$(dirname "$0")/sprint-advance-phase.sh"`
     b. Trace control flow from delegation back to script entry
     c. Identify: pre-existing behavior preserved? error paths bubble? sub-step records only after underlying work succeeded?
  2. Document findings per-script in proof/L3-9script-audit.md
  3. Apply any fixes found (record as separate commit)

L4 parent phase-walk:
  1. Resume parent: bash scripts/sprint-resume.sh harness-deterministic-phases-v1
  2. Walk cleaning → verifying → pre-deploy → deploying → done
  3. Each transition: bash scripts/sprint-advance-phase.sh <next-phase>
  4. Any [FAIL] predicate: SPRINT_BYPASS_GATE=<gate> SPRINT_BYPASS_WHY='...' bash scripts/sprint-advance-phase.sh <next-phase>
  5. After done: jq '.phase, .closed_at' state.json → verify
  6. node scripts/sprint-replay-validator.mjs --only-sprint harness-deterministic-phases-v1 → expect walked=1 passed=1
  7. Write proof/L4-parent-walk.md

  NOTE: L4 happens in Wave F (after Wave E doc updates land), not Wave A.
  Wave A only fixes the BLOCKERS that prevent the walk (L1+L2+L3 = the hook + audit gaps).
```

### 2.2 Wave B pseudocode

```
WAVE B — Verification (L5-L11)

L5 worker_rigor=strict smoke:
  Create fixture test-strict-worker-rigor/state.json with phase=spec-locked + worker_rigor=strict
  Run check_phase_requirements verifying
  Expect [FAIL] on verify-worker-map-refreshed + verify-worker-consolidate-refreshed (strict-only)
  Write proof/L5-strict-mode.md

L6 --from invariant:
  Against this closure sprint (phase=spec-locked):
    SPRINT_SLUG_OVERRIDE=closure bash scripts/sprint-advance-phase.sh design-locked --from spec-wizard
  Expect exit 1 with "--from spec-wizard but current is spec-locked"
  Write proof/L6-from-invariant.md

L7 9 predicate evaluators:
  For each kind ∈ {file_exists, json_path_equals, json_path_present, file_contains_heading}:
    Create fixture state + files satisfying predicate; verify pass
    Modify fixture to fail predicate; verify [FAIL] line emitted
  Write proof/L7-predicates.md

L8 retro substeps:
  After Wave F begins, run sprint-end.sh against parent sprint
  Verify state.gates_passed contains retro-worked, retro-didnt, retro-surprised, retro-pattern-1, -2, -3, retro-claude-md, retro-followups, daa-feedback-batched, trajectory-closed, velocity-computed
  Write proof/L8-retro-substeps.md

L9 legacy bypass shims:
  For each of 7 legacy envs:
    Set env=1, run caller script
    Verify deprecation warning on stderr
    Verify gate_bypasses[] entry recorded
  Write proof/L9-legacy-shims.md (7-row table)

L10 onboarding-flow-v2 JSON:
  Already partially repaired (commit 4941774). Verify jq empty passes.
  If still corrupt: backup, repair, verify.
  Write proof/L10-onboarding-v2-repair.md

L11 mid-checkin pre-v07 skip:
  Run replay-validator across all closed sprints
  Verify pre-v0.7 sprints skipped (no false-positive failures on legacy mid-checkin entries)
  Write proof/L11-pre-v07-skip.md
```

### 2.3 Wave C pseudocode

```
WAVE C — Polish

L12 TOCTOU-safe atomic write:
  Edit scripts/sprint-advance-phase.sh atomic_update_state call:
    Add --arg expected_phase "$CURRENT_PHASE" to the jq args
    Modify filter to:
      if .phase == $expected_phase then ... else error("phase changed mid-advance") end
  Smoke: race two advance-phase invocations; second exits non-zero
  Write proof/L12-toctou.md

L13 evidence canonical:
  Edit scripts/lib/sub-step.sh::record_sub_step entry:
    If evidence starts with /:
      evidence=$(node -e "console.log(require('path').relative('$REPO_ROOT','$evidence'))" 2>/dev/null || echo "")
    If evidence contains "..": exit 1
  Smoke: try ../../../etc/passwd → reject
  Smoke: absolute path inside repo → canonicalize
  Write proof/L13-evidence.md

L14 PII redact:
  Edit scripts/lib/bypass.sh::check_bypass before atomic write:
    redacted_why=$(echo "$SPRINT_BYPASS_WHY" | bash scripts/sprint-pii-redact.sh 2>/dev/null || echo "$SPRINT_BYPASS_WHY")
    Use $redacted_why instead of $SPRINT_BYPASS_WHY in jq filter
  Test corpus (10 rationales) — verify no over-redaction
  Write proof/L14-redactor-corpus.md (covers S-CL3 security finding)

L15 rm/mv hook block:
  Add to sprint-hook.cjs FORBIDDEN_PATTERNS:
    /\b(rm|mv)\b[^\n]{0,200}?docs\/sprints\/[^\s]+state\.json/
  Smoke: rm + mv targeting state.json → block
  Write proof/L15-rm-mv-block.md

L16 record_sub_step gate-name warn:
  Edit scripts/lib/sub-step.sh::record_sub_step entry:
    Read manifest, build allowed gate set
    If gate not in set: print "[WARN] unknown gate '$gate'" to stderr (don't block)
  Smoke: record_sub_step typo-gate → warning emitted, entry still recorded
  Write proof/L16-warn.md

L17 gate-names.json:
  Create scripts/lib/gate-names.json by extracting from manifest:
    {"version":"1.0.0","gates":[...68 gate names...]}
  Extend validate-phase-manifest.mjs to cross-check manifest ↔ gate-names
  Bootstrap-mode flag: --bootstrap-gate-names regenerates
  Document strict-mode timeline (v0.7.1) in DEVELOPER.md
  Write proof/L17-gate-names.md

L18 schema _comment field:
  Add to phase-manifest.schema.json properties:
    "_comment": { "type": "string" }
  Verify validator + ajv-strict consumers tolerate
  Write proof/L18-schema-comment.md

L19 replay --report-file:
  Edit scripts/sprint-replay-validator.mjs:
    Parse --report-file <path>
    On completion, write markdown report with summary table + per-sprint details
  Smoke: --report-file /tmp/replay.md
  Write proof/L19-report-file.md

L20 doc-drift regex scope:
  Edit scripts/sprint-replay-validator.mjs doc-vs-manifest section:
    Restrict kebab-case scan to text between "## Phase enforcement" H2 and next H2
  Smoke: Add a non-gate kebab to USAGE.md outside that section → no doc-drift flag
  Write proof/L20-drift-scope.md
```

### 2.4 Wave D pseudocode

```
WAVE D — Mirror to sprint-harness + v0.7.0 release

Mirror execution (single bulk commit):
  cd /Users/gio/Desktop/sprint-harness
  Use existing sync-mirror.sh from lifeos:
    bash /Users/gio/Desktop/lifeos/scripts/sync-mirror.sh
  Verify 24 files updated/added
  jq -r '.version' package.json → confirm still 0.6.0

Version bump:
  jq '.version = "0.7.0"' package.json > /tmp/p.json && mv /tmp/p.json package.json

CHANGELOG entry:
  Prepend to CHANGELOG.md a ~50-line v0.7.0 entry covering:
    - Deterministic phase enforcement (manifest + advance-phase + predicates + hook)
    - Single bypass UX (SPRINT_BYPASS_GATE + SPRINT_BYPASS_WHY)
    - 25 enforced + 43 deferred gates
    - Legacy SPRINT_*_BYPASS=1 envs deprecated (removal v0.8.0)
    - T1-T4 fix-up summary + 53-item closure work
    - Net security posture improvement (8 of 15 surfaces gain mitigations)

Git tag:
  git add -A
  git commit -m "release: v0.7.0 — deterministic phase enforcement + closure"
  git tag -a v0.7.0 -m 'v0.7.0 release'

Push approval — REQUIRES USER GIO CHAT CONFIRMATION:
  Do NOT auto-push. Surface to user for explicit approval.
  When approved: git push origin main + git push --tags
```

### 2.5 Wave E pseudocode

```
WAVE E — Doc cleanup

L49 README.md:
  Edit docs/sprints/README.md to add a "## Phase enforcement (v0.7.0+)" section
  Brief overview + link to USAGE.md "## Phase enforcement"

L50 DEVELOPER.md stale prose:
  grep -n "tell Claude\|I'll\|you tell me" docs/sprints/DEVELOPER.md
  Replace each occurrence with explicit advance-phase invocation OR mark as legacy
  Document L17 strict-mode timeline + L52 proof convention

L51 USAGE.md rest-of-doc audit:
  grep -n "SPRINT_DRIFT_BYPASS\|SPRINT_DUP_BYPASS\|jq.*phase" docs/sprints/USAGE.md
  Update to v0.7.0 convention where stale
  Mark deprecated where legacy still valid

L52 proof location convention:
  Add a section to DEVELOPER.md documenting:
    - Per-sprint proofs live at docs/sprints/<slug>/proof/
    - Vendored fixtures (sprint-harness install-test) live at lib/proof/ in published package

L53 plan-file curation:
  mkdir ~/.claude/plans/harness-deterministic-phases-v1/
  Move existing kettle.md to .../closure.md
  Original build plan recovered from git history → .../build.md
  (Optional; can defer to v0.7.1)
```

### 2.6 Wave F pseudocode

```
WAVE F — Parent sprint closure

1. Resume parent:
   bash scripts/sprint-resume.sh harness-deterministic-phases-v1

2. From building → cleaning:
   bash scripts/sprint-cleanup-launch.sh harness-deterministic-phases-v1
   (Records 3 cleanup sub-steps OR bypasses with rationale.)

3. From cleaning → verifying:
   SPRINT_BYPASS_GATE='verify-typecheck,...' SPRINT_BYPASS_WHY='...' \
     bash scripts/sprint-advance-phase.sh verifying
   (Most verify sub-steps already recorded T2.4 in parent; few may need re-bypass.)

4. From verifying → pre-deploy:
   Create docs/sprints/harness-deterministic-phases-v1/pre-deploy-review.md (≥200B)
   Set state.predeploy_at
   record_sub_step pre-deploy-reviewer-agent
   record_sub_step pre-deploy-security-architect
   bash scripts/sprint-advance-phase.sh pre-deploy

5. From pre-deploy → deploying:
   Bypass 5 deploy sub-steps with "harness-itself sprint; no Lambda/Vercel deploy"
   bash scripts/sprint-advance-phase.sh deploying

6. From deploying → done:
   Run sprint-end.sh (records retro sub-steps from existing retro.md content)
   Or directly: bash scripts/sprint-advance-phase.sh done

7. Verify:
   jq '.phase, .closed_at' state.json → "done", ISO timestamp
   node scripts/sprint-replay-validator.mjs --only-sprint harness-deterministic-phases-v1 → walked=1 passed=1
```

---

## §3 — Architecture

### 3.1 Wave dependency diagram (final)

```
       ┌─────────────────────┐
       │ harness-deterministic-phases-v1-closure │
       │   spec-locked phase                      │
       └──────────────┬───────────────────────────┘
                      │
              Day 1-2 SPARC design (this doc)
                      │
                      ▼
              ┌──────────────────┐
              │   design-locked  │
              └────────┬─────────┘
                       │
                  build-launch
                       │
                       ▼
              ┌──────────────────┐
              │   building       │
              └────────┬─────────┘
                       │
   ┌───────────────────┼───────────────────┐
   ▼                   ▼                   ▼
┌─────────┐       ┌─────────┐       ┌─────────┐
│ Wave A  │       │ Wave B  │       │ Wave C  │
│ L1-L4   │       │ L5-L11  │       │ L12-L20 │
└────┬────┘       └────┬────┘       └────┬────┘
     └──────┬──────────┴────────────┬────┘
            │                       │
            ▼ Day 5 checkin         ▼
       (sentinels)                  │
            │                       │
            ▼                       ▼
       ┌───────────────────────────────┐
       │            Wave D             │
       │     Mirror + v0.7.0 release   │
       │     L25-L48 (24 items)        │
       └───────────────┬───────────────┘
                       │
                       ▼
              ┌──────────────────┐
              │  Wave E doc      │
              │  cleanup L49-L53 │
              └────────┬─────────┘
                       │
              Day 11-12 verify
                       │
                       ▼
              ┌──────────────────┐
              │   verifying      │
              └────────┬─────────┘
                       │
              Day 12 pre-deploy review
                       │
                       ▼
              ┌──────────────────┐
              │   pre-deploy     │
              └────────┬─────────┘
                       │
              Day 13 deploy (N/A — bypass with rationale)
                       │
                       ▼
              ┌──────────────────┐
              │   deploying      │ → done
              └──────────────────┘

       After this sprint hits done:
                       ▼
              ┌──────────────────────────────┐
              │  Wave F (parent closure walk) │
              │  harness-deterministic-       │
              │  phases-v1 from building →    │
              │  cleaning → ... → done        │
              └──────────────────────────────┘
```

### 3.2 Layer interaction (re-use from parent + new additions)

Reused (no changes this sprint):

- `scripts/lib/atomic-state.sh` (v0.5.0)
- `scripts/lib/session-file.sh` (v0.5.0)
- `scripts/lib/lock-dir.sh` (v0.5.0)
- `scripts/lib/phase-manifest.json` + `phase-manifest.schema.json` (v0.7.0)
- `scripts/lib/phase-predicates.sh` (v0.7.0) — extended in L7 for missed kinds
- `scripts/sprint-advance-phase.sh` (v0.7.0) — extended in L12 for TOCTOU
- `scripts/sprint-replay-validator.mjs` (v0.7.0) — extended in L19+L20

Net additions per closure sprint:

- **New file**: `scripts/lib/gate-names.json` (L17)
- **New file**: `~/Desktop/sprint-harness/CHANGELOG.md` v0.7.0 entry (L45)
- **Modified hook**: `.claude/helpers/sprint-hook.cjs` (L2 regex extension + L15 rm/mv block)
- **Modified bypass**: `scripts/lib/bypass.sh` (L14 PII redact integration)
- **Modified sub-step**: `scripts/lib/sub-step.sh` (L13 evidence canonical + L16 warn)
- **Modified replay**: `scripts/sprint-replay-validator.mjs` (L19 + L20)
- **Modified docs**: USAGE.md, DEVELOPER.md, README.md, \_guides/bypass-cheatsheet.md, \_guides/sub-step-coverage.md
- **Mirror**: 24 files to `~/Desktop/sprint-harness/lib/...` + package.json + CHANGELOG.md + tag

### 3.3 Push approval boundary

```
┌──────────────────────────────────────────────────────────────┐
│ Closure sprint executes everything LOCALLY without push.     │
│ Two pending pushes at the end:                                │
│   1. lifeos `sprint/pipeline-v2-visibility` branch            │
│   2. ~/Desktop/sprint-harness `main` branch (+ v0.7.0 tag)   │
│                                                                │
│ Both require EXPLICIT user `gio` chat confirmation per org    │
│ policy.                                                        │
│                                                                │
│ Closure sprint marks final state as "ready-to-push" + writes   │
│ retro.md "Open follow-ups" item: "user gio approves push to   │
│ unblock v0.7.0 ship".                                          │
└──────────────────────────────────────────────────────────────┘
```

---

## §4 — Files in scope (echo of §H1)

(Per spec §H1: 34 files including ~/.claude/plans/ + ~/Desktop/sprint-harness/)

---

## §5 — Verification

```bash
# After all 6 waves land + sprint reaches done:

# 1. Manifest still clean
node scripts/lib/validate-phase-manifest.mjs

# 2. Replay validator passes for closure sprint AND parent
node scripts/sprint-replay-validator.mjs --only-sprint harness-deterministic-phases-v1
node scripts/sprint-replay-validator.mjs --only-sprint harness-deterministic-phases-v1-closure

# 3. Both sprints reached done
for s in harness-deterministic-phases-v1 harness-deterministic-phases-v1-closure; do
  jq '{phase, closed_at}' docs/sprints/$s/state.json
done

# 4. Sprint-harness at v0.7.0
cd ~/Desktop/sprint-harness && jq -r '.version' package.json
git tag -l | grep v0.7.0
```

---

## §6 — Rollback

Per-AC reverts via `git revert <sha>` on the closure sprint's branch. Sprint-harness v0.7.0 tag can be moved before push (not yet published to npm). No DB / no migration / pure file edits.
