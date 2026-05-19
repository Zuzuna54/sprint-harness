#!/usr/bin/env bash
# sub-step.sh — atomic, idempotent recording of sub-step gate completion.
#
# Public API:
#   record_sub_step <slug> <gate-name> <verdict> [evidence-path]
#     verdict ∈ {pass, fail, bypassed}
#     evidence-path is optional; if present, stored as a relative path
#     (relative to docs/sprints/<slug>/).
#
#   Idempotent on (slug, gate-name): re-recording same gate updates `at`
#   timestamp, does not duplicate the entry.
#
#   Dual-write: appends to BOTH state.gates_passed[] (canonical, v0.7+) AND
#   state.gates[] (legacy compat). Replay validator + sub_step_recorded
#   predicate read union of both. Both fields drop bare-string legacy entries
#   that match the new gate name — they get upgraded to object form on first
#   re-record.
#
# Exit: 0 on success, 1 on atomic_update_state failure or bad input.
#
# Used by: sprint-advance-phase.sh, sprint-spec-wizard.mjs, sprint-checkin.sh,
# sprint-cleanup-launch.sh, sprint-verify.sh, sprint-end.sh, etc.

set -uo pipefail

_ss_self="${BASH_SOURCE[0]:-$0}"
_ss_dir="$(cd "$(dirname "$_ss_self")" && pwd)"
# shellcheck disable=SC1091
source "$_ss_dir/atomic-state.sh"

record_sub_step() {
  local slug="$1"
  local gate="$2"
  local verdict="${3:-pass}"
  local evidence="${4:-}"

  if [ -z "$slug" ] || [ -z "$gate" ]; then
    echo "[record_sub_step] usage: record_sub_step <slug> <gate-name> <verdict> [evidence]" >&2
    return 1
  fi

  case "$verdict" in
    pass|fail|bypassed) ;;
    *)
      echo "[record_sub_step] verdict must be pass|fail|bypassed (got '$verdict')" >&2
      return 1
      ;;
  esac

  # L13 (closure Wave C): canonicalize evidence path. Reject `..` traversal;
  # convert absolute paths inside REPO_ROOT to repo-relative. Security review
  # S9 + S13 follow-up.
  if [ -n "$evidence" ]; then
    if [[ "$evidence" == *".."* ]]; then
      echo "[record_sub_step] evidence path '..' traversal rejected: $evidence" >&2
      return 1
    fi
    local _repo_root
    _repo_root="$(cd "$_atomic_state_dir/../.." && pwd 2>/dev/null)" || _repo_root=""
    if [[ "$evidence" == /* ]] && [ -n "$_repo_root" ] && [[ "$evidence" == "$_repo_root"/* ]]; then
      evidence="${evidence#$_repo_root/}"
    fi
  fi

  # L16 (closure Wave C): warn (don't block) if gate name unknown to manifest.
  # Catches typos at record-time before they fail at replay-time.
  local _manifest="$_atomic_state_dir/phase-manifest.json"
  if [ -f "$_manifest" ] && command -v jq >/dev/null 2>&1; then
    local _known
    _known=$(jq -r --arg g "$gate" '
      ([.phases[] | (.required_sub_step_gates // []), (.strict_only_sub_step_gates // [])] | flatten | index($g)) // empty
    ' "$_manifest" 2>/dev/null)
    if [ -z "$_known" ]; then
      echo "[record_sub_step] [WARN] gate '$gate' not declared in phase-manifest.json (typo? bootstrap? recording anyway)" >&2
    fi
  fi

  local at
  at="$(date -u +%FT%TZ)"

  # The jq filter normalizes legacy bare-string entries (e.g. "spec-lock") to
  # objects, drops any existing entry with the same gate name (idempotent),
  # then appends the new object. Dual-writes to both gates_passed and gates.
  local filter='
    def upsert(arr; g; obj):
      (arr // [])
      | map(if type=="string" then {gate: ., at: null, verdict: "pass"} else . end)
      | map(select(.gate != g))
      | . + [obj];

    . as $st |
    ($evidence | if . == "" then null else . end) as $ev |
    {gate: $gate, at: $at, verdict: $verdict, evidence: $ev} as $entry |
    .gates_passed = upsert($st.gates_passed; $gate; $entry) |
    .gates        = upsert($st.gates;        $gate; $entry)
  '

  atomic_update_state "$slug" \
    --arg gate "$gate" \
    --arg at "$at" \
    --arg verdict "$verdict" \
    --arg evidence "$evidence" \
    "$filter"
}
