#!/usr/bin/env bash
# lock-dir.sh — resolve $LOCK_DIR for sprint harness concurrency primitives.
#
# Sprint harness-parallel-safety-v2 AC-6 (security B2): lock files must live
# in a 0700 directory, not bare /tmp/$(id -u)-* where they're world-readable.
# Snooping/DoS via flock-hold is the threat.
#
# Resolution order:
#   1. $XDG_RUNTIME_DIR/lifeos          (Linux user-runtime, already 0700)
#   2. $HOME/.cache/lifeos/locks        (macOS / Linux without XDG)
#
# Exports LOCK_DIR. Idempotent — safe to source multiple times.
#
# Usage:
#   source scripts/lib/lock-dir.sh
#   exec 9>"$LOCK_DIR/state-$slug.lock"
#   flock -w 10 9

if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
  export LOCK_DIR="$XDG_RUNTIME_DIR/lifeos"
else
  export LOCK_DIR="$HOME/.cache/lifeos/locks"
fi

# Create with 0700 perms via umask; parent dirs inherit 0700 perms.
( umask 077; mkdir -p "$LOCK_DIR" ) || {
  echo "[lock-dir] could not create $LOCK_DIR" >&2
  return 1 2>/dev/null || exit 1
}
