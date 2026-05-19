#!/usr/bin/env bash
# sprint-build-launch.sh — Phase 3 kickoff. Triggers lifeos-sprint-build workflow.
#
# Pre-condition: state.phase == design-locked
# Post-condition: state.phase == building; 8-agent swarm + 3 autopilot side-cars running
#
# Usage: bash scripts/sprint-build-launch.sh [<slug>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint." >&2
  exit 1
fi

SPRINT_DIR="docs/sprints/$SLUG"
SPEC_FILE="$SPRINT_DIR/spec.md"
STATE_FILE="$SPRINT_DIR/state.json"
WORKFLOW="docs/workflows/lifeos-sprint-build.yaml"

[ -f "$SPEC_FILE" ] || { echo "[!] spec.md missing: $SPEC_FILE" >&2; exit 1; }
[ -f "$WORKFLOW" ]  || { echo "[!] workflow missing: $WORKFLOW" >&2; exit 1; }

PHASE="$(grep -o '"phase":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
if [ "$PHASE" != "design-locked" ]; then
  echo "[!] Expected phase=design-locked, got phase=$PHASE" >&2
  echo "    Complete the SPARC design phase first." >&2
  exit 1
fi

# Try ruflo workflow execute; fall back to printing instructions if not available
if command -v ruflo >/dev/null 2>&1 && ruflo workflow --help 2>&1 | grep -q execute; then
  echo "[+] Executing lifeos-sprint-build workflow"
  ruflo workflow execute --file "$WORKFLOW" \
    --input spec="$SPEC_FILE" \
    --input slug="$SLUG"
else
  echo ""
  echo "[i] ruflo workflow CLI not available — orchestrator skill takes over."
  echo ""
  echo "    Tell Claude:"
  echo "      'execute lifeos-sprint-build for $SLUG'"
  echo ""
  echo "    Claude will follow $WORKFLOW step-by-step:"
  echo "      1. mcp__claude-flow__swarm_init (hierarchical-mesh, 8 agents)"
  echo "      2. mcp__claude-flow__claims_claim × 7 domains"
  echo "      3. mcp__claude-flow__autopilot_enable × 3 side-cars"
  echo "      4. mcp__claude-flow__hooks_intelligence_trajectory-start"
  echo "      5. Begin per-AC execution per spec §I"
  echo ""
  echo "    Worker integration (plan: Q4):"
  echo "      At each wave kickoff, run: bash scripts/sprint-wave-start.sh <wave-name>"
  echo "      → fires predict (haiku) → docs/sprints/$SLUG/worker-output/predict.json"
  echo ""

  # Best-effort: just update the state to building so per-AC loop can start
atomic_update_state "$SLUG" '.phase = "building"'
fi
