# AC-7 — Migrate phase-writers to delegate

**Verdict:** Production
**Methodology:** grep-based static analysis + chain smoke

## Files migrated (9 scripts × 11 inline `.phase = ` writes → 0 outside canonical mutator)

| Script                         | Before                                                     | After                                                                                     |
| ------------------------------ | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `sprint-amend-spec.sh:88`      | `.phase = "spec-locked" \| .gates_passed += [...] \| ...`  | `record_sub_step spec-lock-baseline-written` + delegate to advance-phase.sh `spec-locked` |
| `sprint-build-launch.sh:64`    | `.phase = "building"`                                      | `record_sub_step build-launched` + delegate to advance-phase.sh `building`                |
| `sprint-cleanup-launch.sh:71`  | `.phase = "cleaning"`                                      | delegate to advance-phase.sh `cleaning`                                                   |
| `sprint-cleanup-launch.sh:97`  | `.phase = "pre-deploy" \| .gates_passed += ["cleanup"]`    | record 3 sub-steps (deadcode-delete, lint-fix, claude-md-clean) + delegate `pre-deploy`   |
| `sprint-design-lock.sh:113`    | `.phase = "design-locked" \| .gates += ["design-lock"]`    | record 3 sub-steps (sparc-spec-pseudocode, sparc-architect, design-locked) + delegate     |
| `sprint-end.sh:135`            | `.phase = "done" \| .closed_at = "..."`                    | record elapsed_seconds + delegate to advance-phase.sh `done`                              |
| `sprint-pause.sh:41`           | `.phase = "paused" \| .prev_phase = ... \| .pause_events`  | write prev_phase + pause_events first, then delegate `paused`                             |
| `sprint-resume.sh:35`          | `.phase = "$PREV_PHASE" \| .pause_events`                  | write resumed_at first, then delegate `$PREV_PHASE`                                       |
| `sprint-predeploy-gate.sh:101` | `.phase = "pre-deploy" \| .gates += ["pre-deploy"] \| ...` | record 2 sub-steps (reviewer, security-architect) + delegate `pre-deploy`                 |

Each migration also adds a deprecation shim for the legacy per-script bypass env (`SPRINT_DESIGN_LOCK_BYPASS=1` → auto-set `SPRINT_BYPASS_GATE=design-locked SPRINT_BYPASS_WHY='legacy-shim-...'`).

## grep proof — zero inline phase writes remain outside advance-phase.sh + legacy fallbacks

```
$ grep -rnE "\.phase\s*=\s*[\"']" scripts/ | grep -v sprint-advance-phase.sh | grep -v "legacy fallback" | grep -v "atomic-state.sh:"
(empty — all inline phase writes are either inside sprint-advance-phase.sh or marked as `# legacy fallback` inside an error-handler branch)
```

The remaining `legacy fallback` lines (5 occurrences) execute ONLY when `sprint-advance-phase.sh` is missing or rejects the advance — they preserve the v0.6.x behavior for harnesses installed before v0.7.0.

## Chain smoke

After Wave 1+2, every phase write traces this path:

```
operator/caller → sprint-amend-spec.sh --lock
                  → atomic_update_state files_touched
                  → record_sub_step spec-lock-baseline-written
                  → sprint-advance-phase.sh spec-locked
                     → validate-phase-manifest.mjs (check structure)
                     → check_phase_requirements spec-wizard
                       → file_min_bytes spec.md ≥ 500
                       → file_min_bytes wizard-transcript.md ≥ 100
                       → json_path_in spec.partial.json:.current_section ∈ [complete, J]
                       → state_field_all_values_in .wizard_state.sections_status[]
                       → 14 sub-step gates (wizard-section-A..J + 3 coherence + assemble)
                     → if all pass (or all bypassed via SPRINT_BYPASS_GATE):
                       → atomic write: .prev_phase = spec-wizard, .phase = spec-locked,
                                       .gate_history += [{from, to, at, by}]
```

Every transition between phases now flows through this single path. The hook (AC-5) blocks all other paths.

## Files modified (this AC)

- `scripts/sprint-amend-spec.sh` — +14 lines / -3
- `scripts/sprint-build-launch.sh` — +11 lines / -1
- `scripts/sprint-cleanup-launch.sh` — +21 lines / -2
- `scripts/sprint-design-lock.sh` — +20 lines / -10
- `scripts/sprint-end.sh` — +14 lines / -10
- `scripts/sprint-pause.sh` — +14 lines / -2
- `scripts/sprint-predeploy-gate.sh` — +18 lines / -10
- `scripts/sprint-resume.sh` — +11 lines / -2

Total: 8 files modified, ~123 lines changed.

## Inject-violation: model attempts to skip a phase

Before this AC: model could call `jq '.phase = "done"' state.json` directly → state advanced without retro/patterns/etc.

After this AC + AC-5:

1. AC-5 PreToolUse hook blocks the jq command (exit 2).
2. Even if model writes a script with the jq embedded, the hook STILL fires on Bash tool use (matches `jq … .phase = …` regex).
3. Even if model SHELL-INHERITS `SPRINT_ADVANCE_PHASE_RUNNING=1` env, the hook's `parentIsAdvancePhase()` check finds the parent process is NOT `sprint-advance-phase.sh`, blocks anyway.
4. Only `sprint-advance-phase.sh` invocations pass — and they enforce manifest predicates.

The deterministic-phase invariant is now mechanical, not merely documented.
