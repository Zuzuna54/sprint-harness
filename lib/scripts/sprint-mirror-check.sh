#!/usr/bin/env bash
# sprint-mirror-check.sh — AC-13 mirror-parity pre-push check.
#
# Called from .husky/pre-push (AC-6). Fails push if lifeos commits matching
# feat(harness-parallel-safety-v2/AC-N): lack corresponding sprint-harness
# mirror commits (within 24h).
#
# Exit codes:
#   0 = mirror parity OK (all ACs have mirrors)
#   1 = mirror desync — blocked until scripts/sync-mirror.sh runs

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HARNESS_DIR="$HOME/Desktop/sprint-harness"
cd "$REPO_ROOT"

if [ ! -d "$HARNESS_DIR" ]; then
  echo "[sprint-mirror-check] ~/Desktop/sprint-harness/ not found — skipping mirror check" >&2
  exit 0
fi

SINCE="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
  date -u -v-24H +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
  echo '1970-01-01T00:00:00Z')"

AC_COMMITS="$(git log --since="$SINCE" --format='%H %s' --all 2>/dev/null | \
  grep -E 'feat\(harness-parallel-safety-v2/AC-[0-9]+\):' | \
  while IFS=' ' read -r hash msg; do
    echo "$msg" | grep -oE 'AC-[0-9]+' | while read -r ac; do
      echo "$ac $hash"
    done
  done)"

if [ -z "$AC_COMMITS" ]; then
  echo "[sprint-mirror-check] no AC commits in past 24h — nothing to check" >&2
  exit 0
fi

MISSING=""
while IFS=' ' read -r ac hash; do
  [ -z "$ac" ] && continue
  # Look for mirror commit in sprint-harness (same 24h window)
  cd "$HARNESS_DIR" 2>/dev/null || continue
  HARNESS_SINCE="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -v-24H +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
    echo '1970-01-01T00:00:00Z')"
  HAS_MIRROR="$(git log --since="$HARNESS_SINCE" --format='%s' 2>/dev/null | \
    grep -E "$ac" | grep -iE '(port|mirror|backport|port-)' | head -1)"
  cd "$REPO_ROOT" 2>/dev/null
  if [ -z "$HAS_MIRROR" ]; then
    MISSING="${MISSING}${MISSING:+, }$ac"
  fi
done <<< "$AC_COMMITS"

if [ -n "$MISSING" ]; then
  echo "mirror desync; run scripts/sync-mirror.sh first. Missing mirror for: $MISSING" >&2
  exit 1
fi

echo "[sprint-mirror-check] mirror parity OK" >&2
exit 0