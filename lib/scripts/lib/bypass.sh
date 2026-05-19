#!/usr/bin/env bash
# bypass.sh — single canonical bypass interface for the harness.
#
# Public API:
#   check_bypass <gate-name>
#     Returns 0 if SPRINT_BYPASS_GATE matches <gate-name> AND SPRINT_BYPASS_WHY
#     is non-empty (≥10 chars). On accepted bypass, appends to
#     state.gate_bypasses[] via atomic_update_state.
#     Returns 1 otherwise (bypass not requested OR _WHY missing/short).
#
#     Requires $SLUG to be set in the caller's env (resolved via the standard
#     session-file / SPRINT_SLUG_OVERRIDE / state.json chain by the caller).
#
#   deprecate_legacy_bypass <legacy-env-var-name> <new-gate-name>
#     If <legacy-env-var-name>=1 is set, prints a deprecation warning naming
#     the new bypass invocation, then short-circuits as if SPRINT_BYPASS_GATE
#     + SPRINT_BYPASS_WHY were set. Used by sprint-drift-check.sh,
#     sprint-design-lock.sh, etc. during the v0.7.x deprecation window.
#     Removal scheduled for v0.8.0.

set -uo pipefail

_bp_self="${BASH_SOURCE[0]:-$0}"
_bp_dir="$(cd "$(dirname "$_bp_self")" && pwd)"
# shellcheck disable=SC1091
source "$_bp_dir/atomic-state.sh"

# Minimum length for SPRINT_BYPASS_WHY rationale (chars). Empty + short alike rejected.
: "${BYPASS_WHY_MIN_CHARS:=10}"

check_bypass() {
  local gate="$1"

  if [ -z "${SPRINT_BYPASS_GATE:-}" ]; then
    return 1
  fi
  if [ "$SPRINT_BYPASS_GATE" != "$gate" ]; then
    return 1
  fi

  # Bypass requested for THIS gate. Validate rationale.
  if [ -z "${SPRINT_BYPASS_WHY:-}" ]; then
    echo "[bypass] SPRINT_BYPASS_GATE=$gate set but SPRINT_BYPASS_WHY missing" >&2
    echo "[bypass] Required: SPRINT_BYPASS_WHY='<reason, ≥${BYPASS_WHY_MIN_CHARS} chars>'" >&2
    return 1
  fi
  if [ "${#SPRINT_BYPASS_WHY}" -lt "$BYPASS_WHY_MIN_CHARS" ]; then
    echo "[bypass] SPRINT_BYPASS_WHY too short (${#SPRINT_BYPASS_WHY} chars, need ≥${BYPASS_WHY_MIN_CHARS})" >&2
    return 1
  fi

  local slug="${SLUG:-${SPRINT_SLUG_OVERRIDE:-}}"
  if [ -z "$slug" ]; then
    echo "[bypass] cannot record: SLUG / SPRINT_SLUG_OVERRIDE not set" >&2
    return 1
  fi

  local at
  at="$(date -u +%FT%TZ)"
  local caller
  caller="$(basename "${BASH_SOURCE[1]:-${0:-unknown}}")"

  # L14 (closure Wave C): redact PII (emails, JWTs, API keys, DB URLs) from
  # SPRINT_BYPASS_WHY before recording. Security review S11 follow-up.
  # state.gate_bypasses[] lives in git history; secrets must NEVER land there.
  # Uses sprint-pii-redact.sh if available; falls back to raw on error.
  local redacted_why="$SPRINT_BYPASS_WHY"
  local _redactor="$(dirname "${BASH_SOURCE[0]:-$0}")/../sprint-pii-redact.sh"
  if [ -x "$_redactor" ]; then
    local _r
    _r=$(printf '%s' "$SPRINT_BYPASS_WHY" | bash "$_redactor" 2>/dev/null || true)
    [ -n "$_r" ] && redacted_why="$_r"
  fi

  # Append bypass record. Idempotent on (gate, why) — re-using the same WHY
  # is allowed and refreshes the timestamp.
  atomic_update_state "$slug" \
    --arg gate "$gate" \
    --arg why "$redacted_why" \
    --arg at "$at" \
    --arg caller "$caller" \
    '.gate_bypasses = ((.gate_bypasses // []) | map(select(.gate != $gate)) + [{gate: $gate, why: $why, at: $at, caller: $caller}])'

  echo "[bypass] gate=$gate accepted (why=\"${redacted_why:0:60}$([ ${#redacted_why} -gt 60 ] && echo "…")\")" >&2
  return 0
}

deprecate_legacy_bypass() {
  local legacy_env="$1"
  local new_gate="$2"
  local val
  eval "val=\${$legacy_env:-}"
  if [ "$val" = "1" ]; then
    echo "[bypass] $legacy_env=1 is DEPRECATED in v0.7.x (removal in v0.8.0)." >&2
    echo "[bypass] Migrate to: SPRINT_BYPASS_GATE=$new_gate SPRINT_BYPASS_WHY='<reason>'" >&2
    # Auto-synthesize a synthetic bypass so the legacy call still works for v0.7.x.
    if [ -z "${SPRINT_BYPASS_GATE:-}" ]; then
      SPRINT_BYPASS_GATE="$new_gate"
      SPRINT_BYPASS_WHY="${SPRINT_BYPASS_WHY:-legacy-shim-from-$legacy_env}"
      export SPRINT_BYPASS_GATE SPRINT_BYPASS_WHY
    fi
    return 0
  fi
  return 1
}
