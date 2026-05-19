#!/usr/bin/env bash
# run-workflow.sh — Minimal YAML workflow runner.
#
# Ruflo's `workflow run -f <yaml>` doesn't decompose our `steps:` array
# (upstream issue #1916). This shim reads our YAML format and executes each
# step's `cmd:` sequentially, honoring `on_failure: pause` semantics.
#
# Usage:
#   bash scripts/run-workflow.sh <yaml> [slug=<slug>] [spec=<path>]
#
# Variables ${slug} and ${spec} in cmd: blocks are substituted from kv args.
#
# Exit 0 = all steps passed.  Non-zero = step failed (on_failure: pause).
set -uo pipefail

WF="${1:?workflow yaml path required}"
shift || true
[ -f "$WF" ] || { echo "[!] not found: $WF" >&2; exit 2; }

# kv args — kept in two parallel arrays (bash 3.2 compatible, no `declare -A`)
VAR_KEYS=()
VAR_VALS=()
for kv in "$@"; do
  VAR_KEYS+=("${kv%%=*}")
  VAR_VALS+=("${kv#*=}")
done

substitute() {
  local s="$1"
  local n=${#VAR_KEYS[@]}
  local prev=""
  # harness-full-coverage retro #9 — fixed-point loop so nested vars
  # resolve: if `state_file=docs/sprints/${slug}/state.json` and a step
  # references `${state_file}`, the first pass leaves `${slug}` in the
  # output. Re-run until stable (max 8 iterations as a safety cap).
  local pass=0
  while [ "$s" != "$prev" ] && [ $pass -lt 8 ]; do
    prev="$s"
    local i=0
    while [ $i -lt $n ]; do
      s="${s//\$\{${VAR_KEYS[$i]}\}/${VAR_VALS[$i]}}"
      i=$((i+1))
    done
    pass=$((pass+1))
  done
  echo "$s"
}

# Extract steps using yq if available; else simple awk.
if command -v yq >/dev/null 2>&1; then
  STEP_COUNT=$(yq '.steps | length' "$WF")
else
  # Crude awk parser: looks for `- id: <name>` and `cmd: ...` (single-line or `|` block).
  STEP_COUNT=$(grep -cE "^  - id: " "$WF")
fi

echo "═══ $(basename "$WF") — $STEP_COUNT step(s) ═══"
i=0
FAILED=0
while [ $i -lt "$STEP_COUNT" ]; do
  if command -v yq >/dev/null 2>&1; then
    ID=$(yq ".steps[$i].id // \"step-$i\"" "$WF")
    CMD=$(yq ".steps[$i].cmd // \"\"" "$WF")
    ON_FAIL=$(yq ".steps[$i].on_failure // \"continue\"" "$WF")
  else
    # awk extractor (best-effort, sufficient for our YAML style)
    ID=$(awk -v idx=$i '/^  - id: / { c++; if (c-1==idx) { sub(/^  - id: /, ""); print; exit } }' "$WF")
    CMD=$(awk -v idx=$i '
      /^  - id: / { c++ }
      c-1==idx && /^    cmd:/ {
        sub(/^    cmd: ?/, "")
        if ($0 ~ /^\|/) { collecting=1; next }
        print; exit
      }
      collecting && /^    [a-z]+:/ { exit }
      collecting && /^[^ ]/ { exit }
      collecting { sub(/^      /, ""); print }
    ' "$WF")
    ON_FAIL=$(awk -v idx=$i '
      /^  - id: / { c++ }
      c-1==idx && /^    on_failure:/ { sub(/^    on_failure: ?/, ""); print; exit }
    ' "$WF")
    STEP_TYPE=$(awk -v idx=$i '
      /^  - id: / { c++ }
      c-1==idx && /^    type:/ { sub(/^    type: ?/, ""); print; exit }
    ' "$WF")
    SKILL_NAME=$(awk -v idx=$i '
      /^  - id: / { c++ }
      c-1==idx && /^    skill:/ { sub(/^    skill: ?/, ""); print; exit }
    ' "$WF")
    TOOL_NAME=$(awk -v idx=$i '
      /^  - id: / { c++ }
      c-1==idx && /^    tool:/ { sub(/^    tool: ?/, ""); print; exit }
    ' "$WF")
  fi

  echo "── step $((i+1))/$STEP_COUNT: $ID"

  # Dispatch by step type: cmd, skill, or mcp
  STEP_OK=1
  if [ -n "$CMD" ]; then
    CMD=$(substitute "$CMD")
    bash -c "$CMD" || STEP_OK=0
  elif [ "$STEP_TYPE" = "skill" ] && [ -n "$SKILL_NAME" ]; then
    # Skill steps require Claude in the loop. Log a marker and continue.
    echo "  [type:skill] would invoke /$SKILL_NAME — requires Claude session."
    SLUG_FOR_LOG="${VAR_VALS[0]:-current}"
    [ "${VAR_KEYS[0]:-}" = "slug" ] && SLUG_FOR_LOG="${VAR_VALS[0]}"
    LOG_DIR="docs/sprints/$SLUG_FOR_LOG"
    [ -d "$LOG_DIR" ] && echo "  [marker] $(date -u +%FT%TZ) skill=$SKILL_NAME step=$ID workflow=$(basename "$WF")" >> "$LOG_DIR/workflow-pending-skills.log" || true
  elif [ "$STEP_TYPE" = "mcp" ] && [ -n "$TOOL_NAME" ]; then
    # Translate MCP tool to ruflo CLI equivalent
    case "$TOOL_NAME" in
      mcp__claude-flow__swarm_init)
        ruflo swarm init --topology hierarchical-mesh --max-agents 8 2>&1 | tail -3 || STEP_OK=0 ;;
      mcp__claude-flow__claims_claim)
        echo "  [type:mcp] claims_claim — Claude-side via MCP (no CLI equivalent yet)" ;;
      mcp__claude-flow__performance_profile)
        ruflo performance profile -t cpu -d 5 2>&1 | tail -5 || STEP_OK=0 ;;
      mcp__claude-flow__aidefence_scan)
        # Skip aidefence_scan (CLI uses 'security defend' which needs a target file)
        echo "  [type:mcp] aidefence_scan — Claude-side via MCP" ;;
      mcp__claude-flow__hooks_intelligence_trajectory-start)
        ruflo hooks pre-task --task-id "sprint-$(date +%s)" --description "workflow-runner step: $ID" 2>&1 | tail -3 || true ;;
      mcp__claude-flow__hooks_intelligence_trajectory-end)
        ruflo hooks post-task --task-id "sprint-$(date +%s)" 2>&1 | tail -3 || true ;;
      mcp__claude-flow__agentdb_consolidate)
        echo "  [type:mcp] agentdb_consolidate — Claude-side via MCP" ;;
      mcp__claude-flow__autopilot_enable)
        ruflo autopilot enable 2>&1 | tail -3 || true ;;
      mcp__claude-flow__hive-mind_broadcast)
        echo "  [type:mcp] hive-mind_broadcast — Claude-side via MCP" ;;
      *)
        echo "  [type:mcp] $TOOL_NAME — unmapped, requires Claude" ;;
    esac
  else
    # No cmd, no recognized type — skip silently (might be a phase-transition stub)
    i=$((i+1)); continue
  fi

  if [ $STEP_OK -eq 0 ]; then
    echo "✗ step '$ID' failed."
    if [ "$ON_FAIL" = "pause" ]; then
      echo "  on_failure=pause → halting workflow."
      FAILED=1
      break
    fi
  fi
  i=$((i+1))
done

[ $FAILED -eq 0 ] && echo "✓ workflow completed" || echo "✗ workflow halted"
exit $FAILED
