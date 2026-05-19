#!/usr/bin/env bash
# sprint-wave-start.sh — fire `predict` worker at the start of each build wave.
#
# Per Q4: predict fires once per wave at wave-launch. Output ($docs/sprints/
# <slug>/worker-output/predict.json) suggests files/tests/docs the agents should
# preload for this wave's context. Advisory only — never blocks.
#
# Called from inside lifeos-sprint-build.yaml workflow OR manually by operator
# when starting a new wave (e.g. `bash scripts/sprint-wave-start.sh wave-2`).
#
# Usage:
#   bash scripts/sprint-wave-start.sh <wave-name> [--slug <slug>]
#
# Exit codes:
#   0 — predict ran (output captured) or skipped gracefully (auth missing locally)
#   1 — daemon down, trigger failed
#   2 — caller error

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source scripts/lib/worker-trigger.sh

WAVE="${1:-}"
SLUG="${SPRINT_SLUG_OVERRIDE:-}"
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    *) echo "[sprint-wave-start] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$WAVE" ]; then
  echo "Usage: $0 <wave-name> [--slug <slug>]" >&2
  exit 2
fi

if [ -z "$SLUG" ] && [ -f scripts/lib/session-file.sh ]; then
  # shellcheck disable=SC1091
  source scripts/lib/session-file.sh
  SLUG="$(read_session_file 2>/dev/null || true)"
fi
if [ -z "$SLUG" ]; then
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi
if [ -z "$SLUG" ]; then
  echo "[sprint-wave-start] no active sprint" >&2
  exit 2
fi

echo "[sprint-wave-start] wave=$WAVE slug=$SLUG"

# Trigger predict. Fails-gracefully if not authenticated locally (logs WARN).
# 60s timeout — predict is a haiku call, typically completes in 20-30s.
if trigger_worker predict "$SLUG" 60; then
  echo "[sprint-wave-start] ✓ predict output → docs/sprints/$SLUG/worker-output/predict.json"
else
  echo "[sprint-wave-start] ⊘ predict skipped (advisory; wave continues)" >&2
fi
exit 0
