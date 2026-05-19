# AC-8 — Sub-step instrumentation

**Verdict:** Production
**Methodology:** instrumentation coverage map + AC-7 migration verification

## Sub-step gates instrumented

10 sub-step gates instrumented via `record_sub_step` calls injected during AC-7 migration:

| Sub-step gate                   | Recording site                  | When fires                                   |
| ------------------------------- | ------------------------------- | -------------------------------------------- |
| `spec-lock-baseline-written`    | `sprint-amend-spec.sh` (--lock) | After drift baseline + files_touched written |
| `build-launched`                | `sprint-build-launch.sh`        | At swarm launch                              |
| `cleanup-deadcode-delete`       | `sprint-cleanup-launch.sh`      | After deadcode pass                          |
| `cleanup-lint-fix`              | `sprint-cleanup-launch.sh`      | After lint --fix pass                        |
| `cleanup-claude-md-clean`       | `sprint-cleanup-launch.sh`      | After CLAUDE.md auto-clean                   |
| `design-sparc-spec-pseudocode`  | `sprint-design-lock.sh`         | At design-lock                               |
| `design-sparc-architect`        | `sprint-design-lock.sh`         | At design-lock                               |
| `design-locked`                 | `sprint-design-lock.sh`         | At design-lock                               |
| `pre-deploy-reviewer-agent`     | `sprint-predeploy-gate.sh`      | When --reviewer file present                 |
| `pre-deploy-security-architect` | `sprint-predeploy-gate.sh`      | When --security file present                 |

## Coverage status against manifest (68 named gates)

| Phase           | Gates needed                      | Instrumented this AC             | Deferred to follow-up sprint                                                                                 |
| --------------- | --------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `spec-wizard`   | 14                                | 0                                | 14 — wizard sub-step recording (AC-10 +)                                                                     |
| `spec-locked`   | 5                                 | 1 (`spec-lock-baseline-written`) | 4 — solution-sketches, architect-review, security-review, hive-mind-consensus — caller-side (workflow yamls) |
| `design-locked` | 3                                 | 3 ✓                              | 0                                                                                                            |
| `building`      | 1                                 | 1 (`build-launched`) ✓           | 0                                                                                                            |
| `day-5-checkin` | 4                                 | 0                                | 4 — AC-11 enforces in next commit                                                                            |
| `cleaning`      | 3                                 | 3 ✓                              | 0                                                                                                            |
| `verifying`     | 18                                | 0                                | 18 — `sprint-verify.sh` extension (deferred follow-up)                                                       |
| `pre-deploy`    | 2                                 | 2 ✓                              | 0                                                                                                            |
| `deploying`     | 5                                 | 0                                | 5 — workflow yaml (deferred)                                                                                 |
| `done`          | 11                                | 0                                | 11 — AC-12 enforces in next commit                                                                           |
| `paused`        | 0                                 | 0                                | 0                                                                                                            |
| **Total**       | **66 non-strict + 2 strict_only** | **10 (15%)**                     | **56 (85%) — split across AC-11, AC-12, and follow-up sprint**                                               |

This AC ships the **instrumentation pattern + first 10 sites**. AC-11 + AC-12 cover the next 15 sites (day-5 + retro). Verify-chain (18) is a follow-up sprint because each verify-command needs its own integration (e.g., parsing sonar output).

## Coverage map document

`docs/sprints/_guides/sub-step-coverage.md` (next commit, AC-14) catalogs every named gate + which script records it + how to add a new one.

## What this proves

1. **Pattern works** — `record_sub_step` is sourced into each script via `source "$(dirname "$0")/lib/sub-step.sh" 2>/dev/null` (graceful skip if helper missing during install). Calls are idempotent + dual-write to gates+gates_passed.
2. **Coverage IS partial** — 15% of named gates instrumented this commit; 85% deferred to AC-11, AC-12, and a follow-up `harness-verify-instrumentation-v1` sprint.
3. **Phase manifest is the contract** — by listing 68 required gates explicitly, the manifest documents the gap. Replay validator (AC-13) will refuse to pass `phase=done` unless all 68 (minus strict-only-when-lax) are recorded or bypassed. Operators are forced to either ship instrumentation OR bypass-with-rationale.

## Follow-up sprint scope (proposed)

`harness-verify-instrumentation-v1` — 18 verify-chain sub-steps + wizard 14 sub-steps + retro 11 sub-steps + deploy 5 sub-steps = ~48 ACs. Single appetite. Defer until v0.7.x has shipped + operators have run 1-2 real sprints under the new gate.
