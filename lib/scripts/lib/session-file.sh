#!/usr/bin/env bash
# session-file.sh — session-context file management for parallel sprints.
#
# Sprint harness-parallel-safety-v2 AC-1: every Claude Code session resolves
# its active sprint via ~/.claude/sessions/<CLAUDE_SESSION_ID>/sprint-slug.
# Without this file, the hook falls back to env var, git branch, or returns
# NULL (no mtime fallback per AC-2).
#
# Session ID comes from $CLAUDE_SESSION_ID (or $CC_SESSION_ID legacy var).
# If neither is set, we degrade gracefully — write/read are no-ops. This lets
# scripts run outside Claude Code (CI, manual invocation) without errors.
#
# Usage:
#   source scripts/lib/session-file.sh
#   write_session_file "<slug>"   # called by sprint-start.sh
#   clear_session_file "<slug>"   # called by sprint-end.sh (only clears if match)
#   read_session_file              # returns current slug or empty
#
# All operations are best-effort. Lock-free (single-file write is atomic enough
# for the typical "set once per session" pattern). 0700 parent dir, 0600 file.

_session_id() {
  echo "${CLAUDE_SESSION_ID:-${CC_SESSION_ID:-}}"
}

_session_dir() {
  local sid
  sid="$(_session_id)"
  [ -z "$sid" ] && return 1
  echo "${HOME}/.claude/sessions/${sid}"
}

write_session_file() {
  local slug="$1"
  local dir
  if ! dir="$(_session_dir)"; then
    return 0  # No session id — silent no-op (CI, manual).
  fi
  ( umask 077; mkdir -p "$dir" )
  printf '%s\n' "$slug" > "$dir/sprint-slug"
  chmod 0600 "$dir/sprint-slug" 2>/dev/null
}

read_session_file() {
  local dir
  if ! dir="$(_session_dir)"; then
    return 0
  fi
  local f="$dir/sprint-slug"
  [ -f "$f" ] && cat "$f" | tr -d '[:space:]'
}

clear_session_file() {
  # Only remove if the file's content matches the supplied slug — protects
  # against sprint A's end.sh accidentally clearing sprint B's session file.
  local expected="$1"
  local dir
  if ! dir="$(_session_dir)"; then
    return 0
  fi
  local f="$dir/sprint-slug"
  [ -f "$f" ] || return 0
  local actual
  actual=$(cat "$f" | tr -d '[:space:]')
  if [ "$actual" = "$expected" ]; then
    rm -f "$f"
  fi
}
