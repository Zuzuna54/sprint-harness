#!/usr/bin/env bash
# sprint-review-rerun.sh — multi-producer rerun (audit + knip + sonar).
#
# W1 (harness-review-resolution-v1, AC-3): supersedes sprint-audit-rerun.sh.
# Re-fires each producer + diffs against per-producer baseline. Tracks
# regression streak per producer; blocks when any producer hits streak ≥ 2.
#
# Usage:
#   bash scripts/sprint-review-rerun.sh                              # all producers
#   bash scripts/sprint-review-rerun.sh --slug <slug>
#   bash scripts/sprint-review-rerun.sh --slug <slug> --producer knip  # single producer
#   bash scripts/sprint-review-rerun.sh --slug <slug> --dry-run        # diff existing
#
# Exit codes: 0 OK, 1 confirmed REGRESSION, 2 caller error.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source scripts/lib/atomic-state.sh
# shellcheck disable=SC1091
source scripts/lib/sub-step.sh
# shellcheck disable=SC1091
source scripts/lib/worker-trigger.sh

SLUG="${SPRINT_SLUG_OVERRIDE:-}"
DRY_RUN=0
ONLY_PRODUCER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --producer) ONLY_PRODUCER="$2"; shift 2 ;;
    *) echo "[review-rerun] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SLUG" ]; then
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi
if [ -z "$SLUG" ] || ! [[ "$SLUG" =~ ^[a-z0-9-]{3,64}$ ]]; then
  echo "[review-rerun] invalid or missing slug: $SLUG" >&2
  exit 2
fi

SPRINT_DIR="docs/sprints/$SLUG"
[ -d "$SPRINT_DIR/worker-output" ] || mkdir -p "$SPRINT_DIR/worker-output"
STATE="$SPRINT_DIR/state.json"

fire_producer() {
  local producer="$1"
  case "$producer" in
    audit)
      env -i HOME="$HOME" PATH="$PATH" SHELL="${SHELL:-/bin/sh}" \
        trigger_worker audit "$SLUG" 600
      ;;
    knip)
      node scripts/sprint-deadcode-delete.mjs --check --json --slug "$SLUG" \
        > "$SPRINT_DIR/worker-output/knip.json" 2>/dev/null || true
      jq empty "$SPRINT_DIR/worker-output/knip.json" 2>/dev/null \
        || echo '{"producer":"knip","schema_version":1,"findings":[]}' > "$SPRINT_DIR/worker-output/knip.json"
      ;;
    sonar)
      node scripts/sprint-sonar-parse.mjs --json --slug "$SLUG" \
        > "$SPRINT_DIR/worker-output/sonar.json" 2>/dev/null || true
      jq empty "$SPRINT_DIR/worker-output/sonar.json" 2>/dev/null \
        || echo '{"producer":"sonar","schema_version":1,"findings":[]}' > "$SPRINT_DIR/worker-output/sonar.json"
      ;;
  esac
}

# Per-producer fingerprint (severity + file + line + producer)
fingerprint() {
  local producer="$1" file="$2"
  [ -f "$file" ] || return 0
  case "$producer" in
    audit)
      jq -r '(.findings.vulnerabilities // .vulnerabilities // [])[] |
             "\(.severity // "?")\t\(.file // "?")\t\(.line // "?")"' "$file" 2>/dev/null | sort -u
      ;;
    knip|sonar)
      jq -r '(.findings // [])[] |
             "\(.severity // "?")\t\(.file // "?")\t\(.line // "?")"' "$file" 2>/dev/null | sort -u
      ;;
  esac
}

overall_regression=0

for producer in audit knip sonar; do
  if [ -n "$ONLY_PRODUCER" ] && [ "$ONLY_PRODUCER" != "$producer" ]; then continue; fi

  BASELINE="$SPRINT_DIR/worker-output/${producer}-baseline.json"
  CURRENT="$SPRINT_DIR/worker-output/${producer}.json"

  if [ ! -f "$BASELINE" ] && [ -f "$CURRENT" ]; then
    cp "$CURRENT" "$BASELINE"
    echo "[review-rerun:$producer] snapshotted baseline" >&2
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    echo "[review-rerun:$producer] re-firing..." >&2
    fire_producer "$producer" || echo "[review-rerun:$producer] fire failed (continuing)" >&2
  fi

  if [ ! -f "$CURRENT" ]; then
    echo "[review-rerun:$producer] no output produced, skipping diff" >&2
    continue
  fi
  if [ ! -f "$BASELINE" ]; then
    echo "[review-rerun:$producer] no baseline (vacuous PASS for first run)" >&2
    continue
  fi

  base_fp=$(fingerprint "$producer" "$BASELINE")
  curr_fp=$(fingerprint "$producer" "$CURRENT")

  fixed=$(comm -23 <(printf '%s\n' "$base_fp") <(printf '%s\n' "$curr_fp") | grep -v '^$' || true)
  regression=$(comm -13 <(printf '%s\n' "$base_fp") <(printf '%s\n' "$curr_fp") | grep -v '^$' || true)
  unchanged=$(comm -12 <(printf '%s\n' "$base_fp") <(printf '%s\n' "$curr_fp") | grep -v '^$' || true)

  fixed_count=$(printf '%s' "$fixed" | grep -c '.' || echo 0)
  regression_count=$(printf '%s' "$regression" | grep -c '.' || echo 0)
  unchanged_count=$(printf '%s' "$unchanged" | grep -c '.' || echo 0)

  echo "[review-rerun:$producer] FIXED:$fixed_count REGRESSION:$regression_count UNCHANGED:$unchanged_count" >&2

  if [ "$regression_count" -gt 0 ]; then
    prior_streak=$(jq -r --arg p "$producer" '.review_rerun_regression_streak[$p] // 0' "$STATE")
    new_streak=$((prior_streak + 1))
    atomic_update_state "$SLUG" --arg p "$producer" --argjson s "$new_streak" \
      '.review_rerun_regression_streak = (.review_rerun_regression_streak // {}) | .review_rerun_regression_streak[$p] = $s' \
      2>/dev/null || true
    if [ "$new_streak" -ge 2 ]; then
      echo "[review-rerun:$producer] ✗ REGRESSION confirmed (streak=$new_streak ≥ 2) — BLOCKING" >&2
      record_sub_step "$SLUG" "review-rerun-regression-blocked-${producer}" fail "$CURRENT" 2>/dev/null || true
      overall_regression=1
    else
      echo "[review-rerun:$producer] regression streak=$new_streak — not blocking yet" >&2
    fi
  else
    atomic_update_state "$SLUG" --arg p "$producer" \
      '.review_rerun_regression_streak = (.review_rerun_regression_streak // {}) | .review_rerun_regression_streak[$p] = 0' \
      2>/dev/null || true
  fi
done

if [ "$overall_regression" -eq 1 ]; then exit 1; fi
echo "[review-rerun] ✓ all producers clean (or first-pass regression)" >&2
exit 0
