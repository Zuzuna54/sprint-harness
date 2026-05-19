#!/usr/bin/env bash
# sprint-start.sh — Phase 0 of the LifeOS sprint protocol
#
# Usage:
#   bash scripts/sprint-start.sh <slug> [--with-branch] [--no-issue]
#
# Creates docs/sprints/<slug>/, initializes state.json.
#
# Branch behavior (2026-05-17 update: default flipped to stay-on-branch):
#   - DEFAULT: stays on current branch. Records current branch in state.git_branch.
#     Multiple sprints can live on the same branch; resolution via --slug or
#     SPRINT_SLUG_OVERRIDE. Single-operator parallel sessions don't churn branches.
#   - --with-branch: creates + checks out sprint/<slug> (legacy behavior).
#   - --no-branch: alias for default (kept for back-compat).
#
# See:
#   docs/sprints/README.md
#   .claude/skills/sprint-orchestrator/SKILL.md
#   /Users/gio/.claude/plans/hazy-gathering-kettle.md

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

# ── Args ─────────────────────────────────────────────────────────────────────
SLUG="${1:-}"
WITH_BRANCH=false           # Default: do NOT switch branches.
NO_ISSUE=false
for arg in "${@:2}"; do
  case "$arg" in
    --with-branch) WITH_BRANCH=true ;;
    --no-branch)   WITH_BRANCH=false ;; # explicit no-op for back-compat
    --no-issue)    NO_ISSUE=true ;;
    *) echo "[!] unknown arg: $arg" >&2 ;;
  esac
done

if [ -z "$SLUG" ]; then
  echo "Usage: $0 <slug> [--with-branch] [--no-issue]" >&2
  echo "" >&2
  echo "Example: $0 supplements-compliance" >&2
  exit 1
fi

# ── Path resolution ──────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"
PARTIAL_FILE="$SPRINT_DIR/spec.partial.json"
TRANSCRIPT_FILE="$SPRINT_DIR/wizard-transcript.md"
HILL_FILE="$SPRINT_DIR/hill-chart.md"
RECALLED_FILE="$SPRINT_DIR/recalled-patterns.json"

# ── Guard: don't clobber existing sprint ─────────────────────────────────────
if [ -d "$SPRINT_DIR" ]; then
  echo "[!] Sprint directory already exists: $SPRINT_DIR" >&2
  echo "    If you want to resume, run: bash scripts/sprint-resume.sh $SLUG" >&2
  echo "    If you want to start over, delete the directory first." >&2
  exit 1
fi

# Day 0 — fire `map` worker (local, free) so the wizard's codebase grep sees
# fresh structure. graphify-rebuild stays as fallback.
# Plan: ruflo workers → sprint-harness on-demand (Q1 + table row "Day 0 — start").
if [ "${SPRINT_SKIP_GRAPHIFY:-0}" != "1" ]; then
  if [ -f "$(dirname "$0")/lib/worker-trigger.sh" ]; then
    # shellcheck disable=SC1091
    source "$(dirname "$0")/lib/worker-trigger.sh"
    trigger_worker map "$SLUG" 30 >/dev/null 2>&1 || true
  fi
  # Fallback: graphify-rebuild only if stale (>4h old)
  if command -v pnpm >/dev/null 2>&1; then
    GRAPH_REPORT="graphify-out/GRAPH_REPORT.md"
    NEED_REBUILD=1
    if [ -f "$GRAPH_REPORT" ]; then
      GRAPH_AGE=$(( $(date +%s) - $(stat -f %m "$GRAPH_REPORT" 2>/dev/null || stat -c %Y "$GRAPH_REPORT" 2>/dev/null || echo 0) ))
      if [ "$GRAPH_AGE" -lt 14400 ]; then
        NEED_REBUILD=0
        echo "[i] graphify-out fresh ($((GRAPH_AGE / 60))m old) — skipping rebuild"
      fi
    fi
    if [ "$NEED_REBUILD" -eq 1 ]; then
      echo "[i] Rebuilding graphify-out for fresh codebase context..."
      pnpm graphify:rebuild >/dev/null 2>&1 || echo "    (graphify rebuild failed; continuing)"
    fi
  fi
else
  # AC-10 (harness-portability-v2): log bypass to state.gate_bypasses[]
  # State file may not exist yet (pre-sprint-init); skip if so.
  if [ "${SPRINT_SKIP_GRAPHIFY:-0}" = "1" ] && [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
    atomic_update_state "$SLUG" --arg at "$(date -u +%FT%TZ)" '.gate_bypasses = ((.gate_bypasses // []) + [{gate:"graphify-rebuild", at:$at, reason:"SPRINT_SKIP_GRAPHIFY=1"}])'
  fi
fi

# ── Guard: parallel sprints allowed; only block if THIS slug already exists ──
# 2026-05-17 update: removed the "one sprint at a time" hard block. Multiple
# concurrent sprints in the same workdir are supported via --slug / SPRINT_SLUG_OVERRIDE
# resolution. The only remaining guard: don't re-start a sprint that already
# exists on disk (use --slug-only resume instead).
if [ -d "$SPRINT_DIR" ] && [ -f "$SPRINT_DIR/state.json" ]; then
  EXISTING_PHASE=$(grep -o '"phase":[[:space:]]*"[^"]*"' "$SPRINT_DIR/state.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  if [ "$EXISTING_PHASE" != "done" ]; then
    echo "[!] Sprint '$SLUG' already exists (phase=$EXISTING_PHASE)." >&2
    echo "    To resume:  bash scripts/sprint-status.sh --slug $SLUG" >&2
    echo "    To close:   bash scripts/sprint-end.sh $SLUG" >&2
    echo "    To restart: rm -rf $SPRINT_DIR && bash $0 $SLUG" >&2
    exit 1
  fi
fi

# Informational: list other active sprints (no block, just FYI)
OTHER_ACTIVE="$(bash scripts/sprint-status.sh --list 2>/dev/null | grep -v "^\s*$SLUG\b" | head -3 || true)"
if [ -n "$OTHER_ACTIVE" ]; then
  echo "[i] Other in-flight sprints (resolvable via --slug or SPRINT_SLUG_OVERRIDE):"
  echo "$OTHER_ACTIVE"
  echo ""
fi

# ── Create sprint directory + initial state ──────────────────────────────────
mkdir -p "$SPRINT_DIR"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NOW_EPOCH="$(date -u +%s)"

cat > "$STATE_FILE" <<JSON
{
  "slug": "$SLUG",
  "phase": "spec-wizard",
  "started_at": "$NOW_ISO",
  "started_at_epoch": $NOW_EPOCH,
  "day": 0,
  "appetite_days": 14,
  "appetite_seconds": $((14 * 86400)),
  "gates_passed": [],
  "acs_total": 0,
  "acs_closed": 0,
  "acs_in_progress": [],
  "drift_score_latest": null,
  "drift_events": [],
  "pause_events": [],
  "scope_amendments": [],
  "files_touched": [],
  "autopilot_log": [],
  "wizard_state": {
    "current_section": "A",
    "sections_status": {
      "A": "pending", "B": "pending", "C": "pending", "D": "pending", "E": "pending",
      "F": "pending", "G": "pending", "H": "pending", "I": "pending", "J": "pending"
    }
  },
  "git_branch": null,
  "github_issue": null
}
JSON

cat > "$PARTIAL_FILE" <<JSON
{
  "slug": "$SLUG",
  "started_at": "$NOW_ISO",
  "current_section": "A",
  "sections_status": {
    "A": "pending", "B": "pending", "C": "pending", "D": "pending", "E": "pending",
    "F": "pending", "G": "pending", "H": "pending", "I": "pending", "J": "pending"
  },
  "sections_answers": {},
  "recalled_patterns": [],
  "codebase_refs": [],
  "coherence_checks": [],
  "skip_reasons": {}
}
JSON

cat > "$TRANSCRIPT_FILE" <<MARK
# Wizard Transcript: $SLUG

Started: $NOW_ISO

This file logs every question and answer during the adaptive spec wizard. Preserved for retro and DAA reviewer feedback.

---

MARK

cat > "$HILL_FILE" <<MARK
# Hill Chart: $SLUG

Started: $NOW_ISO

\`\`\`
                                Uphill          Top           Downhill
   Figuring out  ────────────────────●─────────────────────────────────  Making it happen
\`\`\`

> No ACs yet — hill chart will be populated after spec lock.

---

## Scopes

_(populated after §I of wizard completes — one dot per AC)_

MARK

echo '[]' > "$RECALLED_FILE"

# ── Git branch ───────────────────────────────────────────────────────────────
if [ "$WITH_BRANCH" = true ]; then
  # Legacy mode: create + check out sprint/<slug>
  BRANCH="sprint/$SLUG"
  if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    echo "[i] Branch $BRANCH already exists; checking it out"
    git checkout "$BRANCH" >/dev/null 2>&1
  else
    git checkout -b "$BRANCH" >/dev/null 2>&1
    echo "[+] Created branch: $BRANCH"
  fi
  if command -v jq >/dev/null 2>&1; then
    atomic_update_state "$SLUG" ".git_branch = \"$BRANCH\""
  fi
else
  # Default: stay on current branch. Record it in state for reference; multi-sprint
  # resolution uses --slug or SPRINT_SLUG_OVERRIDE rather than branch matching.
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
  echo "[i] Staying on current branch: ${CURRENT_BRANCH:-?} (use --with-branch for legacy sprint/<slug> mode)"
  if command -v jq >/dev/null 2>&1 && [ -n "$CURRENT_BRANCH" ]; then
    atomic_update_state "$SLUG" --arg b "$CURRENT_BRANCH" '.git_branch = $b'
  fi
fi

# ── GitHub Issue (best-effort) ───────────────────────────────────────────────
# BUG 7 fix: previously the script just tried `gh issue create --label sprint`
# and emitted "failed (likely missing 'sprint' label)" without trying to create
# the label. Now: ensure the label exists first (auto-create with a sensible
# color/description); then create the issue. If still fails, fall back to
# creating without the label rather than surfacing a confusing error.
if [ "$NO_ISSUE" = false ] && command -v gh >/dev/null 2>&1; then
  if gh repo view >/dev/null 2>&1; then
    # Ensure 'sprint' label exists (idempotent)
    if ! gh label list --limit 200 --json name -q '.[].name' 2>/dev/null | grep -qx "sprint"; then
      gh label create "sprint" --color "0E8A16" \
        --description "Sprint tracking issue (LifeOS sprint system)" 2>/dev/null || \
        echo "[i] Could not auto-create 'sprint' label (insufficient perms?); will try without it."
    fi

    ISSUE_TITLE="Sprint: $SLUG"
    ISSUE_BODY=$(cat <<EOF
**Sprint slug:** \`$SLUG\`
**Started:** $NOW_ISO
**Appetite:** 14 days (Shape Up + SPARC hybrid)
**Branch:** sprint/$SLUG

Spec: \`docs/sprints/$SLUG/spec.md\` (populated after wizard)

State: \`docs/sprints/$SLUG/state.json\`

_This issue tracks the sprint. Sub-tasks per AC will be added after spec lock._
EOF
)
    # Try with label first; fall back to no label if it still fails
    ISSUE_URL="$(gh issue create --title "$ISSUE_TITLE" --body "$ISSUE_BODY" --label "sprint" 2>/dev/null || true)"
    if [ -z "$ISSUE_URL" ]; then
      ISSUE_URL="$(gh issue create --title "$ISSUE_TITLE" --body "$ISSUE_BODY" 2>/dev/null || true)"
    fi

    if [ -n "$ISSUE_URL" ]; then
      echo "[+] Created GitHub Issue: $ISSUE_URL"
      if command -v jq >/dev/null 2>&1; then
        atomic_update_state "$SLUG" ".github_issue = \"$ISSUE_URL\""
      fi
    else
      echo "[i] Could not create GitHub Issue (no permissions or no remote)."
      echo "    Sprint continues; local state.json is the source of truth."
    fi
  else
    echo "[i] No GitHub repo detected; skipping issue creation."
  fi
fi

# ── AC-33 (sprint-system-100): systems-health precheck (BLOCKING) ───────────
# Before any sprint state is captured, verify daemon + MCP + memory.db are
# healthy. Block sprint creation if critical components down (override with
# SPRINT_PRECHECK_BYPASS=1).
if [ -x "$REPO_ROOT/scripts/sprint-precheck.sh" ]; then
  echo ""
  if ! bash "$REPO_ROOT/scripts/sprint-precheck.sh" "$SLUG" --mode start --strict; then
    echo ""
    echo "[!] Sprint precheck failed. Fix the components above OR run with SPRINT_PRECHECK_BYPASS=1."
    [ "${SPRINT_PRECHECK_BYPASS:-0}" != "1" ] && exit 1
    echo "[i] SPRINT_PRECHECK_BYPASS=1 — continuing despite warnings."
  fi
fi

# ── AC-2 (sprint-system-100, Gap E): trajectory start ───────────────────────
# Auto-fire ruflo trajectory tracking so ReasoningBank accumulates per-sprint
# learning. Captures task-id into state.json.trajectory_id for matching close.
# Graceful fail if daemon down — sprint should not block on this.
if command -v ruflo >/dev/null 2>&1; then
  TRAJ_OUT="$(ruflo hooks pre-task --description "sprint:$SLUG" 2>&1 || true)"
  TRAJ_ID="$(echo "$TRAJ_OUT" | grep -oE 'task-[a-zA-Z0-9]+' | head -1 || true)"
  if [ -n "$TRAJ_ID" ] && command -v jq >/dev/null 2>&1; then
    atomic_update_state "$SLUG" --arg id "$TRAJ_ID" '.trajectory_id = $id'
    echo "[+] Trajectory started: $TRAJ_ID"
  else
    echo "[i] Trajectory start failed (daemon down or no task-id); sprint continues."
  fi
fi

# ── Session-file (AC-1, harness-parallel-safety-v2) ─────────────────────────
# Write the slug to ~/.claude/sessions/<session>/sprint-slug so the hook can
# resolve the active sprint without mtime fallback.
if [ -f "$(dirname "$0")/lib/session-file.sh" ]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/lib/session-file.sh"
  write_session_file "$SLUG"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Sprint started: $SLUG"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Sprint dir: $SPRINT_DIR/"
echo "  State:      $STATE_FILE"
echo "  Branch:     ${BRANCH:-(none)}"
echo ""
echo "  Next step: Claude will now invoke the sprint-spec-wizard skill."
echo "  The wizard runs through 10 discovery sections (A-J) adaptively."
echo "  Estimated time: 20-40 minutes."
echo ""
echo "  Ask Claude: \"start the spec wizard\" or \"continue with §A\"."
echo ""
