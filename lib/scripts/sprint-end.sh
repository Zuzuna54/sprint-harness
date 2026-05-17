#!/usr/bin/env bash
# sprint-end.sh — Phase 8 of the <BRAND_SLUG_TITLE> sprint protocol
#
# Usage:
#   bash scripts/sprint-end.sh <slug> [--skip-patterns] [--skip-claude-md]
#
# Generates retro, extracts patterns to memory, syncs CLAUDE.md, closes Issue,
# closes trajectory, re-enables paused workers, updates state.phase = done.

set -euo pipefail

SLUG="${1:-}"
SKIP_PATTERNS=false
SKIP_CLAUDE_MD=false
STORE_PATTERNS=false   # AC-3: opt-in flag to auto-save retro patterns to ruflo

for arg in "${@:2}"; do
  case "$arg" in
    --skip-patterns)   SKIP_PATTERNS=true ;;
    --skip-claude-md)  SKIP_CLAUDE_MD=true ;;
    --store-patterns)  STORE_PATTERNS=true ;;
    *) echo "[!] unknown arg: $arg" >&2 ;;
  esac
done

if [ -z "$SLUG" ]; then
  echo "Usage: $0 <slug> [--skip-patterns] [--skip-claude-md]" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"
RETRO_FILE="$SPRINT_DIR/retro.md"
METRICS_FILE="$SPRINT_DIR/metrics.json"

if [ ! -d "$SPRINT_DIR" ]; then
  echo "[!] Sprint not found: $SPRINT_DIR" >&2
  exit 1
fi

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NOW_EPOCH="$(date -u +%s)"

# ── Generate retro skeleton ──────────────────────────────────────────────────
if [ ! -f "$RETRO_FILE" ]; then
  cat > "$RETRO_FILE" <<MARK
# Sprint Retro: $SLUG

Closed: $NOW_ISO

## What worked
_(Claude proposes 3-5 items based on session logs; user edits.)_

## What didn't
_(Claude proposes; user edits.)_

## What surprised us
_(Claude proposes; user edits.)_

## Velocity metrics
_(populated from state.json — see metrics.json)_

## Patterns extracted
_(Claude proposes 3-5 reusable patterns; user approves each before \`ruflo memory store\`.)_

## CLAUDE.md updates proposed
_(If any new convention emerged repo-wide, Claude proposes additions here for review.)_

## Open follow-ups for next sprint
- ...

MARK
  echo "[+] Retro skeleton written: $RETRO_FILE"
fi

# ── Compute metrics ──────────────────────────────────────────────────────────
# BUG 8 fix: when grep -o returns empty AND head -1 returns empty AND grep -o
# extracts nothing, the variable is empty. Under `set -e`, $((NOW - "")) then
# errors and the script silently exits. Now: each parser has explicit empty
# fallback to 0 BEFORE arithmetic.

STARTED_EPOCH="$(grep -o '"started_at_epoch":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$' || true)"
[ -z "$STARTED_EPOCH" ] && STARTED_EPOCH="$NOW_EPOCH"  # 0 elapsed if missing

ELAPSED_SEC=$((NOW_EPOCH - STARTED_EPOCH))
ELAPSED_DAYS=$((ELAPSED_SEC / 86400))

GATES="$(grep -o '"gates_passed":[[:space:]]*\[[^]]*\]' "$STATE_FILE" | head -1 || true)"

ACS_TOTAL="$(grep -o '"acs_total":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$' || true)"
[ -z "$ACS_TOTAL" ] && ACS_TOTAL=0

ACS_CLOSED="$(grep -o '"acs_closed":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$' || true)"
[ -z "$ACS_CLOSED" ] && ACS_CLOSED=0

DRIFT_EVENTS_COUNT="$(grep -c '"drift_events":\|"score":' "$STATE_FILE" 2>/dev/null || true)"
[ -z "$DRIFT_EVENTS_COUNT" ] && DRIFT_EVENTS_COUNT=0

PAUSE_EVENTS_COUNT="$(grep -c '"pause_events":\|"at":' "$STATE_FILE" 2>/dev/null || true)"
[ -z "$PAUSE_EVENTS_COUNT" ] && PAUSE_EVENTS_COUNT=0

SCOPE_AMENDS_COUNT="$(grep -c '"scope_amendments":\|"diff":' "$STATE_FILE" 2>/dev/null || true)"
[ -z "$SCOPE_AMENDS_COUNT" ] && SCOPE_AMENDS_COUNT=0

cat > "$METRICS_FILE" <<JSON
{
  "slug": "$SLUG",
  "closed_at": "$NOW_ISO",
  "elapsed_seconds": $ELAPSED_SEC,
  "elapsed_days": $ELAPSED_DAYS,
  "appetite_days": 14,
  "acs_total": $ACS_TOTAL,
  "acs_closed": $ACS_CLOSED,
  "ac_closure_rate": $([ "$ACS_TOTAL" -gt 0 ] && echo "scale=2; $ACS_CLOSED / $ACS_TOTAL" | bc -l 2>/dev/null || echo 0),
  "drift_events_count": $DRIFT_EVENTS_COUNT,
  "pause_events_count": $PAUSE_EVENTS_COUNT,
  "scope_amendments_count": $SCOPE_AMENDS_COUNT,
  "success_criteria": {
    "all_acs_closed": $([ "$ACS_CLOSED" -eq "$ACS_TOTAL" ] && [ "$ACS_TOTAL" -gt 0 ] && echo "true" || echo "false"),
    "within_appetite": $([ "$ELAPSED_DAYS" -le 14 ] && echo "true" || echo "false"),
    "low_drift": $([ "$DRIFT_EVENTS_COUNT" -le 3 ] && echo "true" || echo "false")
  }
}
JSON
echo "[+] Metrics written: $METRICS_FILE"

# ── Update state.phase = done (BUG 4+5 fix) ─────────────────────────────────
# Previous version chained `jq … > tmp && mv tmp file` — if jq exited non-zero
# (e.g., state.json malformed, or a variable interpolated badly), the chain
# silently skipped the mv, leaving phase unchanged. Now: verify jq output
# parses before moving, and ALWAYS run sed as a fallback for phase + closed_at
# so the transition lands even if jq fails.

PHASE_TRANSITION_OK=false

if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  if jq ".phase = \"done\" | .closed_at = \"$NOW_ISO\" | .elapsed_seconds = $ELAPSED_SEC" \
       "$STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if node -e "JSON.parse(require('fs').readFileSync('$tmp'))" 2>/dev/null; then
      mv "$tmp" "$STATE_FILE"
      PHASE_TRANSITION_OK=true
    else
      echo "[!] jq output is not valid JSON — falling back to sed"
      rm -f "$tmp"
    fi
  else
    echo "[!] jq failed or produced empty output — falling back to sed"
    rm -f "$tmp"
  fi
fi

# Fallback: sed (always runs if jq didn't succeed). Mutates in-place via .bak.
if [ "$PHASE_TRANSITION_OK" != "true" ]; then
  sed -i.bak 's/"phase":[[:space:]]*"[^"]*"/"phase": "done"/' "$STATE_FILE"
  # Add closed_at if not present, or update if present
  if grep -q '"closed_at"' "$STATE_FILE"; then
    sed -i.bak "s|\"closed_at\":[[:space:]]*[^,}]*|\"closed_at\": \"$NOW_ISO\"|" "$STATE_FILE"
  else
    sed -i.bak "s|\"phase\": \"done\"|\"phase\": \"done\",\n  \"closed_at\": \"$NOW_ISO\"|" "$STATE_FILE"
  fi
  rm -f "$STATE_FILE.bak"
fi

# Verify the transition actually landed
ACTUAL_PHASE="$(grep -o '"phase":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
ACTUAL_CLOSED="$(grep -o '"closed_at":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
if [ "$ACTUAL_PHASE" = "done" ]; then
  echo "[+] state.phase → done"
  echo "[+] state.closed_at → ${ACTUAL_CLOSED:-(empty)}"
else
  echo "[!] WARNING: state.phase did not transition to 'done' (still: $ACTUAL_PHASE)"
  echo "    Inspect: $STATE_FILE"
fi

# ── Re-enable paused daemon workers ──────────────────────────────────────────
if command -v ruflo >/dev/null 2>&1; then
  ruflo daemon enable -w refactor >/dev/null 2>&1 || true
  ruflo daemon enable -w document >/dev/null 2>&1 || true
  echo "[+] Re-enabled daemon workers: refactor, document"
fi

# ── AC-3 (Bug #21): retro pattern auto-save ──────────────────────────────────
# Parses retro.md "## Patterns extracted" section + runs ruflo memory store
# per pattern. Failures surfaced (not silently dropped).
#   - Default: list mode (safe; Claude/user confirms)
#   - --store-patterns: auto-save (use for non-interactive sprint-end runs)
if [ -f "$RETRO_FILE" ] && [ -x "$REPO_ROOT/scripts/sprint-retro-save-patterns.mjs" ]; then
  if [ "$STORE_PATTERNS" = "true" ]; then
    echo ""
    echo "[+] Retro pattern auto-save (--store-patterns flag set):"
    node "$REPO_ROOT/scripts/sprint-retro-save-patterns.mjs" "$SLUG" --auto-save 2>&1 | sed 's/^/    /'
  else
    echo ""
    echo "[i] Retro patterns detected — preview (use --store-patterns to save):"
    node "$REPO_ROOT/scripts/sprint-retro-save-patterns.mjs" "$SLUG" 2>&1 | sed 's/^/    /' | head -20
  fi
fi

# ── AC-7 (Bug #25): auto-generate dashboard at sprint-end ────────────────────
if [ -x "$REPO_ROOT/scripts/sprint-dashboard.mjs" ]; then
  echo ""
  echo "[+] Auto-generating sprint dashboard..."
  node "$REPO_ROOT/scripts/sprint-dashboard.mjs" "$SLUG" 2>&1 | sed 's/^/    /'
fi

# ── AC-8 (Bug #22): known-gaps memory auto-update prompt ─────────────────────
# Cross-reference resolved bug/AC tokens against the project's known-gaps
# memory files. Default: list mode (user decides). Pass --auto-strike to the
# underlying script for in-place updates (skipped by default — gaps memory
# usually wants human review).
if [ -x "$REPO_ROOT/scripts/sprint-update-known-gaps.mjs" ]; then
  echo ""
  echo "[+] Known-gaps memory check:"
  node "$REPO_ROOT/scripts/sprint-update-known-gaps.mjs" "$SLUG" 2>&1 | sed 's/^/    /'
fi

# ── Close GitHub Issue if present ────────────────────────────────────────────
ISSUE_URL="$(grep -o '"github_issue":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
if [ -n "${ISSUE_URL:-}" ] && [ "$ISSUE_URL" != "null" ] && command -v gh >/dev/null 2>&1; then
  ISSUE_NUM="$(echo "$ISSUE_URL" | grep -oE '[0-9]+$' || true)"
  if [ -n "$ISSUE_NUM" ]; then
    gh issue close "$ISSUE_NUM" --reason completed 2>/dev/null || echo "[i] gh issue close failed (issue may already be closed)"
  fi
fi

# ── AC-33 (sprint-system-100): systems-health close-check (WARN only) ───────
# Run precheck again at sprint-end so retro captures the final state of all
# dependencies. Non-blocking — retro should always complete.
if [ -x "$REPO_ROOT/scripts/sprint-precheck.sh" ]; then
  echo ""
  bash "$REPO_ROOT/scripts/sprint-precheck.sh" "$SLUG" --mode end 2>&1 | sed 's/^/    /' || true
fi

# ── AC-2 (sprint-system-100, Gap E): trajectory close ───────────────────────
# Auto-fire ruflo post-task to close the trajectory started by sprint-start.sh.
# Uses state.json.trajectory_id captured at sprint-start.
TRAJ_ID="$(grep -o '"trajectory_id":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
if [ -n "${TRAJ_ID:-}" ] && [ "$TRAJ_ID" != "null" ] && command -v ruflo >/dev/null 2>&1; then
  SUCCESS_FLAG="true"
  if [ "${ACS_TOTAL:-0}" != "0" ] && [ "${ACS_CLOSED:-0}" != "${ACS_TOTAL:-0}" ]; then
    SUCCESS_FLAG="false"
  fi
  ruflo hooks post-task --task-id "$TRAJ_ID" 2>&1 | head -3 | sed 's/^/    /' || true
  echo "[+] Trajectory closed: $TRAJ_ID (success=$SUCCESS_FLAG)"
else
  echo "[i] No trajectory_id in state.json or ruflo unavailable; skipping trajectory close."
fi

# ── Harness readiness aggregation ────────────────────────────────────────────
# Auto-aggregates proof/AC-N.md files into harness-readiness.md (Production/Broken counts).
# Wires sprint-harness-readiness.mjs into the automatic close flow (was orphan before).
if [ -d "docs/sprints/$SLUG/proof" ] && command -v node >/dev/null 2>&1; then
  if [ -f "scripts/sprint-harness-readiness.mjs" ]; then
    echo ""
    echo "[+] Aggregating proof files → harness-readiness.md..."
    # Capture exit code via PIPESTATUS (pipe-RC trap fix — was `| tail -5 || true`
    # which silently masked the readiness aggregator's actual exit).
    node scripts/sprint-harness-readiness.mjs "$SLUG" 2>&1 | tail -5
    HARNESS_READINESS_RC=${PIPESTATUS[0]}
    if [ "$HARNESS_READINESS_RC" -ne 0 ]; then
      echo "[!] harness-readiness aggregator exit $HARNESS_READINESS_RC — readiness report may be stale"
    fi
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Sprint ended: $SLUG"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Elapsed:    $ELAPSED_DAYS days (appetite: 14)"
echo "  ACs:        $ACS_CLOSED / $ACS_TOTAL closed"
echo "  Drift:      $DRIFT_EVENTS_COUNT events"
echo ""
echo "  Next steps for Claude (the orchestrator):"
echo "    1. Read $RETRO_FILE — fill in worked/didn't/surprised based on session logs"
if [ "$SKIP_PATTERNS" = false ]; then
  echo "    2. Propose 3-5 reusable patterns; store via \`ruflo memory store --vector --upsert\`"
fi
if [ "$SKIP_CLAUDE_MD" = false ]; then
  echo "    3. Propose CLAUDE.md updates if a new convention emerged"
fi
echo "    4. Batch PR feedback to DAA reviewer (\`mcp__claude-flow__daa_agent_adapt\`)"
echo "    5. Close trajectory (\`hooks_intelligence_trajectory-end\`)"
echo "    6. Commit: \`sprint($SLUG): retro + close\`"
echo ""
echo "  If 20+ trajectories accumulated, propose: ruflo neural train --type coordination --epochs 50"
echo ""
