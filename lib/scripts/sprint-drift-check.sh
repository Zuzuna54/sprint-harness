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

# ── Emergency bypass ─────────────────────────────────────────────────────────
if [ "${SPRINT_DRIFT_BYPASS:-}" = "1" ]; then
  echo "[sprint-drift-check] BYPASS=1 — skipping drift check (logging to state.gate_bypasses[])" >&2
  # Log bypass to state.gate_bypasses[] (was silent before — violates the
  # "all bypasses logged" contract in bypass-cheatsheet.md).
  REPO_ROOT_LOG="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  ACTIVE_SLUG=$(bash "$REPO_ROOT_LOG/scripts/sprint-status.sh" --slug-only 2>/dev/null || true)
  if [ -n "$ACTIVE_SLUG" ] && command -v jq >/dev/null 2>&1; then
    SF="$REPO_ROOT_LOG/docs/sprints/$ACTIVE_SLUG/state.json"
    if [ -f "$SF" ]; then
      tmp=$(mktemp)
      jq --arg at "$(date -u +%FT%TZ)" \
        '.gate_bypasses = ((.gate_bypasses // []) + [{gate:"drift-check", at:$at, reason:"SPRINT_DRIFT_BYPASS=1"}])' \
        "$SF" > "$tmp" && mv "$tmp" "$SF"
    fi
  fi
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# ── Find active sprint ───────────────────────────────────────────────────────
if [ ! -x scripts/sprint-status.sh ]; then
  # sprint system not installed; nothing to check
  exit 0
fi

SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"

if [ -z "$SLUG" ]; then
  # No active sprint — nothing to check
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
TMP="$(mktemp)"
if command -v jq >/dev/null 2>&1; then
  jq ".drift_score_latest = $SCORE | .drift_events += [{at: \"$NOW_ISO\", score: $SCORE, msg: $(printf '%s' "$COMMIT_MSG" | head -c 200 | jq -Rs .)}]" "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
fi

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
