#!/usr/bin/env bash
# sprint-trajectory-seed.sh — Reconstruct trajectories from past sprints.
#
# Usage:
#   bash scripts/sprint-trajectory-seed.sh [--dry-run]
#   bash scripts/sprint-trajectory-seed.sh --force  # actually insert
#
# Reads closed sprints from docs/sprints/*/state.json and creates trajectory
# records in .swarm/memory.db. Each sprint becomes one trajectory with
# phase transitions as steps.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MEMORY_DB=".swarm/memory.db"
DRY_RUN=true

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) DRY_RUN=false ;;
  esac
done

if [ ! -f "$MEMORY_DB" ]; then
  echo "[!] No .swarm/memory.db found"
  exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  Trajectory Seeding Tool"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Find all done sprints
SPRINT_DIRS=$(find docs/sprints -maxdepth 1 -type d ! -name 'sprints' ! -name '_*' ! -name 'DEVELOPER.md' ! -name 'USAGE.md' ! -name 'QUICKSTART.md' ! -name 'OPENCODE_USAGE.md' ! -name 'SCRIPTS.md' | sort)

COUNT=0
for dir in $SPRINT_DIRS; do
  SLUG=$(basename "$dir")
  STATE_FILE="$dir/state.json"
  
  # Skip if not done or no state.json
  if [ ! -f "$STATE_FILE" ]; then
    continue
  fi
  
  PHASE=$(jq -r '.phase // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
  if [ "$PHASE" != "done" ]; then
    continue
  fi
  
  # Check if trajectory already exists for this sprint
  EXISTING_TRAJ=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM trajectories WHERE task = '$SLUG';" 2>/dev/null || echo 0)
  if [ "$EXISTING_TRAJ" -gt 0 ]; then
    echo "[skip] $SLUG — trajectory already exists"
    continue
  fi
  
  # Extract trajectory data - simpler approach
  STARTED_AT=$(jq -r '.started_at_epoch // 0' "$STATE_FILE" 2>/dev/null)
  ACS_TOTAL=$(jq -r '.acs_total // 0' "$STATE_FILE" 2>/dev/null)
  ACS_CLOSED=$(jq -r '.acs_closed // 0' "$STATE_FILE" 2>/dev/null)
  DRIFT_SCORE=$(jq -r '.drift_score_latest // 0' "$STATE_FILE" 2>/dev/null)
  GATES_COUNT=$(jq -r '.gates_passed | length' "$STATE_FILE" 2>/dev/null || echo 0)
  
  # Fallback for missing values
  STARTED_AT=${STARTED_AT:-0}
  ACS_TOTAL=${ACS_TOTAL:-0}
  ACS_CLOSED=${ACS_CLOSED:-0}
  DRIFT_SCORE=${DRIFT_SCORE:-0}
  GATES_COUNT=${GATES_COUNT:-0}
  
  # Determine verdict
  if [ "$ACS_CLOSED" -eq "$ACS_TOTAL" ] && [ "$ACS_TOTAL" -gt 0 ]; then
    VERDICT="success"
  elif [ "$ACS_CLOSED" -eq 0 ]; then
    VERDICT="failure"
  else
    VERDICT="partial"
  fi
  
  # Build context JSON (escape for SQL)
  CONTEXT="{\"acs_total\":$ACS_TOTAL,\"acs_closed\":$ACS_CLOSED,\"drift_score\":$DRIFT_SCORE,\"gates_count\":$GATES_COUNT}"
  
  # Generate trajectory ID
  TRAJ_ID="traj-reconstructed-$(date +%s)-${SLUG:0:8}"
  TOTAL_STEPS=0
  
  # Count phase transitions (proxy for steps) - use sub_steps or gate count
  SUB_STEPS=$(jq -r '.sub_steps | length' "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$SUB_STEPS" = "null" ] || [ -z "$SUB_STEPS" ] || [ "$SUB_STEPS" -eq 0 ]; then
    # Use gates_passed count or default
    TOTAL_STEPS=${GATES_COUNT:-5}
    if [ "$TOTAL_STEPS" -eq 0 ]; then
      TOTAL_STEPS=5
    fi
  else
    TOTAL_STEPS=$SUB_STEPS
  fi
  
  echo "───────"
  echo "Sprint: $SLUG"
  echo "  Verdict: $VERDICT ($ACS_CLOSED/$ACS_TOTAL ACs)"
  echo "  Steps: ~$TOTAL_STEPS (estimated from phase history)"
  echo "  Context: $CONTEXT"
  
  if [ "$DRY_RUN" = true ]; then
    echo "  → [DRY RUN] Would insert trajectory"
  else
    # Insert trajectory - use test insert first to verify
    INSERT_RESULT=$(sqlite3 "$MEMORY_DB" "
      INSERT INTO trajectories (id, status, verdict, task, context, total_steps, started_at, ended_at)
      VALUES (
        '$TRAJ_ID',
        'completed',
        '$VERDICT',
        '$SLUG',
        '$CONTEXT',
        $TOTAL_STEPS,
        $((STARTED_AT * 1000)),
        $(($(date +%s) * 1000))
      );
    " 2>&1)
    
    if [ -z "$INSERT_RESULT" ]; then
      echo "  → [INSERTED] $TRAJ_ID"
      COUNT=$((COUNT + 1))
    else
      echo "[!] SQL Error: $INSERT_RESULT"
    fi
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$DRY_RUN" = true ]; then
  echo "  DRY RUN complete — run with --force to actually insert"
else
  echo "  Seeding complete — inserted $COUNT trajectories"
fi
echo "═══════════════════════════════════════════════════════════════"

# Show final count
TRAJ_TOTAL=$(sqlite3 "$MEMORY_DB" "SELECT count(*) FROM trajectories;" 2>/dev/null || echo 0)
echo ""
echo "Total trajectories in DB: $TRAJ_TOTAL"
if [ "$TRAJ_TOTAL" -ge 20 ]; then
  echo "✓ Ready for neural training!"
else
  echo "  Need $((20 - TRAJ_TOTAL)) more for neural training"
fi