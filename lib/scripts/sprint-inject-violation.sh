#!/usr/bin/env bash
# sprint-inject-violation.sh — Apply a violation fixture, run a gate, assert
# the gate CATCHES it, then restore.
#
# Used by harness-full-coverage sprint to prove each verify gate works.
#
# Usage:
#   bash scripts/sprint-inject-violation.sh <fixture-name> <gate-command>
#
# Where:
#   <fixture-name>   — basename in scripts/violation-fixtures/ (no .patch ext)
#   <gate-command>   — shell command to run; expected to EXIT NON-ZERO
#                       OR produce stdout/stderr matching ASSERT_PATTERN env var
#
# Env:
#   ASSERT_PATTERN   — substring to grep in gate output for "caught"
#   PROOF_FILE       — path to proof markdown to write
#   AC_ID            — AC identifier (for proof file header)
#   GATE_NAME        — human label for the gate
#
# Exit 0 = gate CAUGHT the violation. Exit 1 = gate failed to catch (real bug).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FIXTURE="${1:?fixture name required}"
GATE_CMD="${2:?gate command required}"
ASSERT_PATTERN="${ASSERT_PATTERN:-}"
PROOF_FILE="${PROOF_FILE:-/dev/stdout}"
AC_ID="${AC_ID:-AC-?}"
GATE_NAME="${GATE_NAME:-unknown}"

FIXTURE_PATH="scripts/violation-fixtures/${FIXTURE}.patch"
if [ ! -f "$FIXTURE_PATH" ]; then
  echo "[!] fixture not found: $FIXTURE_PATH" >&2
  exit 2
fi

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Step 1: BASELINE run (gate against clean main)
BASELINE_OUT="$(mktemp)"
BASELINE_RC=0
eval "$GATE_CMD" > "$BASELINE_OUT" 2>&1 || BASELINE_RC=$?

# Step 2: INJECT violation
INJECT_OK=0
git apply "$FIXTURE_PATH" 2>/dev/null && INJECT_OK=1
if [ "$INJECT_OK" = "0" ]; then
  echo "[!] could not apply fixture: $FIXTURE_PATH" >&2
  rm -f "$BASELINE_OUT"
  exit 2
fi

# Step 3: RE-RUN gate against injected violation
INJECTED_OUT="$(mktemp)"
INJECTED_RC=0
eval "$GATE_CMD" > "$INJECTED_OUT" 2>&1 || INJECTED_RC=$?

# Step 4: RESTORE (reverse-apply)
git apply -R "$FIXTURE_PATH" 2>/dev/null
# Check only files touched by THE FIXTURE (not whole tree — unrelated dirty
# files would cause false negatives). Parse `+++ b/<path>` lines only, skip
# `/dev/null`.
FIXTURE_FILES="$(awk '/^\+\+\+ b\// { sub(/^\+\+\+ b\//, ""); print }' "$FIXTURE_PATH" | sort -u)"
RESTORE_DIRTY=0
for f in $FIXTURE_FILES; do
  # If fixture added the file, it should NOT exist after restore.
  if [ -e "$f" ]; then
    RESTORE_DIRTY=$((RESTORE_DIRTY+1))
    continue
  fi
  # For pre-existing files modified by fixture, git diff should be clean.
  if ! git diff --quiet -- "$f" 2>/dev/null; then
    RESTORE_DIRTY=$((RESTORE_DIRTY+1))
  fi
done

# Step 5: Decide CAUGHT
CAUGHT="no"
if [ -n "$ASSERT_PATTERN" ]; then
  grep -qE "$ASSERT_PATTERN" "$INJECTED_OUT" 2>/dev/null && CAUGHT="yes"
else
  # No pattern → fall back to exit-code change (baseline=0, injected!=0)
  [ "$BASELINE_RC" = "0" ] && [ "$INJECTED_RC" != "0" ] && CAUGHT="yes"
fi

# Step 6: Write proof
cat > "$PROOF_FILE" <<MD
# Proof: $AC_ID — $GATE_NAME

Generated: $NOW

## Gate command
\`\`\`
$GATE_CMD
\`\`\`

## Violation fixture
\`$FIXTURE_PATH\`

## Phase 1 — baseline (clean main)
- Exit code: $BASELINE_RC
- Output (last 20 lines):
\`\`\`
$(tail -20 "$BASELINE_OUT")
\`\`\`

## Phase 2 — injected violation
- Exit code: $INJECTED_RC
- Output (last 20 lines):
\`\`\`
$(tail -20 "$INJECTED_OUT")
\`\`\`

## Phase 3 — restore
- Reverse-apply: $([ $? -eq 0 ] && echo "✓" || echo "✗")
- Working tree dirty after restore: $RESTORE_DIRTY non-empty diff line(s)

## Verdict

**Caught injected violation:** $CAUGHT

**Production-ready:** $([ "$CAUGHT" = "yes" ] && [ "$RESTORE_DIRTY" = "0" ] && echo "✓ yes" || echo "✗ no — see above")
MD

rm -f "$BASELINE_OUT" "$INJECTED_OUT"

[ "$CAUGHT" = "yes" ] || exit 1
[ "$RESTORE_DIRTY" = "0" ] || exit 1
exit 0
