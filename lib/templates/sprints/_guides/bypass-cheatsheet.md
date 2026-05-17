# Bypass cheatsheet

Every escape-hatch env var in the sprint system, when to use, and where it logs.

> All bypasses are LOGGED — either to `state.gate_bypasses[]` or `state.scope_amendments[]`. Retro will surface them.

---

## Commit-path gates

| Env var                     | Skips                                      | When to use                                                                                                                               | Logs to                                           |
| --------------------------- | ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `SPRINT_DRIFT_BYPASS=1`     | husky drift check                          | Legitimate amendment-class commit that hasn't been added to scope yet (e.g., emergency fix to a script that itself fixes drift detection) | `state.drift_events[]` records score regardless   |
| `SPRINT_DUP_BYPASS=1`       | jscpd code-duplication block               | Refactor commit that legitimately introduces parallel structures (copying a known template); cleanup phase will dedupe later              | `state.gate_bypasses[].gate = "dup-check"`        |
| `SPRINT_SKIP_REUSE_AUDIT=1` | post-commit reuse audit (AC-5)             | CI run / cold start where the slow `pnpm dlx jscpd` first-time download is intolerable                                                    | not logged (preventive, not corrective)           |
| `SPRINT_NO_REVIEW_GATE=1`   | pre-push reviewer + security marks (AC-13) | Trivial hotfix where spawning agents is overkill (e.g., typo fix in a comment)                                                            | `state.gate_bypasses[].gate = "pre-merge-review"` |

## Wizard / amendment gates

| Env var                        | Skips                                                            | When to use                                                                                                 | Logs to                                                            |
| ------------------------------ | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `AMEND_ALLOW_EMPTY=1`          | AC-31 strict `--add-file` / `--cut` requirement for `WHY+INTENT` | Auto-callers that genuinely have no context (background daemons, retro workflow)                            | `state.scope_amendments[].decided_by = "AMEND_ALLOW_EMPTY-bypass"` |
| `AMEND_NONINTERACTIVE=1`       | TTY prompt fall-through to interactive mode                      | Scripted / CI invocations of `sprint-amend-spec.sh`; combine with `AMEND_WHY=` and `AMEND_INTENT=` env vars | nothing (just controls UX)                                         |
| `--user-confirmed`             | wizard interactive mode enforcement                              | Each `wizard answer` call when user actually approved                                                       | nothing (default expected behavior)                                |
| `--force-advance`              | wizard interactive mode for one answer                           | Genuine emergency where the wizard is stuck but you must move on                                            | wizard-transcript.md tags `[FORCE-ADVANCE override]`               |
| `SPRINT_WIZARD_MODE=autopilot` | per-answer `--user-confirmed` requirement                        | Tooling-only sprints with no UX decisions (e.g., this sprint-system-100 closeout itself)                    | `spec.partial.json.wizard_mode = "autopilot"`                      |

## Precheck / health gates

| Env var                     | Skips                                        | When to use                                                                           | Logs to                                       |
| --------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------- |
| `SPRINT_PRECHECK_BYPASS=1`  | `sprint-start.sh` blocking precheck          | Daemon temporarily down but you must start sprint anyway (rare; better to fix daemon) | not logged; precheck output prints regardless |
| `SPRINT_HIVE_MIND_BYPASS=1` | `sprint-hive-mind-spec-lock.sh` daemon check | Spec-lock when ruflo daemon down; you accept the missing consensus signal             | stderr log                                    |
| `SPRINT_GH_BYPASS=1`        | every gh API call in `sprint-gh-mirror.mjs`  | Offline / network-isolated; mirror entries skipped (resync later)                     | not logged                                    |
| `SPRINT_SKIP_GRAPHIFY=1`    | verify-workflow `graphify-rebuild` step      | Throwaway / smoke sprint where graph staleness is acceptable                          | workflow step skip note                       |

## Drift-related tuning (not bypasses)

| Env var                    | Default                          | Effect                                                                         |
| -------------------------- | -------------------------------- | ------------------------------------------------------------------------------ |
| `SPRINT_DRIFT_THRESHOLD`   | `0.75` (this sprint used `0.65`) | Looser ≈ more permissive; tighter ≈ more pauses                                |
| `SPRINT_DUP_THRESHOLD`     | `50` (percent)                   | jscpd dup similarity that triggers BLOCK                                       |
| `SPRINT_DUP_REPO_SCAN=1`   | off                              | Even single-staged-file commits trigger full-repo jscpd scan (slow)            |
| `SPRINT_BASE_BRANCH`       | `main`                           | Coverage-delta + git merge-base reference branch                               |
| `SPRINT_DEADCODE_COMMIT=1` | off                              | `sprint-cleanup-launch.sh` actually runs `sprint-deadcode-delete.mjs --commit` |
| `AMEND_DECIDED_BY`         | `user`                           | Tag whose name appears in scope_amendments entry                               |

---

## How to check what's been bypassed

```bash
node -e "
  const s = require('./docs/sprints/<slug>/state.json');
  console.log('Gate bypasses:', (s.gate_bypasses || []).length);
  console.log('Scope amendments via bypass:',
    (s.scope_amendments || []).filter(a => /bypass/i.test(a.decided_by || '')).length);
  console.log('Drift events below threshold:',
    (s.drift_events || []).filter(e => e.score < 0.75).length);
"
```

At sprint-end, the velocity report flags any sprint with >3 below-threshold drift events as "low_drift_events: false" success criterion fail.

---

## Anti-patterns (don't do this)

- **Permanent `SPRINT_DRIFT_BYPASS=1` shell export** — defeats the whole drift system. Use per-command instead.
- **`AMEND_ALLOW_EMPTY=1` outside a daemon callback** — silent context loss; future retro can't tell what changed and why.
- **`SPRINT_NO_REVIEW_GATE=1` for non-trivial commits** — pre-merge gate exists to catch RLS/auth gaps; bypassing should be exceptional.
- **`SPRINT_HIVE_MIND_BYPASS=1` without restarting daemon afterward** — daemon-down state hides bigger problems (state.json races, no trajectory accumulation).
- **Closing a sprint without inject-catch-restore proof per AC** — "presence + invocability" is not Production (lesson from harness-full-coverage 4-close cycle). Run `scripts/sprint-inject-violation.sh` for each capability before claiming Production verdict.

---

## Harness-full-coverage env vars (2026-05-17 additions)

| Env var                                                 | Used by                         | Purpose                                                            |
| ------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------ |
| `HIVE_POLL_TIMEOUT`                                     | `sprint-hive-mind-spec-lock.sh` | Bounded polling timeout for consensus terminal state (default 60s) |
| `PROOF_FILE` / `AC_ID` / `GATE_NAME` / `ASSERT_PATTERN` | `sprint-inject-violation.sh`    | Required env for inject-catch-restore helper                       |
