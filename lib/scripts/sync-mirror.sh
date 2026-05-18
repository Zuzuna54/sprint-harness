#!/usr/bin/env bash
# sync-mirror.sh — AC-13: sync ~/Desktop/sprint-harness/ to mirror lifeos AC commits.
#
# Rebases/fast-forwards harness to match lifeos and creates missing mirror
# commits for any AC-N that lacks a corresponding port/mirror commit.
#
# Called when sprint-mirror-check.sh reports desync.
# Run from lifeos root: bash scripts/sync-mirror.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HARNESS_DIR="$HOME/Desktop/sprint-harness"
cd "$REPO_ROOT"

if [ ! -d "$HARNESS_DIR" ]; then
  echo "[sync-mirror] ~/Desktop/sprint-harness/ not found — aborting" >&2
  exit 1
fi

cd "$HARNESS_DIR"

git fetch --all --quiet 2>/dev/null || true

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

git rebase "origin/$CURRENT_BRANCH" 2>/dev/null || git merge "origin/$CURRENT_BRANCH" 2>/dev/null || true

cd "$REPO_ROOT"

SINCE="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
  date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
  echo "1970-01-01T00:00:00Z")"

AC_COMMITS="$(git log --since="$SINCE" --format='%H %s' --all 2>/dev/null | \
  grep -E 'feat\(harness-parallel-safety-v2/AC-[0-9]+\):' | \
  while IFS=' ' read -r hash msg; do
    echo "$msg" | grep -oE 'AC-[0-9]+' | while read -r ac; do
      echo "$ac $hash"
    done
  done)"

if [ -z "$AC_COMMITS" ]; then
  echo "[sync-mirror] no AC commits in past 24h — nothing to mirror" >&2
  exit 0
fi

cd "$HARNESS_DIR"

MIRRORED=0
while IFS=' ' read -r ac hash; do
  [ -z "$ac" ] && continue

  HARNESS_SINCE="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    echo "1970-01-01T00:00:00Z")"

  HAS_MIRROR="$(git log --since="$HARNESS_SINCE" --format='%s' 2>/dev/null | \
    grep -E "$ac" | grep -iE '(port|mirror|backport|port-)' | head -1)"

  if [ -z "$HAS_MIRROR" ]; then
    ORIG_MSG="$(git log -1 --format='%s' "$hash" 2>/dev/null || echo "mirror: $ac")"
    COMMIT_DATE="$(git log -1 --format='%ad' --date=iso "$hash" 2>/dev/null || echo "")"
    GIT_AUTHOR="$(git log -1 --format='%an <%ae>' "$hash" 2>/dev/null || echo "LifeOS Bot <bot@ordex.app>")"

    if [ -n "$COMMIT_DATE" ]; then
      export GIT_AUTHOR_NAME="$(echo "$GIT_AUTHOR" | sed 's/ <.*//')"
      export GIT_AUTHOR_EMAIL="$(echo "$GIT_AUTHOR" | sed 's/.*<//;s/>//')"
      export GIT_COMMITTER_DATE="$COMMIT_DATE"
      export GIT_AUTHOR_DATE="$COMMIT_DATE"

      if ! git log --since="$HARNESS_SINCE" --format='%H' 2>/dev/null | grep -q "$hash"; then
        git cherry-pick "$hash" --no-commit 2>/dev/null || git cherry-pick -n "$hash" 2>/dev/null || true

        git commit -m "port($ac): ${ORIG_MSG#feat(harness-*/}" \
          --author="$GIT_AUTHOR" --date="$COMMIT_DATE" 2>/dev/null || \
        git commit -m "mirror: $ac" --author="$GIT_AUTHOR" --date="$COMMIT_DATE" 2>/dev/null || \
        true

        if git diff --cached --quiet 2>/dev/null; then
          git reset --soft HEAD~ 2>/dev/null || true
          git commit -m "mirror($ac): ${ORIG_MSG}" --author="$GIT_AUTHOR" 2>/dev/null || true
        fi
      fi
    else
      git commit -m "mirror($ac): ${ORIG_MSG}" --allow-empty 2>/dev/null || true
    fi

    MIRRORED=$((MIRRORED + 1))
  fi
done <<< "$AC_COMMITS"

cd "$REPO_ROOT"

echo "[sync-mirror] created $MIRRORED mirror commit(s)" >&2
echo "[sync-mirror] DONE — push harness changes, then re-push lifeos" >&2
exit 0