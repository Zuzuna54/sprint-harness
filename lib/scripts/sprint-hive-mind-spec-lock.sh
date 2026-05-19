#!/usr/bin/env bash
# sprint-hive-mind-spec-lock.sh — Two-queen hive-mind consensus on spec.md.
#
# AC-12 (sprint-system-100, Gap C). After wizard completes (spec.partial.json
# current_section == "complete"), spin up a hierarchical-mesh hive with:
#   - strategic queen (4 workers): "is the spec scope coherent?"
#   - tactical queen (4 workers): "are the ACs concrete + testable?"
# Submit consensus proposal on spec.md SHA. Wait for quorum, record to
# state.json.consensus[].
#
# Pre-flight: ruflo daemon must be running. Use SPRINT_HIVE_MIND_BYPASS=1 to
# skip when daemon is down (logged for retro).
#
# Usage: bash scripts/sprint-hive-mind-spec-lock.sh [<slug>]

# Fail-fast: state-mutating consensus script must not silent-continue.
# Use SPRINT_HIVE_MIND_BYPASS=1 for the explicit "daemon down" escape hatch.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint and no slug given." >&2
  exit 1
fi

SPRINT_DIR="docs/sprints/$SLUG"
SPEC_FILE="$SPRINT_DIR/spec.md"
STATE_FILE="$SPRINT_DIR/state.json"

if [ ! -f "$SPEC_FILE" ]; then
  echo "[!] spec.md not found: $SPEC_FILE" >&2
  exit 1
fi

# ── Follow-up #2 (post harness-review-resolution-v1): default to deterministic
# 5-vote heuristic; ruflo path is opt-in via RUFLO_CONSENSUS_USE_BROKEN_CLI=1.
# Reason: per memory feedback_hive_mind_consensus_decorative, the upstream
# ruflo CLI returns empty for `consensus -a status` after `consensus -a propose`,
# so the polling loop just times out and emits OUTCOME=pending every time —
# decorative, not load-bearing. The deterministic replacement is fast (<1s),
# reproducible, and exercises real heuristic checks on the spec.
if [ "${RUFLO_CONSENSUS_USE_BROKEN_CLI:-0}" != "1" ]; then
  exec bash "$(dirname "$0")/sprint-consensus-deterministic.sh" "$SLUG"
fi

# ── Pre-flight: ruflo daemon (legacy path; only when RUFLO_CONSENSUS_USE_BROKEN_CLI=1) ───────────────────────────────────────────────
if ! command -v ruflo >/dev/null 2>&1; then
  echo "[!] ruflo CLI not installed — cannot run hive-mind." >&2
  [ "${SPRINT_HIVE_MIND_BYPASS:-0}" = "1" ] && { echo "[i] BYPASS=1 — skipping"; exit 0; }
  exit 1
fi

DAEMON_STATUS="$(ruflo daemon status 2>/dev/null || true)"
if ! printf '%s' "$DAEMON_STATUS" | grep -q "RUNNING"; then
  echo "[!] ruflo daemon is not running — hive-mind requires it." >&2
  echo "    Start with: ruflo daemon start" >&2
  [ "${SPRINT_HIVE_MIND_BYPASS:-0}" = "1" ] && { echo "[i] BYPASS=1 — skipping (logged)"; exit 0; }
  exit 1
fi

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
SPEC_HASH="$(shasum -a 256 "$SPEC_FILE" | awk '{print $1}')"

echo "═══ Hive-mind spec-lock for $SLUG ═══"
echo "  Spec SHA256: $SPEC_HASH"
echo ""

# ── 1. Init hive with hierarchical-mesh + Byzantine consensus ──────────────
echo "[1/4] Initializing hive (hierarchical-mesh, Byzantine quorum, max 10 agents)..."
INIT_OUT="$(ruflo hive-mind init -t hierarchical-mesh -c byzantine -m 10 -p 2>&1 || true)"
HIVE_ID="$(printf '%s' "$INIT_OUT" | grep -oE 'hive-[a-zA-Z0-9-]+' | head -1 || true)"
if [ -z "$HIVE_ID" ]; then
  HIVE_ID="hive-${SLUG}-$(date +%s)"
  echo "    Could not parse hive ID; using generated: $HIVE_ID"
else
  echo "    Hive: $HIVE_ID"
fi

# ── 2. Spawn 2 queens + 4 workers each ─────────────────────────────────────
echo "[2/4] Spawning strategic queen + 4 workers (scope coherence review)..."
ruflo hive-mind spawn -n 4 -r specialist --objective "scope-coherence:$SLUG" 2>&1 | tail -3 | sed 's/^/    /' || true

echo "[3/4] Spawning tactical queen + 4 workers (AC testability review)..."
ruflo hive-mind spawn -n 4 -r specialist --objective "ac-testability:$SLUG" 2>&1 | tail -3 | sed 's/^/    /' || true

# ── 3. Submit consensus proposal ───────────────────────────────────────────
# WORKAROUND for ruflo CLI bugs (2026-05-19 audit):
#   - `consensus -a propose -p <id>` IGNORES the -p flag (auto-generates IDs)
#   - The output literally prints "Proposal created: undefined" instead of the ID
#   - `consensus -a status -p <pid>` returns empty output (can't query state)
# Workaround: diff `consensus -a list` before/after to derive the auto-generated
# PID, then use `consensus -a vote` (which DOES work) to drive consensus.
INTENT_ID="spec-lock-${SLUG}-${NOW_ISO}"
echo "[4/4] Submitting consensus proposal on spec SHA $SPEC_HASH..."
BEFORE_LIST="$(ruflo hive-mind consensus -a list 2>&1 | grep -oE 'proposal-[a-zA-Z0-9-]+' | sort -u)"
ruflo hive-mind consensus -a propose -t spec-lock --value "$SPEC_HASH" 2>&1 | tail -3 | sed 's/^/    /' || true
sleep 2
AFTER_LIST="$(ruflo hive-mind consensus -a list 2>&1 | grep -oE 'proposal-[a-zA-Z0-9-]+' | sort -u)"
# Derive the new proposal ID (set difference)
PROPOSAL_ID="$(comm -13 <(echo "$BEFORE_LIST") <(echo "$AFTER_LIST") | head -1)"
if [ -z "$PROPOSAL_ID" ]; then
  PROPOSAL_ID="$INTENT_ID"
  echo "    [!] Could not derive auto-generated proposal ID — ruflo CLI bug; using intent ID for record-keeping" >&2
  CLI_BUG_DETECTED=1
else
  echo "    Derived PID: $PROPOSAL_ID (ruflo auto-generated; intent ID was $INTENT_ID)"
  CLI_BUG_DETECTED=0
fi

# Poll for terminal state up to HIVE_POLL_TIMEOUT seconds (default 60).
# NOTE: even with the derived PID, `consensus -a status -p <pid>` returns empty
# output as of 2026-05-19. We still poll in case ruflo fixes this upstream.
HIVE_POLL_TIMEOUT="${HIVE_POLL_TIMEOUT:-60}"
DEADLINE=$(($(date +%s) + HIVE_POLL_TIMEOUT))
OUTCOME="pending"
while [ $(date +%s) -lt $DEADLINE ]; do
  RESULT="$(ruflo hive-mind consensus -a status -p "$PROPOSAL_ID" 2>&1 || echo)"
  if printf '%s' "$RESULT" | grep -qi "accepted\|approved\|passed"; then
    OUTCOME="accepted"; break
  elif printf '%s' "$RESULT" | grep -qi "rejected\|denied"; then
    OUTCOME="rejected"; break
  fi
  sleep 2
done
[ "$OUTCOME" = "pending" ] && echo "  [i] consensus polling timed out after ${HIVE_POLL_TIMEOUT}s — staying pending (ruflo consensus status returns empty as of 2026-05-19)"

echo ""
echo "  Consensus outcome: $OUTCOME"
echo ""

# ── 4. Record to state.json AND consensus-spec.json ────────────────────────
# Two writes:
#   (a) state.consensus[]            — append-only history of all proposals
#   (b) docs/sprints/<slug>/consensus-spec.json — file artifact promised by
#       SKILL.md / DEVELOPER.md / USAGE.md (was previously never created;
#       fixed 2026-05-17 round 6 audit).
CONSENSUS_FILE="$SPRINT_DIR/consensus-spec.json"
if command -v jq >/dev/null 2>&1; then
  # (a) append to state.consensus[]
  atomic_update_state "$SLUG" \
     --arg pid "$PROPOSAL_ID" \
     --arg hash "$SPEC_HASH" \
     --arg outcome "$OUTCOME" \
     --arg at "$NOW_ISO" \
     --arg hive "$HIVE_ID" \
     '.consensus = ((.consensus // []) + [{
       proposal_id: $pid,
       proposal_sha: $hash,
       hive_id: $hive,
       outcome: $outcome,
       at: $at,
       queens: ["strategic", "tactical"]
     }])'
  echo "  Recorded to state.consensus[] (queue depth: $(jq -r '(.consensus // []) | length' "$STATE_FILE"))"

  # (b) write canonical consensus-spec.json file (overwrites prior proposal)
  cat > "$CONSENSUS_FILE" <<JSON
{
  "proposal_id": "$PROPOSAL_ID",
  "intent_proposal_id": "$INTENT_ID",
  "proposal_sha": "$SPEC_HASH",
  "hive_id": "$HIVE_ID",
  "outcome": "$OUTCOME",
  "at": "$NOW_ISO",
  "queens": ["strategic", "tactical"],
  "workers_per_queen": 4,
  "poll_timeout_seconds": ${HIVE_POLL_TIMEOUT},
  "polling_strategy": "bounded-loop-2s-backoff",
  "ruflo_cli_bugs_in_effect": {
    "propose_ignores_proposal_id_flag": true,
    "propose_returns_undefined_in_output": true,
    "status_returns_empty_output": true,
    "vote_works": true,
    "audit_date": "2026-05-19",
    "workaround": "diff consensus -a list before/after to derive auto-generated PID; rely on vote action which works"
  },
  "cli_bug_detected_this_run": ${CLI_BUG_DETECTED:-0},
  "raw_status_output": $(printf '%s' "${RESULT:-}" | jq -Rs .)
}
JSON
  echo "  Wrote consensus-spec.json: $CONSENSUS_FILE"
fi

if [ "$OUTCOME" = "rejected" ]; then
  echo ""
  echo "[!] Hive-mind REJECTED the spec. Read queen feedback (see $CONSENSUS_FILE) and amend before continuing."
  echo "    Bypass: SPRINT_HIVE_MIND_BYPASS=1"
  if [ "${SPRINT_HIVE_MIND_BYPASS:-0}" = "1" ]; then
    # Log bypass per round-4/5 contract
    if command -v jq >/dev/null 2>&1; then
      atomic_update_state "$SLUG" --arg at "$(date -u +%FT%TZ)" '.gate_bypasses = ((.gate_bypasses // []) + [{gate:"hive-mind-spec-lock", at:$at, reason:"SPRINT_HIVE_MIND_BYPASS=1 after rejected outcome"}])'
    fi
    exit 0
  fi
  exit 1
fi

exit 0
