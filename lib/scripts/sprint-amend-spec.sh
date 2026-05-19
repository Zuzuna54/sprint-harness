#!/usr/bin/env bash
# sprint-amend-spec.sh — Amend the active sprint's spec.md, re-baseline drift.
#
# Modes:
#   bash scripts/sprint-amend-spec.sh                # open spec.md in $EDITOR (or print path)
#   bash scripts/sprint-amend-spec.sh --lock         # lock current spec (used at spec-lock gate)
#   bash scripts/sprint-amend-spec.sh --cut <AC-IDs> # cut ACs from §I (comma-separated)
#   bash scripts/sprint-amend-spec.sh --pivot        # alias for default (edit mode)
#   bash scripts/sprint-amend-spec.sh --add-file <path>  # add to §H Files touched + rebaseline
#
# After any modification, the drift baseline is regenerated unless --no-rebaseline.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/atomic-state.sh"

MODE="edit"
NO_REBASELINE=false
EXTRA_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --lock)            MODE="lock"; shift ;;
    --cut)             MODE="cut"; shift; EXTRA_ARG="${1:-}"; shift ;;
    --pivot)           MODE="edit"; shift ;;
    --add-migration)    MODE="add-migration"; shift ;;
    --add-file)        MODE="add-file"; shift; EXTRA_ARG="${1:-}"; shift ;;
    --close-ac)        MODE="close-ac"; shift; EXTRA_ARG="${1:-}"; shift ;;
    --no-rebaseline)   NO_REBASELINE=true; shift ;;
    *) echo "[!] unknown arg: $1" >&2; shift ;;
  esac
done

SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint." >&2
  exit 1
fi

SPRINT_DIR="docs/sprints/$SLUG"
SPEC_FILE="$SPRINT_DIR/spec.md"
STATE_FILE="$SPRINT_DIR/state.json"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [ ! -f "$SPEC_FILE" ]; then
  echo "[!] spec.md not found: $SPEC_FILE" >&2
  echo "    If the wizard is still running, run: node scripts/sprint-wizard-assemble.mjs $SLUG --partial"
  exit 1
fi

# ── Modes ────────────────────────────────────────────────────────────────────

case "$MODE" in
  lock)
    # Lock the spec: write baseline, update state.phase = spec-locked
    bash scripts/sprint-rebaseline.sh "$SLUG"

    # AC-7 (Bug #16): parse spec.md for files mentioned in §H Integration Points
    # AND the dedicated "## Files touched (claims scope)" section. Populates
    # state.files_touched with anything that looks like a file path.
    FILES_TOUCHED_JSON="$(node -e "
      const fs=require('fs');
      const spec=fs.readFileSync('$SPEC_FILE','utf8');
      const files=new Set();
      // Sources: (1) §H Integration Points section, (2) ## Files touched (claims scope) section
      const sources=[];
      const hMatch=spec.match(/##\s+§H[\s\S]*?(?=\n##\s|\n---|\$)/);
      if(hMatch)sources.push(hMatch[0]);
      const ftMatch=spec.match(/##\s+Files touched[^\n]*\n([\s\S]*?)(?=\n##|\n---|\$)/);
      if(ftMatch)sources.push(ftMatch[1]);
      // Heuristic regex: extract any path-like token (with /, with ext)
      const pathRegex=/([a-zA-Z0-9_-][a-zA-Z0-9_./*-]+\.(?:ts|tsx|js|jsx|json|md|sql|sh|cjs|mjs|yml|yaml|html|css))/g;
      for(const src of sources){
        let m;while((m=pathRegex.exec(src))!==null){
          const p=m[1].replace(/[\`'\"]\$/,'').trim();
          if(p && p.length<300) files.add(p);
        }
      }
      console.log(JSON.stringify([...files]));
    " 2>/dev/null || echo '[]')"

    if command -v jq >/dev/null 2>&1; then
      # AC-7 (deterministic-phases-v1): write files_touched + record spec-lock sub-step,
      # but DELEGATE the phase write to sprint-advance-phase.sh. The delegated call
      # enforces the spec-locked phase's manifest predicates (4-way review artifacts).
      atomic_update_state "$SLUG" --argjson f "$FILES_TOUCHED_JSON" \
        ".files_touched = (\$f + (.files_touched // []) | unique)"

      # AC-10 (deterministic-phases-v1): read worker_rigor from wizard §J answers
      # and write to state.worker_rigor. Default 'lax' if unset.
      PARTIAL_FILE="$REPO_ROOT/docs/sprints/$SLUG/spec.partial.json"
      if [ -f "$PARTIAL_FILE" ]; then
        WORKER_RIGOR=$(jq -r '.sections_answers.J.worker_rigor // "lax"' "$PARTIAL_FILE" 2>/dev/null)
      else
        WORKER_RIGOR="lax"
      fi
      # Validate value
      case "$WORKER_RIGOR" in
        lax|strict) ;;
        *) WORKER_RIGOR="lax" ;;
      esac
      atomic_update_state "$SLUG" --arg r "$WORKER_RIGOR" '.worker_rigor = $r'
      echo "[+] state.worker_rigor = $WORKER_RIGOR"

      # Record spec-lock sub-step via sub-step.sh (idempotent, dual-write to gates + gates_passed)
      # shellcheck disable=SC1091
      source "$(dirname "$0")/lib/sub-step.sh" 2>/dev/null || true
      if declare -F record_sub_step >/dev/null 2>&1; then
        record_sub_step "$SLUG" "spec-lock-baseline-written" pass ".baseline-embedding.json" || true
      else
        # Fallback for harnesses without sub-step.sh installed yet (legacy compat)
        atomic_update_state "$SLUG" --arg at "$NOW_ISO" '.gate_history = ((.gate_history // []) + [{gate: "spec-lock", status: "passed", at: $at}])'
      fi
    fi

    FILES_COUNT="$(echo "$FILES_TOUCHED_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>console.log(JSON.parse(s).length))')"
    echo "[+] Spec locked. Drift baseline written."
    echo "[+] state.files_touched populated from §H1: $FILES_COUNT files"

    # AC-7 (deterministic-phases-v1): delegate the actual phase transition to
    # sprint-advance-phase.sh. It enforces the spec-locked manifest predicates
    # (4-way review artifacts + sub-step gates). If predicates fail, baseline
    # is still written (that succeeded above) but phase stays at spec-wizard
    # until operator completes the 4-way review + re-runs:
    #   bash scripts/sprint-advance-phase.sh spec-locked
    if [ -x "$(dirname "$0")/sprint-advance-phase.sh" ]; then
      SPRINT_SLUG_OVERRIDE="$SLUG" bash "$(dirname "$0")/sprint-advance-phase.sh" spec-locked 2>&1 || {
        echo "[i] Spec lock baseline written; phase advance to spec-locked deferred." >&2
        echo "[i] Complete the 4-way review then run: bash scripts/sprint-advance-phase.sh spec-locked" >&2
      }
    fi
    ;;

  cut)
    if [ -z "$EXTRA_ARG" ]; then
      echo "[!] --cut requires AC IDs (comma-separated, e.g., AC-3,AC-5)" >&2
      exit 1
    fi

    # AC-31: rich amendment metadata for scope cuts too.
    AMEND_WHY="${AMEND_WHY:-}"
    AMEND_INTENT="${AMEND_INTENT:-}"
    AMEND_ALTERNATIVES="${AMEND_ALTERNATIVES:-}"
    AMEND_DECIDED_BY="${AMEND_DECIDED_BY:-user}"

    if [ -z "$AMEND_WHY" ] && [ "${AMEND_NONINTERACTIVE:-0}" != "1" ] && [ -t 0 ]; then
      printf 'Why are we cutting these ACs (1-2 sentences)? ' >&2
      read -r AMEND_WHY
      printf 'What does success look like with reduced scope? ' >&2
      read -r AMEND_INTENT
      printf 'Alternatives considered (blank if none)? ' >&2
      read -r AMEND_ALTERNATIVES
    fi

    # AC-31 strict mode for cuts too
    if [ -z "$AMEND_WHY" ] || [ -z "$AMEND_INTENT" ]; then
      if [ "${AMEND_ALLOW_EMPTY:-0}" != "1" ]; then
        echo "[!] AC-31 strict: scope cut requires AMEND_WHY + AMEND_INTENT (or AMEND_ALLOW_EMPTY=1)" >&2
        exit 1
      fi
      AMEND_WHY="${AMEND_WHY:-mid-cycle scope reduction (no detail provided)}"
      AMEND_INTENT="${AMEND_INTENT:-ship remaining ACs within appetite}"
      AMEND_DECIDED_BY="${AMEND_DECIDED_BY:-AMEND_ALLOW_EMPTY-bypass}"
    fi

    cat >> "$SPEC_FILE" <<EOF

### Amendment ${NOW_ISO} — scope cut

- **Cut ACs:** $EXTRA_ARG
- **Why:** $AMEND_WHY
- **Intent:** $AMEND_INTENT
- **Alternatives considered:** ${AMEND_ALTERNATIVES:-(none)}
- **Decided by:** $AMEND_DECIDED_BY
- **Drift score before:** see state.json
EOF

    if command -v jq >/dev/null 2>&1; then
      atomic_update_state "$SLUG" \
        --arg at "$NOW_ISO" --arg cut "$EXTRA_ARG" \
        --arg why "$AMEND_WHY" --arg intent "$AMEND_INTENT" \
        --arg alt "$AMEND_ALTERNATIVES" --arg by "$AMEND_DECIDED_BY" \
        '.scope_amendments = ((.scope_amendments // []) + [{
           at: $at, action: "scope-cut", cut_acs: $cut,
           why: $why, intent: $intent,
           alternatives_considered: $alt, decided_by: $by
         }])'
    fi
    echo "[+] Recorded scope cut: $EXTRA_ARG"
    echo "    why: $AMEND_WHY"
    ;;

add-migration)
    CLAIMS_DIR="$REPO_ROOT/packages/db/src/migrations/.claims"
    mkdir -p "$CLAIMS_DIR"

    # Find highest existing claim number
    highest=0
    for dir in "$CLAIMS_DIR"/*/; do
      if [ -d "$dir" ]; then
        name="$(basename "$dir")"
        if [[ "$name" =~ ^[0-9]{4}$ ]]; then
          num="${name#0}" # strip leading zeros
          if [ "$num" -gt "$highest" ]; then
            highest="$num"
          fi
        fi
      fi
    done

    next=$((highest + 1))
    retry=0
    max_retries=5
    migrated=false

    while [ $retry -lt $max_retries ]; do
      NNNN="$(printf '%04d' $next)"
      if mkdir "$CLAIMS_DIR/$NNNN" 2>/dev; then
        echo "$SLUG" > "$CLAIMS_DIR/$NNNN/owner"
        migrated=true
        break
      fi
      next=$((next + 1))
      retry=$((retry + 1))
    done

    if [ "$migrated" = false ]; then
      echo "[!] AC-5: Could not claim migration number. Tried NNNN from $highest to $next." >&2
      echo "    Pick next NNNN manually (use highest existing + 1), then:" >&2
      echo "    mkdir -p packages/db/src/migrations/.claims/<NNNN>" >&2
      echo "    echo '$SLUG' > packages/db/src/migrations/.claims/<NNNN>/owner" >&2
      exit 1
    fi

    echo "[+] AC-5: Claimed migration slot $NNNN for sprint '$SLUG'"
    echo "    owner file: packages/db/src/migrations/.claims/$NNNN/owner"
    ;;

  add-file)
    if [ -z "$EXTRA_ARG" ]; then
      echo "[!] --add-file requires a path" >&2
      exit 1
    fi

    # AC-31 (sprint-system-100): rich amendment metadata.
    # Read structured fields from env vars OR prompt interactively. Captures:
    # - why (free-form reason for the scope expansion)
    # - intent (what success looks like after this amendment)
    # - scope_impact (files added/cut/replaced + ACs affected)
    # - alternatives_considered (what else we thought about)
    # If $AMEND_NONINTERACTIVE=1, missing fields default to placeholders.
    AMEND_WHY="${AMEND_WHY:-}"
    AMEND_INTENT="${AMEND_INTENT:-}"
    AMEND_SCOPE_IMPACT="${AMEND_SCOPE_IMPACT:-files_added: $EXTRA_ARG}"
    AMEND_ALTERNATIVES="${AMEND_ALTERNATIVES:-}"
    AMEND_ACS_AFFECTED="${AMEND_ACS_AFFECTED:-}"
    AMEND_DECIDED_BY="${AMEND_DECIDED_BY:-user}"

    if [ -z "$AMEND_WHY" ] && [ "${AMEND_NONINTERACTIVE:-0}" != "1" ] && [ -t 0 ]; then
      printf 'Why is this scope addition needed (1-2 sentences)? ' >&2
      read -r AMEND_WHY
      printf 'What does success look like after this amendment? ' >&2
      read -r AMEND_INTENT
      printf 'Which AC IDs are affected (comma-separated, blank if scope-only)? ' >&2
      read -r AMEND_ACS_AFFECTED
      printf 'Alternatives considered (blank if none)? ' >&2
      read -r AMEND_ALTERNATIVES
    fi

    # AC-31 strict: hard-fail if amendment context missing.
    # Auto-callers MUST export AMEND_WHY + AMEND_INTENT or bypass with
    # AMEND_ALLOW_EMPTY=1 (logged for retro review).
    if [ -z "$AMEND_WHY" ] || [ -z "$AMEND_INTENT" ]; then
      if [ "${AMEND_ALLOW_EMPTY:-0}" != "1" ]; then
        cat >&2 <<MSG
[!] AC-31 strict: amendment requires AMEND_WHY and AMEND_INTENT env vars.
    Either run interactively, OR export both before invoking:
      AMEND_WHY="..." AMEND_INTENT="..." bash scripts/sprint-amend-spec.sh --add-file <path>
    Or bypass once with AMEND_ALLOW_EMPTY=1 (logged in retro).
    Missing: WHY='${AMEND_WHY}', INTENT='${AMEND_INTENT}'
    File:    $EXTRA_ARG
MSG
        exit 1
      fi
      AMEND_WHY="${AMEND_WHY:-(AMEND_ALLOW_EMPTY bypass — not provided)}"
      AMEND_INTENT="${AMEND_INTENT:-(AMEND_ALLOW_EMPTY bypass — not provided)}"
      AMEND_DECIDED_BY="${AMEND_DECIDED_BY:-AMEND_ALLOW_EMPTY-bypass}"
    fi

    cat >> "$SPEC_FILE" <<EOF

### Amendment ${NOW_ISO} — add file to scope

- **Added:** \`$EXTRA_ARG\`
- **Why:** $AMEND_WHY
- **Intent:** $AMEND_INTENT
- **Scope impact:** $AMEND_SCOPE_IMPACT
- **ACs affected:** ${AMEND_ACS_AFFECTED:-(none)}
- **Alternatives considered:** ${AMEND_ALTERNATIVES:-(none)}
- **Decided by:** $AMEND_DECIDED_BY
EOF

    # Also update state.files_touched + structured scope_amendments[]
    if command -v jq >/dev/null 2>&1; then
      atomic_update_state "$SLUG" \
         --arg at "$NOW_ISO" \
         --arg path "$EXTRA_ARG" \
         --arg why "$AMEND_WHY" \
         --arg intent "$AMEND_INTENT" \
         --arg impact "$AMEND_SCOPE_IMPACT" \
         --arg alt "$AMEND_ALTERNATIVES" \
         --arg acs "$AMEND_ACS_AFFECTED" \
         --arg by "$AMEND_DECIDED_BY" \
         '.files_touched = (.files_touched + [$path] | unique)
          | .scope_amendments = ((.scope_amendments // []) + [{
              at: $at,
              action: "add-file",
              path: $path,
              why: $why,
              intent: $intent,
              scope_impact: $impact,
              alternatives_considered: $alt,
              acs_affected: $acs,
              decided_by: $by
            }])'
    fi
    echo "[+] Added to scope: $EXTRA_ARG"
    echo "    why:    $AMEND_WHY"
    echo "    intent: $AMEND_INTENT"
    ;;

  close-ac)
    # AC-2 (sprint-system-hardening, Bug #15): mark an AC as closed.
    # Validates AC-N exists in spec.md, then updates state.acs_closed_ids[]
    # (de-dup) + state.acs_closed count.
    if [ -z "$EXTRA_ARG" ]; then
      echo "[!] --close-ac requires an AC ID (e.g. AC-1)" >&2
      exit 1
    fi
    AC_ID="$EXTRA_ARG"
    # Normalize: allow "AC-1" or "1"
    if [[ "$AC_ID" =~ ^[0-9]+$ ]]; then
      AC_ID="AC-$AC_ID"
    fi
    # Validate AC exists in spec.md
    if ! grep -qE "\*\*$AC_ID\*\*" "$SPEC_FILE"; then
      echo "[!] $AC_ID not found in $SPEC_FILE — cannot close" >&2
      echo "    Existing ACs: $(grep -oE '\*\*AC-[0-9]+\*\*' "$SPEC_FILE" | sort -u | tr '\n' ' ')" >&2
      exit 1
    fi
    # Append to state.acs_closed_ids (de-dup) + count + closed_at timestamp
    if command -v jq >/dev/null 2>&1; then
      atomic_update_state "$SLUG" \
        --arg ac "$AC_ID" --arg at "$NOW_ISO" \
        '.acs_closed_ids = ((.acs_closed_ids // []) + [$ac] | unique)
         | .acs_closed = (.acs_closed_ids | length)
         | .acs_closed_at = ((.acs_closed_at // {}) | .[$ac] = $at)'
      # If acs_total wasn't set, count from spec.md now
      CURRENT_TOTAL="$(grep -o '"acs_total":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$' || echo 0)"
      if [ "$CURRENT_TOTAL" = "0" ]; then
        SPEC_TOTAL="$(grep -cE '\*\*AC-[0-9]+\*\*' "$SPEC_FILE" || echo 0)"
        atomic_update_state "$SLUG" --argjson n "$SPEC_TOTAL" '.acs_total = $n'
      fi
    else
      echo "[!] jq not available — cannot update state.json safely" >&2
      exit 1
    fi
    # Append amendment note to spec.md for audit trail
    cat >> "$SPEC_FILE" <<EOF

### Amendment ${NOW_ISO} — closed $AC_ID
EOF
    echo "[+] Closed $AC_ID"
    # Skip rebaseline for AC closures (no spec text change of consequence)
    NO_REBASELINE=true
    ;;

  edit|pivot)
    # Open in editor; if no editor, print path and instructions
    EDITOR="${EDITOR:-${VISUAL:-}}"
    if [ -z "$EDITOR" ]; then
      echo "$SPEC_FILE"
      echo ""
      echo "[i] No \$EDITOR set. Edit the file above manually, then run:"
      echo "    bash scripts/sprint-rebaseline.sh $SLUG"
      exit 0
    fi
    "$EDITOR" "$SPEC_FILE"
    ;;

  *)
    echo "[!] unknown mode: $MODE" >&2
    exit 1
    ;;
esac

# ── Rebaseline (unless suppressed or lock mode which already did it) ─────────
if [ "$NO_REBASELINE" = false ] && [ "$MODE" != "lock" ]; then
  bash scripts/sprint-rebaseline.sh "$SLUG"
fi

echo ""
echo "  Mode:        $MODE"
echo "  Spec:        $SPEC_FILE"
echo "  State:       $STATE_FILE"
echo ""
