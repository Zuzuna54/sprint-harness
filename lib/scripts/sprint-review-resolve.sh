#!/usr/bin/env bash
# sprint-review-resolve.sh — UNIFIED multi-producer review-finding walker.
#
# W1 (harness-review-resolution-v1, AC-2): supersedes sprint-audit-resolve.sh
# by handling 3 producer streams (audit + knip + sonar) under a single
# review_findings[] aggregation.
#
# State fields managed:
#  - state.review_findings[]              — append-only union of producer findings
#  - state.review_findings_total          — populated on first invocation
#  - state.review_findings_resolved_count — incremented on Fix path
#  - state.review_findings_deferred[]     — {producer, har_id, ..., deferred_to_sprint, ac_id, rationale}
#  - state.review_findings_accepted[]     — {producer, har_id, ..., risk_owner, business_rationale}
#
# Security (C5 + C7 inherited):
#  - Rationale piped through sprint-pii-redact.sh before atomic_update_state.
#  - deferred_to_sprint validated against canonical slug regex.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source scripts/lib/atomic-state.sh
# shellcheck disable=SC1091
source scripts/lib/sub-step.sh
# shellcheck disable=SC1091
source scripts/lib/bypass.sh

SLUG="${SPRINT_SLUG_OVERRIDE:-}"
MODE="interactive"
FINDING_ID=""
ACTION=""
TO_SPRINT=""
AC_ID=""
RISK_OWNER=""
RATIONALE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --status) MODE="status"; shift ;;
    --finding) MODE="programmatic"; FINDING_ID="$2"; ACTION="$3"; shift 3 ;;
    --to-sprint) TO_SPRINT="$2"; shift 2 ;;
    --ac-id) AC_ID="$2"; shift 2 ;;
    --risk-owner) RISK_OWNER="$2"; shift 2 ;;
    --rationale) RATIONALE="$2"; shift 2 ;;
    *) echo "[review-resolve] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SLUG" ]; then
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi
if [ -z "$SLUG" ] || ! [[ "$SLUG" =~ ^[a-z0-9-]{3,64}$ ]]; then
  echo "[review-resolve] invalid or missing slug: $SLUG" >&2
  exit 2
fi

SPRINT_DIR="docs/sprints/$SLUG"
STATE="$SPRINT_DIR/state.json"
RESOLUTIONS_MD="$SPRINT_DIR/review-resolutions.md"
TEMPLATE_NEW="docs/sprints/_templates/review-resolutions.md"
TEMPLATE_LEGACY="docs/sprints/_templates/audit-resolutions.md"

# Aggregate review_findings[] from worker-output/{audit,knip,sonar}.json
init_review_findings() {
  local total_in_state
  total_in_state=$(jq -r '.review_findings_total // -1' "$STATE")
  if [ "$total_in_state" -ge 0 ]; then return 0; fi

  local idx=0
  local findings='[]'

  # Audit producer
  if [ -f "$SPRINT_DIR/worker-output/audit.json" ] && jq empty "$SPRINT_DIR/worker-output/audit.json" 2>/dev/null; then
    while IFS= read -r vuln; do
      [ -z "$vuln" ] && continue
      idx=$((idx + 1))
      local entry
      entry=$(jq -n --arg p "audit" --arg id "HAR-$idx" --argjson v "$vuln" \
        '{producer:$p, har_id:$id, severity:($v.severity // "?"), file:($v.file // ""), line:($v.line // "?"), description:($v.description // "")}')
      findings=$(jq --argjson e "$entry" '. + [$e]' <<< "$findings")
    done <<< "$(jq -c '(.findings.vulnerabilities // .vulnerabilities // [])[]' "$SPRINT_DIR/worker-output/audit.json" 2>/dev/null)"
  fi

  # Knip producer
  if [ -f "$SPRINT_DIR/worker-output/knip.json" ] && jq empty "$SPRINT_DIR/worker-output/knip.json" 2>/dev/null; then
    while IFS= read -r kf; do
      [ -z "$kf" ] && continue
      idx=$((idx + 1))
      local entry
      entry=$(jq -n --arg p "knip" --arg id "HAR-$idx" --argjson v "$kf" \
        '{producer:$p, har_id:$id, severity:($v.severity // "medium"), file:($v.file // ""), line:($v.line // "?"), description:($v.reason // $v.symbol // "")}')
      findings=$(jq --argjson e "$entry" '. + [$e]' <<< "$findings")
    done <<< "$(jq -c '.findings[]?' "$SPRINT_DIR/worker-output/knip.json" 2>/dev/null)"
  fi

  # Sonar producer
  if [ -f "$SPRINT_DIR/worker-output/sonar.json" ] && jq empty "$SPRINT_DIR/worker-output/sonar.json" 2>/dev/null; then
    while IFS= read -r sf; do
      [ -z "$sf" ] && continue
      idx=$((idx + 1))
      local entry
      entry=$(jq -n --arg p "sonar" --arg id "HAR-$idx" --argjson v "$sf" \
        '{producer:$p, har_id:$id, severity:($v.severity // "?"), file:($v.file // ""), line:($v.line // "?"), description:($v.message // $v.rule // "")}')
      findings=$(jq --argjson e "$entry" '. + [$e]' <<< "$findings")
    done <<< "$(jq -c '.findings[]?' "$SPRINT_DIR/worker-output/sonar.json" 2>/dev/null)"
  fi

  local total=$idx
  atomic_update_state "$SLUG" --argjson f "$findings" --argjson t "$total" \
    '.review_findings = $f | .review_findings_total = $t | .review_findings_resolved_count = 0 | .review_findings_deferred = [] | .review_findings_accepted = []'
  echo "[review-resolve] initialized review_findings_total=$total (audit + knip + sonar union)" >&2

  if [ ! -f "$RESOLUTIONS_MD" ]; then
    local tpl="$TEMPLATE_NEW"
    [ ! -f "$tpl" ] && tpl="$TEMPLATE_LEGACY"
    if [ -f "$tpl" ]; then
      sed "s|<slug>|$SLUG|g; s|<iso-timestamp>|$(date -u +%FT%TZ)|; s|<total>|$total|" "$tpl" > "$RESOLUTIONS_MD"
      echo "[review-resolve] seeded $RESOLUTIONS_MD from $tpl" >&2
    fi
  fi
}

[ -d "$SPRINT_DIR" ] || { echo "[review-resolve] sprint dir not found: $SPRINT_DIR" >&2; exit 2; }
init_review_findings

total=$(jq -r '.review_findings_total' "$STATE")
resolved=$(jq -r '.review_findings_resolved_count' "$STATE")
deferred_count=$(jq -r '.review_findings_deferred | length' "$STATE")
accepted_count=$(jq -r '.review_findings_accepted | length' "$STATE")
remaining=$((total - resolved - deferred_count - accepted_count))
audit_count=$(jq -r '[.review_findings[]? | select(.producer == "audit")] | length' "$STATE")
knip_count=$(jq -r '[.review_findings[]? | select(.producer == "knip")] | length' "$STATE")
sonar_count=$(jq -r '[.review_findings[]? | select(.producer == "sonar")] | length' "$STATE")

if [ "$MODE" = "status" ]; then
  echo "Review Resolution Status for $SLUG:"
  echo "  Total findings:       $total (audit:$audit_count knip:$knip_count sonar:$sonar_count)"
  echo "  Resolved:             $resolved"
  echo "  Deferred:             $deferred_count"
  echo "  Accepted:             $accepted_count"
  echo "  Remaining:            $remaining"
  if [ "$remaining" -eq 0 ] && [ "$total" -gt 0 ]; then
    echo "  Status: ✓ all triaged"
  elif [ "$total" -eq 0 ]; then
    echo "  Status: ✓ no findings (vacuous PASS)"
  else
    echo "  Status: ⏳ $remaining remaining"
  fi
  exit 0
fi

redact() {
  local text="$1"
  if [ -x scripts/sprint-pii-redact.sh ]; then
    printf '%s' "$text" | bash scripts/sprint-pii-redact.sh 2>/dev/null || printf '%s' "$text"
  else
    printf '%s' "$text"
  fi
}

get_finding() {
  local har_id="$1"
  jq -r --arg id "$har_id" '.review_findings[] | select(.har_id == $id)' "$STATE"
}

record_fix() {
  local har_id="$1"
  local finding; finding=$(get_finding "$har_id")
  [ -z "$finding" ] && { echo "[review-resolve] $har_id not in review_findings" >&2; return 1; }
  if bash scripts/sprint-review-rerun.sh --slug "$SLUG" 2>&1 | tail -5; then
    atomic_update_state "$SLUG" '.review_findings_resolved_count += 1'
    record_sub_step "$SLUG" "review-finding-${har_id}-resolved" pass
    echo "[review-resolve] ✓ $har_id FIXED"
  else
    record_sub_step "$SLUG" "review-finding-${har_id}-resolved" fail
    return 1
  fi
}

record_defer() {
  local har_id="$1" to_sprint="$2" ac="$3" rationale="$4"
  if [ -z "$to_sprint" ] || [ -z "$ac" ]; then
    echo "[review-resolve] defer requires --to-sprint AND --ac-id" >&2; return 2
  fi
  # C7: validate canonical slug regex
  if ! [[ "$to_sprint" =~ ^[a-z0-9-]{3,64}$ ]]; then
    echo "[review-resolve] defer --to-sprint invalid: must match ^[a-z0-9-]{3,64}\$" >&2; return 2
  fi
  local finding; finding=$(get_finding "$har_id")
  [ -z "$finding" ] && { echo "[review-resolve] $har_id not in review_findings" >&2; return 1; }
  local redacted; redacted=$(redact "$rationale")
  local at; at=$(date -u +%FT%TZ)
  local entry
  entry=$(jq -n --argjson f "$finding" --arg s "$to_sprint" --arg a "$ac" --arg r "$redacted" --arg t "$at" \
    '$f + {deferred_to_sprint:$s, ac_id:$a, rationale:$r, deferred_at:$t}')
  atomic_update_state "$SLUG" --argjson e "$entry" '.review_findings_deferred += [$e]'
  record_sub_step "$SLUG" "review-finding-${har_id}-deferred" pass
  echo "[review-resolve] ⏸ $har_id DEFERRED to $to_sprint/$ac (producer: $(echo "$finding" | jq -r .producer))"
}

record_accept() {
  local har_id="$1" risk_owner="$2" rationale="$3"
  if [ -z "$risk_owner" ] || [ -z "$rationale" ]; then
    echo "[review-resolve] accept requires --risk-owner AND --rationale" >&2; return 2
  fi
  local finding; finding=$(get_finding "$har_id")
  [ -z "$finding" ] && { echo "[review-resolve] $har_id not in review_findings" >&2; return 1; }
  local redacted; redacted=$(redact "$rationale")
  local at; at=$(date -u +%FT%TZ)
  local entry
  entry=$(jq -n --argjson f "$finding" --arg o "$risk_owner" --arg r "$redacted" --arg t "$at" \
    '$f + {risk_owner:$o, business_rationale:$r, accepted_at:$t}')
  atomic_update_state "$SLUG" --argjson e "$entry" '.review_findings_accepted += [$e]'
  record_sub_step "$SLUG" "review-finding-${har_id}-accepted" pass
  echo "[review-resolve] ⚠ $har_id ACCEPTED (risk owner: $risk_owner, producer: $(echo "$finding" | jq -r .producer))"
}

if [ "$MODE" = "programmatic" ]; then
  case "$ACTION" in
    fix) record_fix "$FINDING_ID" ;;
    defer) record_defer "$FINDING_ID" "$TO_SPRINT" "$AC_ID" "$RATIONALE" ;;
    accept) record_accept "$FINDING_ID" "$RISK_OWNER" "$RATIONALE" ;;
    *) echo "[review-resolve] unknown action: $ACTION" >&2; exit 2 ;;
  esac
  exit $?
fi

# Vacuous PASS
if [ "$total" -eq 0 ]; then
  echo "[review-resolve] ✓ no findings — vacuous PASS"
  record_sub_step "$SLUG" "review-resolution-fired" pass
  record_sub_step "$SLUG" "review-findings-exit-predicate" pass
  exit 0
fi

echo "[review-resolve] Interactive mode not exercised in autopilot smoke. Use --finding HAR-N action for programmatic triage."
exit 0
