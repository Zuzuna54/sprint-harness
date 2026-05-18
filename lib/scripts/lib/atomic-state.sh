#!/usr/bin/env bash
# atomic-state.sh — atomic mutation of docs/sprints/<slug>/state.json.
#
# Sprint harness-parallel-safety-v2 AC-3: replaces the unsafe pattern of
#
#     jq '<filter>' state.json > /tmp/st.json && mv /tmp/st.json state.json
#
# in 16 sprint scripts. Three classes of bugs eliminated:
#   1. Cross-FS mv (when /tmp is a different filesystem than docs/) — non-atomic
#      rename, leaves half-written state.json visible to readers.
#   2. SIGKILL between jq and mv — readers see stale state.json forever.
#   3. Concurrent writers from parallel sprints — last-write-wins clobber.
#
# This helper:
#   1. Acquires a per-slug flock (10s timeout) — serializes concurrent writers.
#   2. mktemp ON THE SAME FILESYSTEM as the target — atomic mv guaranteed by
#      POSIX rename(2) on APFS / ext4 / xfs (security blocker B1).
#   3. Applies the jq filter to a temp file.
#   4. Validates the result is parseable JSON (jq empty).
#   5. Creates a .bak backup of the current state.json.
#   6. Atomically renames temp → state.json.
#   7. Removes the .bak on success.
#
# Recovery contract:
#   - If killed between (5) and (6): state.json is intact (older), .bak exists.
#     Caller can resume — the operation simply didn't happen.
#   - If killed between (6) and (7): state.json is new, .bak exists temporarily.
#     Readers see the post-write state. .bak is cleaned on next call.
#   - If state.json is missing AND state.json.bak exists: callers SHOULD restore
#     from .bak (see recover_state_from_bak below). The reasserter (AC-7) is
#     instructed to skip-and-log on a missing state.json rather than mutate.
#
# Usage:
#   source scripts/lib/atomic-state.sh
#   atomic_update_state <slug> '<jq-filter-expression>'
#
# Example:
#   atomic_update_state my-sprint '.phase = "building" | .day = 3'
#
# Exit codes:
#   0 — write succeeded.
#   1 — flock timeout, jq filter failed, or validation failed (state untouched).

# Resolve our own directory regardless of how we're invoked (sourced or exec'd,
# absolute or relative path, called with `bash -c`, etc.).
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _atomic_state_self="${BASH_SOURCE[0]}"
else
  _atomic_state_self="$0"
fi
_atomic_state_dir="$(cd "$(dirname "$_atomic_state_self")" && pwd)"
# shellcheck disable=SC1091
source "$_atomic_state_dir/lock-dir.sh"

atomic_update_state() {
  local slug="$1"
  local filter="$2"
  local repo_root
  repo_root="$(cd "$_atomic_state_dir/../.." && pwd)"
  local state_file="$repo_root/docs/sprints/$slug/state.json"
  local lock_file="$LOCK_DIR/state-$slug.lock"
  local bak="$state_file.bak"
  local tmp_file
  local rc

  if [ ! -f "$state_file" ]; then
    echo "[atomic-state] state.json not found for slug $slug: $state_file" >&2
    return 1
  fi

  # Per-slug serialization. Prefer util-linux `flock` (atomic, kernel-backed).
  # macOS doesn't ship it by default — fall back to PID-noclobber lock that
  # the existing state-lock.sh helper has battle-tested. Same correctness
  # guarantees: only one writer at a time per slug; stale locks (>30s + dead
  # holder) are reclaimed.
  local _have_flock=0
  if command -v flock >/dev/null 2>&1; then
    _have_flock=1
  fi
  if [ "$_have_flock" -eq 1 ]; then
    exec 9>"$lock_file"
    if ! flock -w 10 9; then
      echo "[atomic-state] flock timeout for slug $slug (>10s)" >&2
      exec 9>&-
      return 1
    fi
  else
    # PID-noclobber fallback. set -C makes `>` fail if file exists. Retry up
    # to 5 times (10s) with 30s stale reclaim.
    local _retries=0
    while [ "$_retries" -lt 5 ]; do
      if ( set -C; echo "$$" > "$lock_file" ) 2>/dev/null; then
        break
      fi
      # Stale-lock reclaim. Two cases: holder PID is dead+30s OR file is
      # empty/unreadable (an artifact of a previous failed flock acquire).
      if [ -f "$lock_file" ]; then
        local holder
        holder=$(cat "$lock_file" 2>/dev/null || echo "")
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -f %m "$lock_file" 2>/dev/null || stat -c %Y "$lock_file" 2>/dev/null || echo 0) ))
        local _stale=0
        if [ -z "$holder" ] && [ "$lock_age" -gt 5 ]; then
          _stale=1
        fi
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null && [ "$lock_age" -gt 30 ]; then
          _stale=1
        fi
        if [ "$_stale" -eq 1 ]; then
          rm -f "$lock_file"
          continue
        fi
      fi
      sleep 2
      _retries=$((_retries + 1))
    done
    if [ "$_retries" -ge 5 ]; then
      echo "[atomic-state] pid-lock timeout for slug $slug (>10s)" >&2
      return 1
    fi
    # Auto-release on function return (best-effort)
    trap "rm -f '$lock_file'" RETURN
  fi

  # mktemp in the SAME directory as state.json — guarantees same-filesystem,
  # which is required for atomic rename(2).
  if ! tmp_file="$(mktemp "$(dirname "$state_file")/.state.tmp.XXXXXX")"; then
    echo "[atomic-state] mktemp failed in $(dirname "$state_file")" >&2
    _release_lock
    return 1
  fi

  # Apply filter.
  if ! jq "$filter" "$state_file" > "$tmp_file" 2>/dev/null; then
    echo "[atomic-state] jq filter failed: $filter" >&2
    rm -f "$tmp_file"
    _release_lock
    return 1
  fi

  # Validate result is parseable.
  if ! jq empty "$tmp_file" 2>/dev/null; then
    echo "[atomic-state] jq output is not valid JSON" >&2
    rm -f "$tmp_file"
    _release_lock
    return 1
  fi

  # Backup, then atomic rename.
  cp -p "$state_file" "$bak"
  mv "$tmp_file" "$state_file"
  rc=$?

  # Cleanup .bak on success; leave it if mv failed for diagnostics.
  if [ "$rc" -eq 0 ]; then
    rm -f "$bak"
  fi

  _release_lock
  return "$rc"
}

# Internal: release lock acquired earlier in atomic_update_state. Reads
# `$_have_flock` and `$lock_file` from caller scope.
_release_lock() {
  if [ "${_have_flock:-0}" -eq 1 ]; then
    flock -u 9 2>/dev/null
    exec 9>&-
  else
    rm -f "$lock_file"
  fi
}

# Called by resolution chain on missing state.json — restore from .bak if
# present. Best-effort; returns 0 if restored, 1 if nothing to restore.
recover_state_from_bak() {
  local slug="$1"
  local repo_root
  repo_root="$(cd "$_atomic_state_dir/../.." && pwd)"
  local state_file="$repo_root/docs/sprints/$slug/state.json"
  local bak="$state_file.bak"

  if [ ! -f "$state_file" ] && [ -f "$bak" ]; then
    if jq empty "$bak" 2>/dev/null; then
      mv "$bak" "$state_file"
      echo "[atomic-state] recovered state.json for $slug from .bak" >&2
      return 0
    fi
  fi
  return 1
}
