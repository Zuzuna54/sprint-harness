#!/usr/bin/env bash
# worker-gates.sh — sprint-verify gate logic for daemon worker outputs.
#
# Two gates wired into sprint-verify.sh:
#   - gate_audit_blocks    — exits 1 if audit found ANY vulnerability (Q2 zero-tolerance)
#   - gate_testgaps_blocks — exits 1 if testgaps reports an untested route in
#                            spec's `## Files touched` (Q3 scope-bounded)
#
# optimize is advisory-only — its output is surfaced in dashboard.html but
# never blocks. See sprint-verify.sh for orchestration.
#
# Usage:
#   source scripts/lib/worker-gates.sh
#   gate_audit_blocks docs/sprints/<slug>/worker-output/audit.json
#   gate_testgaps_blocks docs/sprints/<slug>/worker-output/testgaps.md <slug>

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _worker_gates_self="${BASH_SOURCE[0]}"
else
  _worker_gates_self="$0"
fi
_worker_gates_dir="$(cd "$(dirname "$_worker_gates_self")" && pwd)"
_gates_repo_root="$(cd "$_worker_gates_dir/../.." && pwd)"

# Q2 — audit blocks on ANY finding regardless of severity.
# Audit worker output schema (from headless-worker-executor.js):
#   { "vulnerabilities": [{ "severity": "high|medium|low", "file": "...", ... }],
#     "riskScore": 0-100,
#     "recommendations": ["..."] }
gate_audit_blocks() {
  local audit_json="${1:-}"
  if [ -z "$audit_json" ] || [ ! -f "$audit_json" ]; then
    echo "[gate-audit] no audit output at $audit_json — skipping gate (advisory pass)" >&2
    return 0
  fi
  if ! jq empty "$audit_json" 2>/dev/null; then
    echo "[gate-audit] audit output is not valid JSON: $audit_json" >&2
    return 1
  fi
  local count
  count="$(jq -r '.vulnerabilities // [] | length' "$audit_json" 2>/dev/null || echo 0)"
  if [ "$count" -gt 0 ]; then
    echo "[gate-audit] ✗ BLOCK — audit found $count vulnerabilities (zero-tolerance per Q2)" >&2
    jq -r '.vulnerabilities[] | "  [\(.severity)] \(.file):\(.line // "?") — \(.description)"' "$audit_json" 2>/dev/null | head -20 >&2
    return 1
  fi
  echo "[gate-audit] ✓ PASS — no audit findings" >&2
  return 0
}

# Q3 — testgaps blocks if any route IN spec's `## Files touched` has zero
# coverage in testgaps output. Routes outside files-touched are advisory.
#
# Testgaps worker output is Markdown (per executor.js outputFormat). We
# accept either:
#   (a) markdown — parse with grep for `Untested:` or coverage table rows
#   (b) JSON envelope with .untested_routes[] — preferred if available
gate_testgaps_blocks() {
  local testgaps_out="${1:-}"
  local slug="${2:-}"
  if [ -z "$testgaps_out" ] || [ -z "$slug" ]; then
    echo "[gate-testgaps] usage: gate_testgaps_blocks <output-file> <slug>" >&2
    return 2
  fi
  if [ ! -f "$testgaps_out" ]; then
    echo "[gate-testgaps] no testgaps output at $testgaps_out — skipping gate (advisory pass)" >&2
    return 0
  fi

  # Extract files-touched from spec.md.
  local spec_file="$_gates_repo_root/docs/sprints/$slug/spec.md"
  if [ ! -f "$spec_file" ]; then
    echo "[gate-testgaps] spec.md missing for $slug; skipping gate" >&2
    return 0
  fi
  # Pull the `## Files touched` section into a tmpfile.
  local files_touched
  files_touched="$(awk '/^## Files touched/,/^## /' "$spec_file" \
    | grep -oE '`[^`]+\.(ts|tsx|mjs|js|sh|cjs|sql)`|^- [^[:space:]]+\.(ts|tsx|mjs|js|sh|cjs|sql)' \
    | tr -d '`' | sed 's/^- //' | sort -u)"

  if [ -z "$files_touched" ]; then
    echo "[gate-testgaps] ✓ PASS — no files in spec ## Files touched (vacuously)" >&2
    return 0
  fi

  # Look for untested-route markers in testgaps output that match a file
  # in files-touched.
  local violations=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local base
    base="$(basename "$file")"
    if grep -qE "(untested|no test|missing test|0 tests).*${base}" "$testgaps_out" 2>/dev/null; then
      echo "[gate-testgaps] ✗ $file flagged as untested by testgaps" >&2
      violations=$((violations + 1))
    fi
  done <<< "$files_touched"

  if [ "$violations" -gt 0 ]; then
    echo "[gate-testgaps] ✗ BLOCK — $violations untested routes in files-touched (Q3)" >&2
    return 1
  fi
  echo "[gate-testgaps] ✓ PASS — all files-touched have test coverage" >&2
  return 0
}

# Optimize is advisory — never blocks. Just log a summary.
gate_optimize_advisory() {
  local optimize_out="${1:-}"
  if [ -z "$optimize_out" ] || [ ! -f "$optimize_out" ]; then
    echo "[gate-optimize] no optimize output (advisory only — pass)" >&2
    return 0
  fi
  local lines
  lines="$(wc -l < "$optimize_out" 2>/dev/null || echo 0)"
  echo "[gate-optimize] ✓ advisory — $lines lines of suggestions at $optimize_out" >&2
  return 0
}
