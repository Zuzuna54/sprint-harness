#!/usr/bin/env bash
# phase-predicates.sh — predicate engine for sprint phase manifest.
#
# Public API:
#   check_phase_requirements <slug> <phase>
#     Reads scripts/lib/phase-manifest.json, walks the phase's
#     required_artifacts + required_state_fields + required_sub_step_gates,
#     and evaluates each predicate against the sprint dir.
#     Returns 0 iff all predicates pass (or are bypassed in state.gate_bypasses[]).
#     Returns 1 with [FAIL] lines on stderr per failing predicate.
#
#   sub_step_recorded <slug> <gate-name>
#     Returns 0 if state.gates_passed[] OR state.gates[] contains an entry
#     where .gate == <gate-name> (gates_passed/gates union for v0.7.x dual-write).
#     Returns 1 otherwise.
#
# Predicate kinds supported (must match validate-phase-manifest.mjs):
#   - file_exists                  → predicate.path file exists in sprint dir
#   - file_min_bytes               → predicate.path file exists AND ≥ predicate.min_bytes
#   - file_contains_heading        → predicate.path contains predicate.heading AND ≥ predicate.min_chars_under chars after it
#   - json_path_present            → predicate.path file parseable + .json_path resolves non-null
#   - json_path_equals             → resolved value == predicate.equals
#   - json_path_in                 → resolved value ∈ predicate.in[]
#   - state_field_min_length       → state.json json_path array/string has length ≥ min_length
#   - state_field_all_values_in    → state.json json_path array all values ∈ predicate.in[]
#   - sub_step_recorded            → gate name appears in state.gates_passed[] ∪ state.gates[]

set -uo pipefail

# Resolve our own dir regardless of how sourced.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _pp_self="${BASH_SOURCE[0]}"
else
  _pp_self="$0"
fi
_pp_dir="$(cd "$(dirname "$_pp_self")" && pwd)"
_pp_repo_root="$(cd "$_pp_dir/../.." && pwd)"
_pp_manifest="$_pp_dir/phase-manifest.json"

# ── Helpers ──────────────────────────────────────────────────────────────────

_pp_state_file() {
  echo "$_pp_repo_root/docs/sprints/$1/state.json"
}

_pp_sprint_dir() {
  echo "$_pp_repo_root/docs/sprints/$1"
}

# Read a value from state.json via jq path. Empty string if path missing.
_pp_state_get() {
  local slug="$1" path="$2"
  jq -r "$path // empty" "$(_pp_state_file "$slug")" 2>/dev/null
}

# Check if a bypass exists for this gate.
_pp_is_bypassed() {
  local slug="$1" gate="$2"
  local n
  n=$(jq -r --arg g "$gate" '[.gate_bypasses // [] | .[] | select(.gate == $g)] | length' "$(_pp_state_file "$slug")" 2>/dev/null)
  [ "${n:-0}" -gt 0 ]
}

# ── sub_step_recorded — public for use by predicates + sprint-advance-phase.sh ──

sub_step_recorded() {
  local slug="$1" gate="$2"
  local n
  # Union of gates_passed and gates (v0.7.x dual-write per AC-9).
  # Normalize entries: legacy entries are bare strings (e.g. "spec-lock");
  # v0.7+ entries are objects {gate, at, verdict, evidence?}.
  n=$(jq -r --arg g "$gate" '
    [
      (.gates_passed // []) | .[] | (if type=="string" then {gate: .} else . end) | select(.gate == $g)
    ] + [
      (.gates // []) | .[] | (if type=="string" then {gate: .} else . end) | select(.gate == $g)
    ] | length
  ' "$(_pp_state_file "$slug")" 2>/dev/null)
  [ "${n:-0}" -gt 0 ]
}

# ── Individual predicate evaluators (return 0 pass / 1 fail; print [FAIL] on fail) ──

_pp_pred_file_exists() {
  local slug="$1" path="$2"
  local abs="$(_pp_sprint_dir "$slug")/$path"
  if [ ! -e "$abs" ]; then
    echo "[FAIL] file_exists: $path (expected at $abs)" >&2
    return 1
  fi
  return 0
}

_pp_pred_file_min_bytes() {
  local slug="$1" path="$2" min="$3"
  local abs="$(_pp_sprint_dir "$slug")/$path"
  if [ ! -e "$abs" ]; then
    echo "[FAIL] file_min_bytes: $path missing (expected ≥ $min bytes)" >&2
    return 1
  fi
  local size
  size=$(wc -c < "$abs" | tr -d ' ')
  if [ "${size:-0}" -lt "$min" ]; then
    echo "[FAIL] file_min_bytes: $path is $size bytes, expected ≥ $min" >&2
    return 1
  fi
  return 0
}

_pp_pred_file_contains_heading() {
  local slug="$1" path="$2" heading="$3" min_chars="$4"
  local abs="$(_pp_sprint_dir "$slug")/$path"
  if [ ! -e "$abs" ]; then
    echo "[FAIL] file_contains_heading: $path missing (expected heading '$heading')" >&2
    return 1
  fi
  # Find line number of heading. Heading match is whole-line equal (after trim).
  local line_no
  line_no=$(awk -v h="$heading" 'BEGIN{IGNORECASE=0} {sub(/[[:space:]]+$/,"")} $0==h {print NR; exit}' "$abs")
  if [ -z "$line_no" ]; then
    echo "[FAIL] file_contains_heading: $path missing heading '$heading'" >&2
    return 1
  fi
  # Count chars from line after heading until next heading-of-same-or-higher level OR EOF.
  # Heading levels: count of leading '#'. We grab the prefix.
  local hash_count
  hash_count=$(echo "$heading" | awk '{for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="#") count++; else break} print count}')
  local content
  content=$(awk -v start="$line_no" -v hc="$hash_count" '
    NR > start {
      # Stop at heading at same or higher level
      if (match($0, /^#+/)) {
        n = RLENGTH
        if (n <= hc) exit
      }
      print
    }
  ' "$abs")
  local len=${#content}
  if [ "$len" -lt "$min_chars" ]; then
    echo "[FAIL] file_contains_heading: $path heading '$heading' has $len chars of body, expected ≥ $min_chars" >&2
    return 1
  fi
  return 0
}

_pp_pred_json_path_present() {
  local slug="$1" path="$2" jpath="$3"
  local abs
  if [ "$path" = "state.json" ]; then
    abs="$(_pp_state_file "$slug")"
  else
    abs="$(_pp_sprint_dir "$slug")/$path"
  fi
  if [ ! -e "$abs" ]; then
    echo "[FAIL] json_path_present: $path missing (expected $jpath to be present)" >&2
    return 1
  fi
  local val
  val=$(jq -r "$jpath // empty" "$abs" 2>/dev/null)
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    echo "[FAIL] json_path_present: $path:$jpath is null/missing" >&2
    return 1
  fi
  return 0
}

_pp_pred_json_path_equals() {
  local slug="$1" path="$2" jpath="$3" expected="$4"
  local abs
  if [ "$path" = "state.json" ]; then
    abs="$(_pp_state_file "$slug")"
  else
    abs="$(_pp_sprint_dir "$slug")/$path"
  fi
  if [ ! -e "$abs" ]; then
    echo "[FAIL] json_path_equals: $path missing" >&2
    return 1
  fi
  local val
  val=$(jq -r "$jpath" "$abs" 2>/dev/null)
  if [ "$val" != "$expected" ]; then
    echo "[FAIL] json_path_equals: $path:$jpath is '$val', expected '$expected'" >&2
    return 1
  fi
  return 0
}

_pp_pred_json_path_in() {
  local slug="$1" path="$2" jpath="$3" in_json="$4"
  local abs
  if [ "$path" = "state.json" ]; then
    abs="$(_pp_state_file "$slug")"
  else
    abs="$(_pp_sprint_dir "$slug")/$path"
  fi
  if [ ! -e "$abs" ]; then
    echo "[FAIL] json_path_in: $path missing" >&2
    return 1
  fi
  local matched
  matched=$(jq --argjson in_set "$in_json" "($jpath) as \$v | (\$in_set | index(\$v)) != null" "$abs" 2>/dev/null)
  if [ "$matched" != "true" ]; then
    local val
    val=$(jq -r "$jpath" "$abs" 2>/dev/null)
    echo "[FAIL] json_path_in: $path:$jpath is '$val', expected one of $in_json" >&2
    return 1
  fi
  return 0
}

_pp_pred_state_field_min_length() {
  local slug="$1" jpath="$2" min="$3"
  local sf="$(_pp_state_file "$slug")"
  local len
  len=$(jq -r "($jpath) | if type==\"array\" or type==\"string\" then length elif type==\"number\" then . else 0 end" "$sf" 2>/dev/null)
  if [ -z "$len" ] || [ "$len" = "null" ] || [ "$len" -lt "$min" ]; then
    echo "[FAIL] state_field_min_length: state.json:$jpath is '$len', expected ≥ $min" >&2
    return 1
  fi
  return 0
}

_pp_pred_state_field_all_values_in() {
  local slug="$1" jpath="$2" in_json="$3"
  local sf="$(_pp_state_file "$slug")"
  local all_in
  all_in=$(jq --argjson in_set "$in_json" "[$jpath] | all(. as \$v | (\$in_set | index(\$v)) != null)" "$sf" 2>/dev/null)
  if [ "$all_in" != "true" ]; then
    local actual
    actual=$(jq -r "[$jpath] | unique | join(\",\")" "$sf" 2>/dev/null)
    echo "[FAIL] state_field_all_values_in: state.json:$jpath has values [$actual], expected all in $in_json" >&2
    return 1
  fi
  return 0
}

_pp_pred_sub_step_recorded() {
  local slug="$1" gate="$2"
  if sub_step_recorded "$slug" "$gate"; then
    return 0
  fi
  echo "[FAIL] sub_step_recorded: gate '$gate' not in state.gates_passed[]/gates[]" >&2
  return 1
}

# ── Top-level: check all predicates for a phase ──────────────────────────────

check_phase_requirements() {
  local slug="$1" phase="$2"
  local manifest="${PHASE_MANIFEST:-$_pp_manifest}"

  if [ ! -f "$manifest" ]; then
    echo "[FAIL] check_phase_requirements: manifest not found at $manifest" >&2
    return 1
  fi

  # Pull phase block.
  local phase_block
  phase_block=$(jq -c --arg p "$phase" '.phases[$p] // empty' "$manifest" 2>/dev/null)
  if [ -z "$phase_block" ]; then
    echo "[FAIL] check_phase_requirements: phase '$phase' not in manifest" >&2
    return 1
  fi

  local worker_rigor
  worker_rigor=$(_pp_state_get "$slug" '.worker_rigor // "lax"')

  local fail_count=0
  local pass_count=0
  local bypassed_count=0

  # ── required_artifacts ─────────────────────────────────────────────────────
  while IFS= read -r pred; do
    [ -z "$pred" ] && continue
    local kind
    kind=$(echo "$pred" | jq -r '.kind')
    local gate_id="$kind:$(echo "$pred" | jq -r '.path // .json_path // "?"')"
    local rc=0
    case "$kind" in
      file_exists)
        _pp_pred_file_exists "$slug" "$(echo "$pred" | jq -r '.path')" || rc=$?
        ;;
      file_min_bytes)
        _pp_pred_file_min_bytes "$slug" \
          "$(echo "$pred" | jq -r '.path')" \
          "$(echo "$pred" | jq -r '.min_bytes')" || rc=$?
        ;;
      file_contains_heading)
        _pp_pred_file_contains_heading "$slug" \
          "$(echo "$pred" | jq -r '.path')" \
          "$(echo "$pred" | jq -r '.heading')" \
          "$(echo "$pred" | jq -r '.min_chars_under')" || rc=$?
        ;;
      json_path_present)
        _pp_pred_json_path_present "$slug" \
          "$(echo "$pred" | jq -r '.path')" \
          "$(echo "$pred" | jq -r '.json_path')" || rc=$?
        ;;
      json_path_equals)
        _pp_pred_json_path_equals "$slug" \
          "$(echo "$pred" | jq -r '.path')" \
          "$(echo "$pred" | jq -r '.json_path')" \
          "$(echo "$pred" | jq -r '.equals')" || rc=$?
        ;;
      json_path_in)
        _pp_pred_json_path_in "$slug" \
          "$(echo "$pred" | jq -r '.path')" \
          "$(echo "$pred" | jq -r '.json_path')" \
          "$(echo "$pred" | jq -c '.in')" || rc=$?
        ;;
      *)
        echo "[FAIL] unknown predicate kind '$kind' in required_artifacts" >&2
        rc=1
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      pass_count=$((pass_count + 1))
    else
      # Check bypass — gate name for file predicates = path; for json predicates = path:json_path
      local bypass_gate
      bypass_gate=$(echo "$pred" | jq -r '.path // .json_path')
      if _pp_is_bypassed "$slug" "$bypass_gate"; then
        echo "[BYPASS] $kind:$bypass_gate" >&2
        bypassed_count=$((bypassed_count + 1))
      else
        fail_count=$((fail_count + 1))
      fi
    fi
  done < <(echo "$phase_block" | jq -c '.required_artifacts[]?')

  # ── required_state_fields ──────────────────────────────────────────────────
  while IFS= read -r pred; do
    [ -z "$pred" ] && continue
    local kind
    kind=$(echo "$pred" | jq -r '.kind')
    local rc=0
    case "$kind" in
      state_field_min_length)
        _pp_pred_state_field_min_length "$slug" \
          "$(echo "$pred" | jq -r '.json_path')" \
          "$(echo "$pred" | jq -r '.min_length')" || rc=$?
        ;;
      state_field_all_values_in)
        _pp_pred_state_field_all_values_in "$slug" \
          "$(echo "$pred" | jq -r '.json_path')" \
          "$(echo "$pred" | jq -c '.in')" || rc=$?
        ;;
      json_path_present)
        _pp_pred_json_path_present "$slug" \
          "$(echo "$pred" | jq -r '.path // "state.json"')" \
          "$(echo "$pred" | jq -r '.json_path')" || rc=$?
        ;;
      json_path_in)
        _pp_pred_json_path_in "$slug" \
          "$(echo "$pred" | jq -r '.path // "state.json"')" \
          "$(echo "$pred" | jq -r '.json_path')" \
          "$(echo "$pred" | jq -c '.in')" || rc=$?
        ;;
      *)
        echo "[FAIL] unknown predicate kind '$kind' in required_state_fields" >&2
        rc=1
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      pass_count=$((pass_count + 1))
    else
      local bypass_gate
      bypass_gate="state-field:$(echo "$pred" | jq -r '.json_path')"
      if _pp_is_bypassed "$slug" "$bypass_gate"; then
        echo "[BYPASS] $kind:$bypass_gate" >&2
        bypassed_count=$((bypassed_count + 1))
      else
        fail_count=$((fail_count + 1))
      fi
    fi
  done < <(echo "$phase_block" | jq -c '.required_state_fields[]?')

  # ── required_sub_step_gates ────────────────────────────────────────────────
  # T4: gates listed in manifest.deferred_gates[] are NOT yet instrumented by
  # record_sub_step. Treat them as [DEFERRED] (don't block phase advance) so
  # operators don't need 40+ bypasses per v0.7.0 sprint.
  local deferred_set
  deferred_set=$(jq -r '.deferred_gates[]?' "$manifest" 2>/dev/null)
  local deferred_count=0

  while IFS= read -r gate; do
    [ -z "$gate" ] && continue
    if sub_step_recorded "$slug" "$gate"; then
      pass_count=$((pass_count + 1))
    elif _pp_is_bypassed "$slug" "$gate"; then
      echo "[BYPASS] sub_step:$gate" >&2
      bypassed_count=$((bypassed_count + 1))
    elif echo "$deferred_set" | grep -Fxq "$gate"; then
      echo "[DEFERRED] sub_step:$gate (not yet instrumented — see _guides/sub-step-coverage.md)" >&2
      deferred_count=$((deferred_count + 1))
    else
      echo "[FAIL] sub_step_recorded: gate '$gate' not in state.gates_passed[]/gates[]" >&2
      fail_count=$((fail_count + 1))
    fi
  done < <(echo "$phase_block" | jq -r '.required_sub_step_gates[]?')

  # ── strict_only_sub_step_gates (only if worker_rigor==strict) ─────────────
  if [ "$worker_rigor" = "strict" ]; then
    while IFS= read -r gate; do
      [ -z "$gate" ] && continue
      if sub_step_recorded "$slug" "$gate"; then
        pass_count=$((pass_count + 1))
      elif _pp_is_bypassed "$slug" "$gate"; then
        echo "[BYPASS] strict-sub_step:$gate" >&2
        bypassed_count=$((bypassed_count + 1))
      elif echo "$deferred_set" | grep -Fxq "$gate"; then
        echo "[DEFERRED] strict-sub_step:$gate" >&2
        deferred_count=$((deferred_count + 1))
      else
        echo "[FAIL] sub_step_recorded (strict): gate '$gate' not in state.gates_passed[]/gates[]" >&2
        fail_count=$((fail_count + 1))
      fi
    done < <(echo "$phase_block" | jq -r '.strict_only_sub_step_gates[]?')
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo "[SUMMARY] phase=$phase pass=$pass_count fail=$fail_count bypassed=$bypassed_count deferred=$deferred_count worker_rigor=$worker_rigor" >&2
    return 1
  fi
  echo "[OK] phase=$phase pass=$pass_count bypassed=$bypassed_count deferred=$deferred_count worker_rigor=$worker_rigor" >&2
  return 0
}
