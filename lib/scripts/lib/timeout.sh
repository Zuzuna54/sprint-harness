#!/usr/bin/env bash
# scripts/lib/timeout.sh — portable timeout wrapper.
#
# macOS doesn't ship GNU `timeout`. This wrapper falls back gracefully:
#   1. gtimeout (from `brew install coreutils`) — preferred
#   2. perl alarm fallback (always available on macOS/Linux)
#
# Usage:
#   bash scripts/lib/timeout.sh <seconds> <command...>
#
# Exit codes:
#   124 = timed out
#   else = command's actual exit code
set -uo pipefail

SECS="${1:?timeout seconds required}"
shift

if command -v gtimeout >/dev/null 2>&1; then
  exec gtimeout "$SECS" "$@"
elif command -v timeout >/dev/null 2>&1; then
  exec timeout "$SECS" "$@"
else
  # perl fallback. Run child in subshell, kill after $SECS, return 124 on timeout.
  ( "$@" ) &
  CHILD=$!
  ( sleep "$SECS" && kill -TERM "$CHILD" 2>/dev/null ) &
  WATCH=$!
  wait "$CHILD" 2>/dev/null
  RC=$?
  if kill -0 "$WATCH" 2>/dev/null; then
    kill "$WATCH" 2>/dev/null
    exit $RC
  else
    # Watcher fired (timed out)
    exit 124
  fi
fi
