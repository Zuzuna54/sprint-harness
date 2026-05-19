#!/usr/bin/env bash
# worker-trigger.sh — invoke a ruflo daemon worker on-demand and capture output
# into the sprint's worker-output directory.
#
# Sprint harness on-demand worker integration (plan: ruflo workers → sprint-harness):
# instead of running workers on hardcoded 10-30 min intervals (which silently
# burns ~9h Sonnet/day against the user's OAuth quota), each worker fires only
# at a specific sprint-protocol checkpoint where its output is consumed by a
# gate or surfaced in a deliverable.
#
# How it works:
#  1. Ensure daemon is running (warm-but-empty per Q1).
#  2. `ruflo daemon trigger -w <worker>` queues the worker.
#  3. Poll `.claude-flow/metrics/<worker>.json` mtime every 2 s.
#  4. When mtime changes + file is parseable JSON → copy to
#     `docs/sprints/<slug>/worker-output/<worker>.{json,md}` (Q7).
#  5. Return 0 on success, 1 on timeout/empty.
#
# Auth note: workers shell out to `claude --print` which uses the operator's
# Claude Code OAuth session (Pro/Max subscription), NOT a separate API key. If
# the operator isn't authenticated locally, the worker fails with the standard
# Claude Code "not authenticated" message — caller decides whether to skip
# gracefully (local dev) or hard-fail (CI per Q8).
#
# Usage:
#   source scripts/lib/worker-trigger.sh
#   trigger_worker <worker-name> <slug> [timeout_seconds]
#
# Returns:
#   0 — worker output captured to docs/sprints/<slug>/worker-output/
#   1 — daemon down, trigger failed, or poll timeout
#   2 — caller error (missing args, bad slug)

# Resolve our own dir so siblings load regardless of how we're invoked.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _worker_trigger_self="${BASH_SOURCE[0]}"
else
  _worker_trigger_self="$0"
fi
_worker_trigger_dir="$(cd "$(dirname "$_worker_trigger_self")" && pwd)"
_repo_root="$(cd "$_worker_trigger_dir/../.." && pwd)"

# Bring in atomic-state for state.json updates + lock-dir for serialization.
# shellcheck disable=SC1091
source "$_worker_trigger_dir/atomic-state.sh"

# Default poll cadence + max wait. Most workers complete in 1-300 s.
WORKER_POLL_INTERVAL_S="${WORKER_POLL_INTERVAL_S:-2}"
WORKER_DEFAULT_TIMEOUT_S="${WORKER_DEFAULT_TIMEOUT_S:-600}"   # 10 min

# Workers that are LOCAL-only (no claude call, no auth required, no token cost).
# These short-circuit the OAuth check.
_local_workers="map consolidate"

# Map worker name → its actual filename under .claude-flow/metrics/.
# (Verified empirically — ruflo doesn't use the worker name as the file name.)
_worker_metrics_basename() {
  case "$1" in
    map)          echo "codebase-map" ;;
    audit)        echo "security-audit" ;;
    optimize)     echo "performance" ;;
    consolidate)  echo "consolidation" ;;
    testgaps)     echo "test-gaps" ;;
    predict)      echo "predictions" ;;
    document)     echo "documentation" ;;
    ultralearn)   echo "ultralearn" ;;
    refactor)     echo "refactor" ;;
    deepdive)     echo "deepdive" ;;
    *)            echo "$1" ;;
  esac
}

# Map worker name → output filename. Most write JSON, some write Markdown.
_worker_output_ext() {
  case "$1" in
    audit|map|predict|ultralearn|consolidate|document|testgaps|optimize) echo "json" ;;
    refactor|deepdive) echo "md" ;;
    *) echo "json" ;;
  esac
}

# Is the worker local (free) or LLM-backed?
_is_local_worker() {
  local w="$1"
  for lw in $_local_workers; do
    [ "$w" = "$lw" ] && return 0
  done
  return 1
}

# Quick check: is the operator able to invoke claude CLI?
# Returns 0 if claude binary is callable, 2 if missing entirely.
# Auth state is NOT verified here (claude uses macOS Keychain on macOS, not a
# file). Real auth failure surfaces from the worker invocation's stderr.
# In CI (CI=true), we require ANTHROPIC_API_KEY since there's no OAuth.
_check_claude_auth() {
  if ! command -v claude >/dev/null 2>&1; then
    return 2
  fi
  if [ -n "${CI:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    return 1
  fi
  return 0
}

# Main entry point.
trigger_worker() {
  local worker="${1:-}"
  local slug="${2:-}"
  local timeout_s="${3:-$WORKER_DEFAULT_TIMEOUT_S}"

  if [ -z "$worker" ] || [ -z "$slug" ]; then
    echo "[worker-trigger] usage: trigger_worker <worker-name> <slug> [timeout_s]" >&2
    return 2
  fi

  # Validate slug format (security: prevent path traversal).
  if ! [[ "$slug" =~ ^[a-z0-9-]{3,64}$ ]]; then
    echo "[worker-trigger] invalid slug format: $slug" >&2
    return 2
  fi

  local sprint_dir="$_repo_root/docs/sprints/$slug"
  if [ ! -d "$sprint_dir" ]; then
    echo "[worker-trigger] sprint dir not found: $sprint_dir" >&2
    return 2
  fi

  local output_dir="$sprint_dir/worker-output"
  mkdir -p "$output_dir"

  local ext
  ext="$(_worker_output_ext "$worker")"
  local out_dest="$output_dir/$worker.$ext"

  # Auth check for LLM-backed workers. Local workers (map, consolidate) skip.
  if ! _is_local_worker "$worker"; then
    _check_claude_auth
    local auth_rc=$?
    if [ "$auth_rc" -eq 2 ]; then
      echo "[worker-trigger] claude CLI not installed — cannot run $worker" >&2
      return 1
    fi
    if [ "$auth_rc" -eq 1 ]; then
      # CI hard-fails per Q8; local degrades gracefully.
      if [ -n "${CI:-}" ]; then
        echo "[worker-trigger] [CI] worker $worker requires local Claude Code OAuth session" >&2
        echo "[worker-trigger] [CI] run sprint-verify locally before pushing" >&2
        return 1
      fi
      echo "[worker-trigger] WARN: claude not authenticated; skipping $worker (run 'claude login' to enable)" >&2
      return 1
    fi
  fi

  # Ensure daemon is running. ruflo daemon start is idempotent.
  if ! ruflo daemon status 2>&1 | grep -q "RUNNING"; then
    echo "[worker-trigger] daemon stopped; starting warm" >&2
    ruflo daemon start --workspace "$_repo_root" >/dev/null 2>&1 || {
      echo "[worker-trigger] failed to start daemon" >&2
      return 1
    }
    sleep 1
  fi

  local metrics_basename
  metrics_basename="$(_worker_metrics_basename "$worker")"
  local metrics_file="$_repo_root/.claude-flow/metrics/$metrics_basename.json"
  local before_mtime=0
  if [ -f "$metrics_file" ]; then
    before_mtime="$(stat -f %m "$metrics_file" 2>/dev/null || stat -c %Y "$metrics_file" 2>/dev/null || echo 0)"
  fi

  echo "[worker-trigger] triggering $worker for $slug (timeout ${timeout_s}s)" >&2
  local trigger_start
  trigger_start=$(date +%s)
  if ! ruflo daemon trigger -w "$worker" >/dev/null 2>&1; then
    echo "[worker-trigger] daemon trigger failed for $worker" >&2
    return 1
  fi

  # Poll the metrics file until mtime changes (worker finished writing).
  local waited=0
  while [ "$waited" -lt "$timeout_s" ]; do
    sleep "$WORKER_POLL_INTERVAL_S"
    waited=$((waited + WORKER_POLL_INTERVAL_S))

    if [ ! -f "$metrics_file" ]; then
      continue
    fi
    local current_mtime
    current_mtime="$(stat -f %m "$metrics_file" 2>/dev/null || stat -c %Y "$metrics_file" 2>/dev/null || echo 0)"
    if [ "$current_mtime" -gt "$before_mtime" ]; then
      # Worker wrote something — verify it's parseable.
      if [ "$ext" = "json" ]; then
        if ! jq empty "$metrics_file" 2>/dev/null; then
          echo "[worker-trigger] $worker output is not valid JSON; failing" >&2
          return 1
        fi
      fi
      cp "$metrics_file" "$out_dest"
      local elapsed=$(($(date +%s) - trigger_start))
      echo "[worker-trigger] ✓ $worker → $out_dest (${elapsed}s)" >&2

      # Record invocation in state.json (best-effort; non-blocking).
      atomic_update_state "$slug" \
        ".worker_invocations = (.worker_invocations // []) + [{worker:\"$worker\", at:\"$(date -u +%FT%TZ)\", elapsed_s:$elapsed, output:\"worker-output/$worker.$ext\"}]" \
        2>/dev/null || true
      return 0
    fi
  done

  echo "[worker-trigger] timeout waiting for $worker after ${timeout_s}s" >&2
  return 1
}

# Helper: trigger multiple workers in parallel, wait for all.
trigger_workers_parallel() {
  local slug="${1:-}"
  shift
  local workers=("$@")
  if [ -z "$slug" ] || [ ${#workers[@]} -eq 0 ]; then
    echo "[worker-trigger] usage: trigger_workers_parallel <slug> <worker1> <worker2> ..." >&2
    return 2
  fi
  local pids=()
  local failed=0
  for w in "${workers[@]}"; do
    trigger_worker "$w" "$slug" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do
    if ! wait "$p"; then
      failed=$((failed + 1))
    fi
  done
  return "$failed"
}
