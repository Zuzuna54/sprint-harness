#!/usr/bin/env bash
# sprint-drift-check.sh — Husky pre-commit hook: compute drift score for THIS commit.
#
# Runs on every commit when a sprint is active. Embeds the commit message + diff
# summary, computes cosine similarity against the spec's baseline embedding, and:
#   - score ≥ 0.75 → log + proceed
#   - score <  0.75 → pause, prompt user via stderr with 3 options
#
# Setup: husky/pre-commit calls this when active sprint exists.
#
# Env overrides:
#   SPRINT_DRIFT_THRESHOLD (default 0.75)
#   SPRINT_DRIFT_BYPASS=1  (skip the check entirely — emergency escape hatch)
#
# Exit codes:
#   0 = OK to proceed
#   1 = user blocked (commit aborted)
#   2 = configuration error (script can't proceed; commit allowed to avoid deadlock)
#
# See: .claude/skills/sprint-orchestrator/SKILL.md "Drift control responsibilities"
#      /Users/gio/.claude/plans/hazy-gathering-kettle.md "Drift score mechanics"

set -uo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

# ── Emergency bypass ─────────────────────────────────────────────────────────
if [ "${SPRINT_DRIFT_BYPASS:-}" = "1" ]; then
  echo "[sprint-drift-check] BYPASS=1 — skipping drift check (logging to state.gate_bypasses[])" >&2
  REPO_ROOT_LOG="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  ACTIVE_SLUG=$(bash "$REPO_ROOT_LOG/scripts/sprint-status.sh" --slug-only 2>/dev/null || true)
  if [ -n "$ACTIVE_SLUG" ] && command -v jq >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT_LOG/scripts/lib/atomic-state.sh"
    atomic_update_state "$ACTIVE_SLUG" --arg at "$(date -u +%FT%TZ)" '.gate_bypasses = ((.gate_bypasses // []) + [{gate:"drift-check", at:$at, reason:"SPRINT_DRIFT_BYPASS=1"}])'
  fi
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# ── Resolve active sprint via resolution chain ────────────────────────────────
# AC-8: must use the session's sprint (not most-recent-mtime fallback).
# Resolution order (matches sprint-hook.cjs + sprint-status.sh):
#   1. SPRINT_SLUG_OVERRIDE env var
#   2. Session-file: ~/.claude/sessions/<CLAUDE_SESSION_ID>/sprint-slug
#      (clean stale entries that point to phase=done sprints)
#   3. Current git branch sprint/<slug>
#   4. NO mtime fallback — exit 0 with "no active sprint" (AC-11 behavior)

SLUG=""

# 1. SPRINT_SLUG_OVERRIDE
if [ -z "$SLUG" ] && [ -n "${SPRINT_SLUG_OVERRIDE:-}" ]; then
  if [[ "$SPRINT_SLUG_OVERRIDE" =~ ^[a-z0-9-]{3,64}$ ]]; then
    if [ -f "docs/sprints/$SPRINT_SLUG_OVERRIDE/state.json" ]; then
      SLUG="$SPRINT_SLUG_OVERRIDE"
    fi
  fi
fi

# 2. Session-file (clean stale done-phase entries)
if [ -z "$SLUG" ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SESSION_FILE="$HOME/.claude/sessions/$CLAUDE_SESSION_ID/sprint-slug"
  if [ -f "$SESSION_FILE" ]; then
    CANDIDATE="$(cat "$SESSION_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$CANDIDATE" =~ ^[a-z0-9-]{3,64}$ ]]; then
      PHASE="$(grep -o '"phase":[[:space:]]*"[^"]*"' "docs/sprints/$CANDIDATE/state.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
      if [ "$PHASE" = "done" ] || [ "$PHASE" = "paused" ]; then
        rm -f "$SESSION_FILE"
      elif [ -f "docs/sprints/$CANDIDATE/state.json" ]; then
        SLUG="$CANDIDATE"
      fi
    else
      rm -f "$SESSION_FILE"
    fi
  fi
fi

# 3. Current git branch sprint/<slug>
if [ -z "$SLUG" ]; then
  BRANCH_NOW="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [[ "$BRANCH_NOW" =~ ^sprint/(.+)$ ]]; then
    CANDIDATE="${BASH_REMATCH[1]}"
    if [ -f "docs/sprints/$CANDIDATE/state.json" ]; then
      PHASE="$(grep -o '"phase":[[:space:]]*"[^"]*"' "docs/sprints/$CANDIDATE/state.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
      if [ "$PHASE" != "done" ] && [ "$PHASE" != "paused" ]; then
        SLUG="$CANDIDATE"
      fi
    fi
  fi
fi

# 4. No slug resolved → AC-11 behavior: exit 0 silently
if [ -z "$SLUG" ]; then
  exit 0
fi

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"
BASELINE_FILE="$SPRINT_DIR/.baseline-embedding.json"
SPEC_FILE="$SPRINT_DIR/spec.md"

# Pre-spec-lock: no baseline yet → skip check (wizard still running)
if [ ! -f "$BASELINE_FILE" ]; then
  echo "[sprint-drift-check] no baseline yet (pre-spec-lock) — skipping" >&2
  exit 0
fi

# Sprint paused? skip — user is mid-recovery
PHASE="$(grep -o '"phase":[[:space:]]*"[^"]*"' "$STATE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
if [ "$PHASE" = "paused" ]; then
  echo "[sprint-drift-check] sprint is paused — skipping" >&2
  exit 0
fi

# ── Build commit signal text ─────────────────────────────────────────────────
# AC-4 (Bug #14): exclude lockfiles + auto-generated files from the signal
# BEFORE embedding. Massive lockfile diffs (e.g., pnpm-lock.yaml 13K+ lines)
# dilute the BoW cosine signal below threshold even when commit is in-scope.
# Filter via `git diff --cached -- <files-minus-excluded>`.

COMMIT_MSG_FILE="${1:-.git/COMMIT_EDITMSG}"
COMMIT_MSG="$(cat "$COMMIT_MSG_FILE" 2>/dev/null || echo "")"

# Excluded paths from drift signal (pathspecs for git diff)
DRIFT_EXCLUDE_PATHSPECS=(
  ':(exclude)*.lock'
  ':(exclude)*.lockb'
  ':(exclude)pnpm-lock.yaml'
  ':(exclude)package-lock.json'
  ':(exclude)yarn.lock'
  ':(exclude)*.snap'
  ':(exclude)**/__snapshots__/**'
  ':(exclude)*.generated.ts'
  ':(exclude)*.generated.tsx'
  ':(exclude)**/dist/**'
  ':(exclude)**/.next/**'
)

# Allow per-baseline override via .baseline-embedding.json.lockfile_exclusion[]
# (future extension; for now use the hardcoded defaults above)

DIFF_STAT="$(git diff --cached --stat -- . "${DRIFT_EXCLUDE_PATHSPECS[@]}" 2>/dev/null || echo "")"
# Sample first 200 changed lines (caps at ~5KB) — keeps semantic signal manageable
DIFF_SAMPLE="$(git diff --cached --no-color -- . "${DRIFT_EXCLUDE_PATHSPECS[@]}" 2>/dev/null | head -200 || echo "")"

# If filtering yields nothing meaningful (e.g., commit was lockfile-only),
# log it and skip drift check (allow the commit — it's trivially "in scope"
# because there's no semantic content to compare).
if [ -z "$DIFF_STAT" ] || [ "$(echo "$DIFF_STAT" | tr -d '[:space:]')" = "" ]; then
  echo "[sprint-drift-check] commit is lockfile-only / excluded-paths only — skipping drift check" >&2
  exit 0
fi

COMMIT_SIGNAL="$(printf '%s\n\n%s\n\n%s\n' "$COMMIT_MSG" "$DIFF_STAT" "$DIFF_SAMPLE")"

# Write to temp for the embedding tool
COMMIT_SIGNAL_FILE="$(mktemp -t sprint-drift-commit.XXXXXX)"
trap 'rm -f "$COMMIT_SIGNAL_FILE"' EXIT
printf '%s' "$COMMIT_SIGNAL" > "$COMMIT_SIGNAL_FILE"

# ── Compute drift score ──────────────────────────────────────────────────────
THRESHOLD="${SPRINT_DRIFT_THRESHOLD:-0.75}"

SCORE_OUT="$(node "$REPO_ROOT/scripts/sprint-drift-score.mjs" \
  "$BASELINE_FILE" "$COMMIT_SIGNAL_FILE" 2>&1 || true)"
SCORE="$(echo "$SCORE_OUT" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"

if [ -z "$SCORE" ]; then
  echo "[sprint-drift-check] could not compute score (output: $SCORE_OUT) — allowing commit" >&2
  exit 2
fi

# ── Record score to state.json ───────────────────────────────────────────────
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
atomic_update_state "$SLUG" --argjson score "$SCORE" --arg at "$NOW_ISO" --argjson msg "$(printf '%s' "$COMMIT_MSG" | head -c 200 | jq -Rs .)" '.drift_score_latest = $score | .drift_events += [{at: $at, score: $score, msg: $msg}]'

# ── Decision ─────────────────────────────────────────────────────────────────
if awk -v s="$SCORE" -v t="$THRESHOLD" 'BEGIN{exit !(s>=t)}'; then
  echo "[sprint-drift-check] drift score $SCORE ≥ $THRESHOLD ✓ proceeding" >&2
  exit 0
fi

# Below threshold → pause + prompt
cat >&2 <<EOF

╔══════════════════════════════════════════════════════════════════════╗
║  DRIFT DETECTED — sprint paused                                      ║
╚══════════════════════════════════════════════════════════════════════╝

  Sprint:    $SLUG
  Spec:      $SPEC_FILE
  Threshold: $THRESHOLD
  Score:     $SCORE   ← below threshold

  Commit message:
$(echo "$COMMIT_MSG" | head -5 | sed 's/^/    /')

  This commit semantically diverges from the spec's intent. Options:

  (a) AMEND SPEC to include this work
       bash scripts/sprint-amend-spec.sh
       (opens editor, re-baselines drift on save)

  (b) DISCARD this commit (drift was unintentional)
       git reset HEAD~ --soft  # or fix the staged diff

  (c) OVERRIDE ONCE (will be logged in retro)
       SPRINT_DRIFT_BYPASS=1 git commit
       (or: re-run this commit with the env var)

  Recommended: (a) if you genuinely need to expand scope, (b) if you
  accidentally pulled in unrelated work, (c) only if you have a good
  reason and are ready to explain it in retro.

EOF

exit 1
