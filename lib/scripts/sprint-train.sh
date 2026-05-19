#!/usr/bin/env bash
# sprint-train.sh — Gated neural training trigger.
#
# Counts accumulated trajectories in .swarm/memory.db. If ≥20, proposes
# (does not auto-run) `ruflo neural train -p coordination -e 50`.
# Below 20, prints a "deferred" message with current count.
#
# Usage: bash scripts/sprint-train.sh [--force]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
  esac
done

MEMORY_DB=".swarm/memory.db"

if [ ! -f "$MEMORY_DB" ]; then
  echo "[i] No .swarm/memory.db yet — neural training deferred."
  exit 0
fi

TRAJECTORY_COUNT="$(sqlite3 "$MEMORY_DB" "SELECT count(*) FROM trajectories" 2>/dev/null || echo 0)"
PATTERN_COUNT="$(sqlite3 "$MEMORY_DB" "SELECT count(*) FROM memory_entries WHERE namespace IN ('patterns', 'procedures', 'causal')" 2>/dev/null || echo 0)"

echo "Neural training readiness:"
echo "  Trajectories: $TRAJECTORY_COUNT (need ≥20)"
echo "  Patterns:     $PATTERN_COUNT (need ≥20)"
echo ""

THRESHOLD=20
TRAJ_OK=$([ "$TRAJECTORY_COUNT" -ge "$THRESHOLD" ] && echo "true" || echo "false")
PAT_OK=$([ "$PATTERN_COUNT" -ge "$THRESHOLD" ] && echo "true" || echo "false")

if [ "$FORCE" = false ] && [ "$TRAJ_OK" = "false" ]; then
  echo "[i] Trajectories below threshold ($TRAJECTORY_COUNT < $THRESHOLD)."
  echo "    Neural training deferred. Run more sprints to accumulate trajectories."
  echo "    Each sprint = 1 trajectory (opened at build phase, closed at retro)."
  exit 0
fi

if ! command -v ruflo >/dev/null 2>&1; then
  echo "[!] ruflo CLI not installed — cannot train."
  exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  Neural training conditions met — proposing training run"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Recommended command:"
echo ""
echo "    ruflo neural train -p coordination -e 50 --learning-rate 0.001"
echo ""
echo "  Expected duration: 5-15 minutes."
echo "  Effect: 3-tier routing improves on LifeOS-specific patterns."
echo ""
echo "  After training:"
echo "    ruflo neural status"
echo "    ruflo neural patterns"
echo ""

if [ "$FORCE" = true ]; then
  echo "  --force flag set — running now..."
  echo ""
  ruflo neural train -p coordination -e 50 --learning-rate 0.001 || {
    echo "[!] neural train failed; check ruflo daemon status"
    exit 1
  }
else
  echo "  To run now: bash scripts/sprint-train.sh --force"
  echo "  Or wait for the next user-initiated training cycle."
fi
