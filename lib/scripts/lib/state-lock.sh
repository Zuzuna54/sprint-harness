#!/usr/bin/env bash
# state-lock.sh — atomic state.json write coordinator.
#
# Per lifeos-state-json-lock memory pattern from sprint-system-100. Every
# concurrent writer to state.json must acquire state.json.lock (set -C
# noclobber, 5 retries, 30s stale reclaim) before mutating. Without this,
# concurrent jq pipes from different Claude sessions / hooks / workflows
# torn-write the file.
#
# Usage:
#   source scripts/lib/state-lock.sh
#   with_state_lock <state-file-path> <function-name>
#
# The wrapped function receives no args; it reads/writes the file directly.
# Lock is released automatically (trap EXIT). Stale locks (>30s with dead
# holder) are reclaimed.
#
# Exit codes:
#   0 — lock acquired + function ran successfully
#   1 — could not acquire lock after 5 retries (10s total)
#   2 — function returned non-zero

LOCK_STALE_SECS=30
LOCK_MAX_RETRIES=5
LOCK_BACKOFF_SECS=2

with_state_lock() {
  local state_file="$1"
  local fn="$2"
  local lock_file="${state_file}.lock"
  local holder
  local lock_age
  local pid

  for ((i=0; i<LOCK_MAX_RETRIES; i++)); do
    if ( set -C; echo "$$" > "$lock_file" ) 2>/dev/null; then
      # Acquired
      trap "rm -f '$lock_file'" EXIT INT TERM
      "$fn"
      local rc=$?
      rm -f "$lock_file"
      trap - EXIT INT TERM
      return $rc
    fi

    # Lock held by someone — check if stale
    if [ -f "$lock_file" ]; then
      holder="$(cat "$lock_file" 2>/dev/null || echo)"
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        # Holder process dead — reclaim
        rm -f "$lock_file"
        continue
      fi
      # Holder alive — check age
      lock_age=$(($(date +%s) - $(stat -f %m "$lock_file" 2>/dev/null || stat -c %Y "$lock_file" 2>/dev/null || echo 0)))
      if [ "$lock_age" -gt "$LOCK_STALE_SECS" ]; then
        echo "[state-lock] reclaiming stale lock (age ${lock_age}s, holder=$holder)" >&2
        rm -f "$lock_file"
        continue
      fi
    fi
    sleep "$LOCK_BACKOFF_SECS"
  done

  echo "[state-lock] could not acquire $lock_file after $LOCK_MAX_RETRIES retries" >&2
  return 1
}

# Convenience: in-place jq with lock.
# Usage: jq_state_lock <state-file> <jq-filter>
# Note: bash 3.2 doesn't support `local _fn() { ... }`, so the wrapper
# defines a global function temporarily.
jq_state_lock() {
  local state_file="$1"
  local filter="$2"
  __state_lock_jq_runner() {
    local tmp
    tmp="$(mktemp)"
    jq "$filter" "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  }
  with_state_lock "$state_file" __state_lock_jq_runner
  unset -f __state_lock_jq_runner
}
