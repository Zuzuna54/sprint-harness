#!/usr/bin/env bash
# sprint-daa-feedback.sh — Batch PR review feedback to the DAA reviewer agent.
#
# At sprint-end, collects the sprint's PR review comments + retro feedback,
# packages them as DAA adapt signals, and feeds them to the <BRAND_SLUG>-reviewer
# DAA agent (creating it on first run).
#
# After 10-20 sprints, the DAA reviewer learns your review style and starts
# matching your bar on code review suggestions.
#
# Usage: bash scripts/sprint-daa-feedback.sh [<slug>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
if [ -z "$SLUG" ]; then
  echo "[i] No active sprint — nothing to feed."
  exit 0
fi

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"
RETRO_FILE="$SPRINT_DIR/retro.md"

if ! command -v ruflo >/dev/null 2>&1; then
  echo "[i] ruflo CLI not installed — DAA feedback deferred."
  exit 0
fi

DAA_AGENT_ID="<BRAND_SLUG>-reviewer-v1"

# Check if DAA agent exists
AGENT_EXISTS=false
if ruflo daa list 2>/dev/null | grep -q "$DAA_AGENT_ID"; then
  AGENT_EXISTS=true
fi

if [ "$AGENT_EXISTS" = false ]; then
  echo "[+] Creating DAA reviewer agent: $DAA_AGENT_ID"
  # Best-effort — actual MCP tool is mcp__claude-flow__daa_agent_create
  # but we surface the command for Claude to run
  cat <<EOF
  To create the DAA reviewer agent, ask Claude to run:

    mcp__claude-flow__daa_agent_create {
      agent_id: "$DAA_AGENT_ID",
      type: "reviewer",
      cognitive_pattern: "balanced",
      initial_policy: "Review <BRAND_SLUG_TITLE> code with focus on: RLS gaps, missing Zod, soft-delete enforcement, mobile responsiveness, auth on every route, no console.log in commits."
    }

  Then re-run this script to feed it the first sprint's feedback.
EOF
  exit 0
fi

# Collect feedback signals
echo "[+] Collecting feedback signals for $DAA_AGENT_ID from sprint $SLUG"

# 1. PR review comments (best-effort via gh)
PR_NUMBER=""
if command -v gh >/dev/null 2>&1; then
  PR_NUMBER="$(gh pr list --head "sprint/$SLUG" --json number --jq '.[0].number' 2>/dev/null || true)"
fi

PR_FEEDBACK=""
if [ -n "$PR_NUMBER" ]; then
  PR_FEEDBACK="$(gh pr view $PR_NUMBER --json reviews,comments --jq '.reviews + .comments | .[].body' 2>/dev/null | head -50 || true)"
fi

# 2. Retro feedback
RETRO_FEEDBACK=""
if [ -f "$RETRO_FILE" ]; then
  RETRO_FEEDBACK="$(grep -A 20 "## What didn't" "$RETRO_FILE" 2>/dev/null | head -30 || true)"
fi

# 3. Drift events (signal: reviewer should have caught these earlier)
DRIFT_COUNT=0
if [ -f "$STATE_FILE" ]; then
  DRIFT_COUNT="$(grep -c '"score":' "$STATE_FILE" || echo 0)"
fi

# Combine into a feedback payload
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
FEEDBACK_FILE="$SPRINT_DIR/daa-feedback.json"

cat > "$FEEDBACK_FILE" <<JSON
{
  "agent_id": "$DAA_AGENT_ID",
  "sprint_slug": "$SLUG",
  "fed_at": "$NOW_ISO",
  "signals": {
    "pr_number": "${PR_NUMBER:-null}",
    "pr_feedback_excerpt": $(echo "$PR_FEEDBACK" | head -c 2000 | node -e "
      let raw = '';
      process.stdin.on('data', d => raw += d);
      process.stdin.on('end', () => process.stdout.write(JSON.stringify(raw)));
    "),
    "retro_didnt_work": $(echo "$RETRO_FEEDBACK" | head -c 2000 | node -e "
      let raw = '';
      process.stdin.on('data', d => raw += d);
      process.stdin.on('end', () => process.stdout.write(JSON.stringify(raw)));
    "),
    "drift_event_count": $DRIFT_COUNT
  }
}
JSON

echo "[+] Feedback payload: $FEEDBACK_FILE"

# AC-11 (sprint-system-100, Gap F): queue the adapt call so Claude (or any
# MCP-enabled context) can drain it later. Avoids losing feedback when the
# post-merge hook fires outside a Claude session.
if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq --arg at "$NOW_ISO" --arg agent "$DAA_AGENT_ID" --arg fb "$FEEDBACK_FILE" \
     '.pending_daa_adapts = ((.pending_daa_adapts // []) + [{
       at: $at,
       agent_id: $agent,
       feedback_path: $fb,
       applied: false
     }])' \
     "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  echo "[+] Queued daa adapt in state.pending_daa_adapts (will be drained next Claude session with MCP)"
fi

echo ""
echo "  To apply NOW (Claude with MCP), run:"
echo ""
echo "    mcp__claude-flow__daa_agent_adapt {"
echo "      agent_id: \"$DAA_AGENT_ID\","
echo "      feedback: <contents of $FEEDBACK_FILE>"
echo "    }"
echo ""
echo "  Then mark the queue entry .applied = true in state.json."
echo "  After 10-20 sprints' worth of feedback, the agent will match"
echo "  your reviewer bar on RLS/Zod/soft-delete/auth concerns."
