#!/usr/bin/env bash
# sprint-advance-phase.sh — the canonical sprint phase mutator.
#
# THIS IS THE ONLY SCRIPT THAT MAY WRITE state.phase. Every other phase-writer
# (sprint-amend-spec.sh --lock, sprint-design-lock.sh, sprint-build-launch.sh,
#  sprint-checkin.sh, sprint-cleanup-launch.sh, sprint-verify.sh,
#  sprint-predeploy-gate.sh, sprint-end.sh, sprint-pause.sh, sprint-resume.sh)
# delegates the actual phase write to this script via:
#
#   bash scripts/sprint-advance-phase.sh <next-phase> [--from <expected-current>]
#
# Algorithm:
#   1. Resolve slug via standard chain (env override → session-file → state.json).
#   2. Validate JSON manifest (scripts/lib/phase-manifest.json) via validator.
#   3. Read current phase from state.json. If <expected-current> given and
#      doesn't match → exit 1 (caller's invariant violated).
#   4. Idempotent: if current == <next-phase>, exit 0 (no-op).
#   5. Verify the transition is in manifest[current].advances_to. Exit 1 if not.
#   6. Run check_phase_requirements <slug> <current> → if fail, exit 1 with
#      predicate trace UNLESS each failing predicate is bypassed via
#      SPRINT_BYPASS_GATE + SPRINT_BYPASS_WHY.
#   7. Atomic write: append gate_history entry + set .phase to <next-phase>.
#      Exports SPRINT_ADVANCE_PHASE_RUNNING=1 to indicate to the PreToolUse
#      hook that this write is sanctioned.
#
# Exit codes:
#   0 — phase advanced (or already at target)
#   1 — manifest validation failed, predicate check failed, illegal transition,
#       or atomic write failed
#   2 — argument error

set -uo pipefail

# ── Resolve own location ─────────────────────────────────────────────────────
_ap_self="${BASH_SOURCE[0]:-$0}"
_ap_dir="$(cd "$(dirname "$_ap_self")" && pwd)"
_ap_repo_root="$(cd "$_ap_dir/.." && pwd)"

# shellcheck disable=SC1091
source "$_ap_dir/lib/atomic-state.sh"
# shellcheck disable=SC1091
source "$_ap_dir/lib/session-file.sh"
# shellcheck disable=SC1091
source "$_ap_dir/lib/phase-predicates.sh"
# shellcheck disable=SC1091
source "$_ap_dir/lib/sub-step.sh"
# shellcheck disable=SC1091
source "$_ap_dir/lib/bypass.sh"

# ── Args ─────────────────────────────────────────────────────────────────────
NEXT_PHASE="${1:-}"
EXPECTED_CURRENT=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --from)        EXPECTED_CURRENT="$2"; shift 2 ;;
    --from=*)      EXPECTED_CURRENT="${1#--from=}"; shift ;;
    --help|-h)
      sed -n '2,30p' "$_ap_self"
      exit 0
      ;;
    *)
      echo "[sprint-advance-phase] unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$NEXT_PHASE" ]; then
  echo "[sprint-advance-phase] usage: sprint-advance-phase.sh <next-phase> [--from <expected-current>]" >&2
  exit 2
fi

# ── Mark ourselves as the sanctioned phase mutator (for PreToolUse hook) ─────
export SPRINT_ADVANCE_PHASE_RUNNING=1

# ── Resolve slug ─────────────────────────────────────────────────────────────
SLUG=""
if [ -n "${SPRINT_SLUG_OVERRIDE:-}" ]; then
  SLUG="$SPRINT_SLUG_OVERRIDE"
elif [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SLUG="$(get_session_slug "$CLAUDE_SESSION_ID" 2>/dev/null || true)"
fi
if [ -z "$SLUG" ]; then
  # Fall back: scan docs/sprints/*/state.json for phase != done && != paused
  SLUG=$(find "$_ap_repo_root/docs/sprints" -maxdepth 2 -name state.json 2>/dev/null \
    | while read -r f; do
        ph=$(jq -r '.phase' "$f" 2>/dev/null)
        if [ "$ph" != "done" ] && [ "$ph" != "paused" ] && [ "$ph" != "null" ]; then
          jq -r '.slug' "$f"
          break
        fi
      done | head -1)
fi
if [ -z "$SLUG" ]; then
  echo "[sprint-advance-phase] no active sprint resolved (set SPRINT_SLUG_OVERRIDE)" >&2
  exit 1
fi

STATE_FILE="$_ap_repo_root/docs/sprints/$SLUG/state.json"
if [ ! -f "$STATE_FILE" ]; then
  echo "[sprint-advance-phase] state.json not found: $STATE_FILE" >&2
  exit 1
fi

# Make SLUG available to bypass.sh
export SLUG

# ── Mutex: prevent concurrent advance-phase invocations for the same slug.
# Two parallel invocations both fire daemon workers in parallel and race each
# other's atomic_update_state writes (observed during harness-review-resolution-v1
# walk: caller A fired audit + testgaps for 80s while caller B re-fired them,
# both stomping on worker_runs[]). flock at sprint-dir level (with portable
# set -C noclobber fallback for macOS) serializes them. Stale-lock reclaim: 30s.
_ap_lockfile="$_ap_repo_root/docs/sprints/$SLUG/.advance.lock"
_ap_have_flock=0
command -v flock >/dev/null 2>&1 && _ap_have_flock=1

if [ "$_ap_have_flock" -eq 1 ]; then
  exec 9>"$_ap_lockfile"
  if ! flock -w 30 9; then
    echo "[sprint-advance-phase] another advance-phase for $SLUG in flight (lock=$_ap_lockfile, waited 30s)" >&2
    exit 1
  fi
else
  # macOS fallback: set -C noclobber lock with stale-reclaim after 30s
  _ap_attempts=0
  while [ "$_ap_attempts" -lt 30 ]; do
    if ( set -C; echo "$$" > "$_ap_lockfile" ) 2>/dev/null; then
      break
    fi
    # Stale-reclaim: holder PID not alive OR lockfile older than 60s
    if [ -f "$_ap_lockfile" ]; then
      _ap_holder=$(cat "$_ap_lockfile" 2>/dev/null || echo "")
      _ap_age=$(($(date +%s) - $(stat -f %m "$_ap_lockfile" 2>/dev/null || echo 0)))
      if [ -n "$_ap_holder" ] && ! kill -0 "$_ap_holder" 2>/dev/null; then
        rm -f "$_ap_lockfile"
        continue
      elif [ "$_ap_age" -gt 60 ]; then
        echo "[sprint-advance-phase] reclaiming stale lock ($_ap_age s, holder=$_ap_holder)" >&2
        rm -f "$_ap_lockfile"
        continue
      fi
    fi
    sleep 1
    _ap_attempts=$((_ap_attempts + 1))
  done
  if [ "$_ap_attempts" -ge 30 ]; then
    echo "[sprint-advance-phase] another advance-phase for $SLUG in flight (waited 30s)" >&2
    exit 1
  fi
  # Cleanup on exit
  trap 'rm -f "$_ap_lockfile" 2>/dev/null || true' EXIT
fi

# ── Validate manifest (T2.1: moved here so bypass-validation can read it) ─────
MANIFEST="$_ap_dir/lib/phase-manifest.json"
if ! node "$_ap_dir/lib/validate-phase-manifest.mjs" "$MANIFEST" >&2; then
  echo "[sprint-advance-phase] manifest validation failed" >&2
  exit 1
fi

# ── Pre-write any requested bypasses (T2.1 — validate against manifest first) ──
# SPRINT_BYPASS_GATE may be a single gate name OR a comma-separated list.
# Each gate gets the same SPRINT_BYPASS_WHY rationale.
#
# T2.1 fix: validate every requested gate against the manifest BEFORE
# recording. A typo like `SPRINT_BYPASS_GATE=desgin-locked` previously
# silently recorded a meaningless bypass for a non-existent gate. Now it
# rejects with a clear "unknown bypass gate" error.
#
# Two categories of valid bypass gate names:
#   1. sub-step gate names — listed in required_sub_step_gates[] or
#      strict_only_sub_step_gates[] of any phase
#   2. artifact-path gates — file paths (predicate.path or .json_path)
#      mentioned in required_artifacts[] or required_state_fields[]
#      Recognized by containing `.` or `/` (path-shaped).
if [ -n "${SPRINT_BYPASS_GATE:-}" ]; then
  # Build the allowed-gate set from the manifest (once, outside the loop).
  # Includes ALL phases' sub-step + strict-only gates.
  _ap_known_gates=$(jq -r '
    [
      .phases[] | (.required_sub_step_gates // []), (.strict_only_sub_step_gates // [])
    ] | flatten | unique | .[]
  ' "$MANIFEST" 2>/dev/null)

  # harness-review-resolution-v1 closeout enhancement: worker names from
  # phase-workers.json are also valid bypass targets (matches the stderr
  # hint emitted on blocking-worker failure).
  _ap_known_workers=""
  _wm="$(cd "$(dirname "$0")" && pwd)/lib/phase-workers.json"
  if [ -f "$_wm" ]; then
    _ap_known_workers=$(jq -r '[.phases[] | (.on_entry // [])] | flatten | unique | .[]' "$_wm" 2>/dev/null)
  fi

  IFS=',' read -r -a _bypass_gates <<< "$SPRINT_BYPASS_GATE"
  for _g in "${_bypass_gates[@]+"${_bypass_gates[@]}"}"; do
    _g=$(echo "$_g" | tr -d ' ')
    [ -z "$_g" ] && continue

    # Path-shaped? (contains `.` or `/`) → accept as artifact-path bypass
    if [[ "$_g" == *"."* ]] || [[ "$_g" == *"/"* ]]; then
      :  # accept
    elif echo "$_ap_known_gates" | grep -Fxq "$_g"; then
      :  # accept — sub-step gate name found in manifest
    elif echo "$_ap_known_workers" | grep -Fxq "$_g"; then
      :  # accept — phase-workers.json worker name
    else
      echo "[sprint-advance-phase] unknown bypass gate: '$_g'" >&2
      echo "[sprint-advance-phase] not found in phase-manifest.json sub-step gates and not path-shaped" >&2
      echo "[sprint-advance-phase] valid gates (sample): $(echo "$_ap_known_gates" | head -5 | tr '\n' ' ')" >&2
      echo "[sprint-advance-phase] valid path-shaped: e.g., 'design.md', 'docs/sprints/<slug>/x.json'" >&2
      exit 1
    fi

    SPRINT_BYPASS_GATE="$_g" check_bypass "$_g" || true
  done
fi

# ── Read current phase ───────────────────────────────────────────────────────
# (manifest validation already happened above before bypass-validation, T2.1)
CURRENT_PHASE=$(jq -r '.phase' "$STATE_FILE")
echo "[sprint-advance-phase] slug=$SLUG current=$CURRENT_PHASE target=$NEXT_PHASE" >&2

# Idempotent: already there
if [ "$CURRENT_PHASE" = "$NEXT_PHASE" ]; then
  echo "[sprint-advance-phase] already at $NEXT_PHASE — no-op" >&2
  exit 0
fi

# --from invariant
if [ -n "$EXPECTED_CURRENT" ] && [ "$CURRENT_PHASE" != "$EXPECTED_CURRENT" ]; then
  echo "[sprint-advance-phase] --from $EXPECTED_CURRENT but current is $CURRENT_PHASE" >&2
  exit 1
fi

# ── Validate transition allowed by manifest ──────────────────────────────────
ALLOWED=$(jq -r --arg p "$CURRENT_PHASE" --arg n "$NEXT_PHASE" '
  (.phases[$p].advances_to // []) | index($n) != null
' "$MANIFEST")
if [ "$ALLOWED" != "true" ]; then
  echo "[sprint-advance-phase] illegal transition: $CURRENT_PHASE → $NEXT_PHASE" >&2
  ALLOWED_LIST=$(jq -r --arg p "$CURRENT_PHASE" '.phases[$p].advances_to // [] | join(", ")' "$MANIFEST")
  echo "[sprint-advance-phase] $CURRENT_PHASE allows transitions to: $ALLOWED_LIST" >&2
  exit 1
fi

# ── Run predicate check for current phase ────────────────────────────────────
if ! check_phase_requirements "$SLUG" "$CURRENT_PHASE"; then
  echo "[sprint-advance-phase] phase $CURRENT_PHASE has unsatisfied requirements — NOT advancing" >&2
  echo "[sprint-advance-phase] options:" >&2
  echo "  1) Fix the [FAIL] predicates above and re-run" >&2
  echo "  2) Bypass a specific gate: SPRINT_BYPASS_GATE=<gate> SPRINT_BYPASS_WHY='<reason>' bash $0 $NEXT_PHASE" >&2
  exit 1
fi

# ── W2 (harness-truthful-docs-and-wiring-v1, AC-2): phase-entry workers ──
# Read scripts/lib/phase-workers.json for workers declared on NEXT_PHASE entry.
# Each worker is invoked via worker-trigger.sh (best-effort; non-blocking by
# default). Output captured to docs/sprints/<slug>/worker-output/<worker>.json.
# Recorded in state.worker_runs[] regardless of success (succeeded / failed /
# skipped-daemon-down). Workers in blocking_workers[] abort phase advance on
# failure with clear stderr + bypass instructions.
WORKERS_MANIFEST="$(cd "$(dirname "$0")" && pwd)/lib/phase-workers.json"
if [ -f "$WORKERS_MANIFEST" ] && command -v jq >/dev/null 2>&1; then
  WORKERS_ON_ENTRY=$(jq -r --arg p "$NEXT_PHASE" '.phases[$p].on_entry // [] | .[]' "$WORKERS_MANIFEST" 2>/dev/null)
  BLOCKING_WORKERS=$(jq -r --arg p "$NEXT_PHASE" '.phases[$p].blocking_workers // [] | .[]' "$WORKERS_MANIFEST" 2>/dev/null)
  if [ -n "$WORKERS_ON_ENTRY" ]; then
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "$0")" && pwd)/lib/worker-trigger.sh" 2>/dev/null || {
      echo "[sprint-advance-phase] [WARN] worker-trigger.sh unavailable — skipping phase-workers for $NEXT_PHASE" >&2
      WORKERS_ON_ENTRY=""
    }
  fi
  for worker in $WORKERS_ON_ENTRY; do
    WORKER_AT="$(date -u +%FT%TZ)"
    IS_BLOCKING="false"
    for bw in $BLOCKING_WORKERS; do
      [ "$bw" = "$worker" ] && IS_BLOCKING="true"
    done
    # harness-review-resolution-v1 closeout enhancement: honor SPRINT_BYPASS_GATE
    # for worker names too, matching the stderr hint emitted on blocking-worker
    # failure. Bypass records to gate_bypasses[] + worker_runs[] as skipped.
    _worker_bypassed=0
    if [ -n "${SPRINT_BYPASS_GATE:-}" ]; then
      IFS=',' read -r -a _wb_gates <<< "$SPRINT_BYPASS_GATE"
      for _wg in "${_wb_gates[@]+"${_wb_gates[@]}"}"; do
        _wg=$(echo "$_wg" | tr -d ' ')
        if [ "$_wg" = "$worker" ]; then
          _worker_bypassed=1
          echo "[sprint-advance-phase] worker '$worker' BYPASSED via SPRINT_BYPASS_GATE" >&2
          atomic_update_state "$SLUG" \
            --arg w "$worker" --arg at "$WORKER_AT" --arg p "$NEXT_PHASE" \
            '.worker_runs = ((.worker_runs // []) + [{worker: $w, at: $at, status: "bypassed", phase: $p, blocking: false}])' \
            2>/dev/null || true
          break
        fi
      done
    fi
    if [ "$_worker_bypassed" = "1" ]; then continue; fi
    echo "[sprint-advance-phase] firing worker '$worker' on entry to $NEXT_PHASE (blocking=$IS_BLOCKING)" >&2
    if trigger_worker "$worker" "$SLUG" "${WORKER_TIMEOUT_S:-300}"; then
      WORKER_STATUS="succeeded"
    else
      WORKER_RC=$?
      WORKER_STATUS="failed"
      [ "$WORKER_RC" -eq 1 ] && WORKER_STATUS="skipped-daemon-down"
      if [ "$IS_BLOCKING" = "true" ]; then
        echo "[sprint-advance-phase] BLOCKING worker '$worker' failed ($WORKER_STATUS) — NOT advancing to $NEXT_PHASE" >&2
        echo "[sprint-advance-phase] bypass: SPRINT_BYPASS_GATE=$worker SPRINT_BYPASS_WHY='<reason>' bash $0 $NEXT_PHASE" >&2
        atomic_update_state "$SLUG" \
          --arg w "$worker" --arg at "$WORKER_AT" --arg s "$WORKER_STATUS" --arg p "$NEXT_PHASE" \
          '.worker_runs = ((.worker_runs // []) + [{worker: $w, at: $at, status: $s, phase: $p, blocking: true}])' \
          2>/dev/null || true
        exit 1
      fi
    fi
    atomic_update_state "$SLUG" \
      --arg w "$worker" --arg at "$WORKER_AT" --arg s "$WORKER_STATUS" --arg p "$NEXT_PHASE" \
      '.worker_runs = ((.worker_runs // []) + [{worker: $w, at: $at, status: $s, phase: $p, blocking: false}])' \
      2>/dev/null || true
  done
fi

# ── All checks passed. Write atomic phase transition. ────────────────────────
# L12 (closure Wave C): TOCTOU-safe — assert .phase still equals $current at
# write time. If another process advanced the phase between our T0 read and
# this write, abort with clear error. Security review S7 follow-up.
AT=$(date -u +%FT%TZ)
GATE_HISTORY_FILTER='
  if .phase != $current
    then error("phase changed mid-advance: expected \($current), got \(.phase). Re-read state and retry.")
    else
      .prev_phase = $current |
      .phase = $next |
      .gate_history = ((.gate_history // []) + [{
        from: $current,
        to: $next,
        at: $at,
        by: "sprint-advance-phase.sh"
      }])
  end
'
# Add design_locked_at / predeploy_at / closed_at where appropriate.
case "$NEXT_PHASE" in
  design-locked)
    GATE_HISTORY_FILTER="$GATE_HISTORY_FILTER | .design_locked_at = \$at"
    ;;
  pre-deploy)
    GATE_HISTORY_FILTER="$GATE_HISTORY_FILTER | .predeploy_at = \$at"
    ;;
  done)
    GATE_HISTORY_FILTER="$GATE_HISTORY_FILTER | .closed_at = \$at"
    ;;
esac

atomic_update_state "$SLUG" \
  --arg current "$CURRENT_PHASE" \
  --arg next "$NEXT_PHASE" \
  --arg at "$AT" \
  "$GATE_HISTORY_FILTER" \
  || { echo "[sprint-advance-phase] atomic write failed" >&2; exit 1; }

echo "[sprint-advance-phase] phase advanced: $CURRENT_PHASE → $NEXT_PHASE @ $AT" >&2
