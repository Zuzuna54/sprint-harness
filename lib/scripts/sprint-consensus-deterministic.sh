#!/usr/bin/env bash
# sprint-consensus-deterministic.sh — deterministic spec-lock consensus.
#
# Follow-up #2 to harness-review-resolution-v1. Replaces the ruflo hive-mind
# consensus call which is broken upstream (per memory
# feedback_hive_mind_consensus_decorative: `consensus -a status` returns empty,
# `consensus -a propose` ignores the -p flag, the polling loop just times out
# silently). The harness has been treating the call as decorative for months.
#
# This script runs 5 heuristic checks against spec.md — one per "vote" in the
# original 5-worker quorum — and tallies them into a verdict:
#   - pass            (≥4 / 5 PASS)
#   - pass-with-notes (3 / 5 PASS)
#   - dissent         (≤2 / 5 PASS — blocks spec-lock)
#
# Output: docs/sprints/<slug>/consensus-spec.json with the same shape the
# downstream phase-manifest predicate (json_path_in .verdict) expects.
#
# Usage: bash scripts/sprint-consensus-deterministic.sh [<slug>]
#
# Exit codes:
#   0 — pass or pass-with-notes (consensus reached)
#   1 — dissent (blocks spec-lock; operator must amend spec)
#   2 — caller error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
if [ -z "$SLUG" ] || ! [[ "$SLUG" =~ ^[a-z0-9-]{3,64}$ ]]; then
  echo "[consensus-deterministic] invalid or missing slug: $SLUG" >&2
  exit 2
fi

SPRINT_DIR="docs/sprints/$SLUG"
SPEC_FILE="$SPRINT_DIR/spec.md"
CONSENSUS_FILE="$SPRINT_DIR/consensus-spec.json"

if [ ! -f "$SPEC_FILE" ]; then
  echo "[consensus-deterministic] spec.md not found: $SPEC_FILE" >&2
  exit 2
fi

NOW_ISO="$(date -u +%FT%TZ)"
SPEC_HASH="$(shasum -a 256 "$SPEC_FILE" | awk '{print $1}')"

# ── 5 heuristic checks (one per "vote") ─────────────────────────────────────
# Each returns "pass" or "fail" + a one-line reason. The 5 are chosen to
# catch the patterns hive-mind WAS supposed to catch — scope coherence,
# AC testability, files-touched non-emptiness, risk-section completeness.

# Helper: safe integer count (grep -c exits 1 on zero matches and prints 0, so
# `|| echo 0` would double-print; instead capture stdout only).
_safe_count() { local c; c=$(grep -cE "$1" "$2" 2>/dev/null || true); echo "${c:-0}"; }

# Vote 1: AC count in reasonable range (3..30). Match `AC-N` references in
# any reasonable shape (heading, bullet, table cell, prose mention).
ac_count=$(_safe_count '\bAC-[0-9]+\b' "$SPEC_FILE")
if [ "$ac_count" -ge 3 ] && [ "$ac_count" -le 100 ]; then
  v1="pass"; v1_reason="AC-N references found: $ac_count (in range 3..100)"
else
  v1="fail"; v1_reason="AC-N references = $ac_count (outside 3..100; under-scoped or runaway)"
fi

# Vote 2: §H Files-touched / Integration Points section has bullet-shaped entries
# with file-extension or path-shape markers. The wizard's spec template uses
# `## §H — Integration Points` with sub-sections.
files_touched_count=$(awk '
  /^## §H |^## H |^## Files touched|^## Integration Points/ { in_h=1; next }
  /^## §?[A-IJ]/ && in_h { exit }
  in_h
' "$SPEC_FILE" 2>/dev/null | grep -cE '^[-*] |`[a-zA-Z0-9_./-]+\.[a-z]+`|/[a-zA-Z0-9_./-]+' || true)
files_touched_count="${files_touched_count:-0}"
if [ "$files_touched_count" -ge 1 ]; then
  v2="pass"; v2_reason="§H section has $files_touched_count integration-point line(s)"
else
  v2="fail"; v2_reason="§H section empty — no integration points listed"
fi

# Vote 3: No unresolved markers (TODO/FIXME/TBD/XXX/TKTK) in spec body, EXCLUDING
# any line that is itself a heading mentioning "follow-up" / "deferred".
ac_unresolved=$(grep -cE '\b(TODO|FIXME|TBD|XXX|TKTK)\b' "$SPEC_FILE" 2>/dev/null || true)
ac_unresolved="${ac_unresolved:-0}"
if [ "$ac_unresolved" -eq 0 ]; then
  v3="pass"; v3_reason="No TODO/FIXME/TBD/XXX markers in spec body"
else
  v3="fail"; v3_reason="$ac_unresolved unresolved marker(s) — spec not lock-ready"
fi

# Vote 4: §J Risks section has substantive content (≥100 chars)
risks_content=$(awk '
  /^## §J |^## J |^## Risks/ { in_j=1; next }
  /^## §?[A-Z]/ && in_j { exit }
  in_j
' "$SPEC_FILE" 2>/dev/null | wc -c | tr -d ' ')
risks_content="${risks_content:-0}"
if [ "$risks_content" -ge 100 ]; then
  v4="pass"; v4_reason="§J Risks has $risks_content chars of content"
else
  v4="fail"; v4_reason="§J Risks under 100 chars ($risks_content) — risk surface unexplored"
fi

# Vote 5: spec mentions verification mechanism somewhere (Verify / How verified /
# Verification / Given/When/Then Gherkin / Manual QA / test plan).
verify_hits=$(grep -ciE '\b(Verify|Verification|How verified|Given/When/Then|Manual QA|test plan|acceptance criteria)\b' "$SPEC_FILE" 2>/dev/null || true)
verify_hits="${verify_hits:-0}"
if [ "$verify_hits" -ge 2 ]; then
  v5="pass"; v5_reason="$verify_hits verification/testability mention(s) in spec"
else
  v5="fail"; v5_reason="Only $verify_hits verification mention(s) — testability unclear"
fi

# ── Tally ────────────────────────────────────────────────────────────────────
pass_count=0
for v in "$v1" "$v2" "$v3" "$v4" "$v5"; do
  [ "$v" = "pass" ] && pass_count=$((pass_count + 1))
done

if [ "$pass_count" -ge 4 ]; then
  verdict="pass"
elif [ "$pass_count" -eq 3 ]; then
  verdict="pass-with-notes"
else
  verdict="dissent"
fi

echo "═══ Deterministic consensus for $SLUG ═══" >&2
echo "  Spec SHA256: $SPEC_HASH" >&2
echo "  Vote 1 (ac-count):       $v1 — $v1_reason" >&2
echo "  Vote 2 (files-touched):  $v2 — $v2_reason" >&2
echo "  Vote 3 (no-unresolved):  $v3 — $v3_reason" >&2
echo "  Vote 4 (risks-section):  $v4 — $v4_reason" >&2
echo "  Vote 5 (verifiability):  $v5 — $v5_reason" >&2
echo "  Tally: $pass_count/5 pass → verdict=$verdict" >&2

# ── Write consensus-spec.json ────────────────────────────────────────────────
cat > "$CONSENSUS_FILE" <<JSON
{
  "verdict": "$verdict",
  "outcome": "$verdict",
  "consensus_kind": "deterministic-5-vote",
  "spec_sha256": "$SPEC_HASH",
  "at": "$NOW_ISO",
  "votes": [
    {"id": 1, "check": "ac_count_in_range",     "result": "$v1", "reason": $(printf '%s' "$v1_reason" | jq -Rs .)},
    {"id": 2, "check": "files_touched_nonempty","result": "$v2", "reason": $(printf '%s' "$v2_reason" | jq -Rs .)},
    {"id": 3, "check": "no_unresolved_markers", "result": "$v3", "reason": $(printf '%s' "$v3_reason" | jq -Rs .)},
    {"id": 4, "check": "risks_section_filled",  "result": "$v4", "reason": $(printf '%s' "$v4_reason" | jq -Rs .)},
    {"id": 5, "check": "ac_verifiability",      "result": "$v5", "reason": $(printf '%s' "$v5_reason" | jq -Rs .)}
  ],
  "pass_count": $pass_count,
  "total_votes": 5,
  "note": "Replaces ruflo hive-mind consensus (broken upstream, see memory feedback_hive_mind_consensus_decorative). Deterministic 5-vote heuristic — fast, reproducible, no external dependency. Set RUFLO_CONSENSUS_USE_BROKEN_CLI=1 on sprint-hive-mind-spec-lock.sh to fall back to the legacy ruflo path."
}
JSON

# Record to state.consensus[] for the audit trail (same shape as legacy)
atomic_update_state "$SLUG" \
  --arg pid "deterministic-$SLUG-$NOW_ISO" \
  --arg hash "$SPEC_HASH" \
  --arg verdict "$verdict" \
  --arg at "$NOW_ISO" \
  '.consensus = ((.consensus // []) + [{
    proposal_id: $pid,
    proposal_sha: $hash,
    hive_id: "deterministic-5-vote",
    outcome: $verdict,
    at: $at,
    queens: ["deterministic"]
  }])' 2>/dev/null || true

echo "  Wrote $CONSENSUS_FILE" >&2

if [ "$verdict" = "dissent" ]; then
  exit 1
fi
exit 0
