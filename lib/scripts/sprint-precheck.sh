#!/usr/bin/env bash
# sprint-precheck.sh — Verify sprint-harness dependencies are healthy.
#
# AC-33 (sprint-system-100): used at sprint-start (BLOCK if critical down)
# and sprint-end (WARN + log to retro). Writes systems-health.json per sprint.
#
# Usage:
#   bash scripts/sprint-precheck.sh [<slug>] [--mode start|end] [--strict]
#
# Exit codes (--strict only):
#   0 = all critical OK
#   1 = critical component down (daemon or memory.db)
#   2 = warnings only

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG=""
MODE="start"
STRICT=false

# Parse args: first non-flag is slug; rest are flags
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)   shift; MODE="${1:-start}" ;;
    --strict) STRICT=true ;;
    *)        [ -z "$SLUG" ] && SLUG="$1" ;;
  esac
  shift
done

# Auto-detect slug
[ -z "$SLUG" ] && SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
REPORT_JSON=""
[ -n "$SLUG" ] && [ -d "docs/sprints/$SLUG" ] && REPORT_JSON="docs/sprints/$SLUG/systems-health.json"

CRITICAL_FAIL=0
WARN_COUNT=0

# Per-check vars (1=ok, 0=fail)
CHECK_DAEMON_OK=0;     CHECK_DAEMON_DETAIL=""
CHECK_MCP_OK=0;        CHECK_MCP_DETAIL=""
CHECK_MEMDB_OK=0;      CHECK_MEMDB_DETAIL=""
CHECK_DECAY_OK=0;      CHECK_DECAY_DETAIL=""
CHECK_GRAPHIFY_OK=0;   CHECK_GRAPHIFY_DETAIL=""
CHECK_HUSKY_OK=0;      CHECK_HUSKY_DETAIL=""

# ── 1. ruflo daemon ─────────────────────────────────────────────────────────
if command -v ruflo >/dev/null 2>&1; then
  if ruflo daemon status 2>/dev/null | grep -q "RUNNING"; then
    CHECK_DAEMON_OK=1
    CHECK_DAEMON_DETAIL="running"
  else
    CHECK_DAEMON_DETAIL="STOPPED — start with: ruflo daemon start"
    CRITICAL_FAIL=1
  fi
else
  CHECK_DAEMON_DETAIL="ruflo CLI not installed"
  CRITICAL_FAIL=1
fi

# ── 2. ruflo MCP server ─────────────────────────────────────────────────────
if command -v ruflo >/dev/null 2>&1; then
  if ruflo mcp status 2>/dev/null | grep -qiE "running|active|listening|started"; then
    CHECK_MCP_OK=1
    CHECK_MCP_DETAIL="running"
  else
    CHECK_MCP_DETAIL="not responding — restart via: ruflo mcp start"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
else
  CHECK_MCP_DETAIL="ruflo CLI missing"
fi

# ── 3. memory.db ────────────────────────────────────────────────────────────
if [ -f .swarm/memory.db ] && command -v sqlite3 >/dev/null 2>&1; then
  MEM_COUNT="$(sqlite3 .swarm/memory.db 'SELECT count(*) FROM memory_entries;' 2>/dev/null || echo 0)"
  if [ "$MEM_COUNT" -gt 0 ]; then
    CHECK_MEMDB_OK=1
    CHECK_MEMDB_DETAIL="$MEM_COUNT entries"
  else
    CHECK_MEMDB_DETAIL="memory.db empty"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
else
  CHECK_MEMDB_DETAIL=".swarm/memory.db not found or sqlite3 missing"
  CRITICAL_FAIL=1
fi

# ── 4. launchd memory-decay ─────────────────────────────────────────────────
# Avoid `| grep -q` here: with `set -o pipefail`, grep's early-exit causes
# launchctl to SIGPIPE (rc=141) → false negative. Capture first, then test.
LAUNCHCTL_OUT="$(launchctl list 2>/dev/null || true)"
if printf '%s\n' "$LAUNCHCTL_OUT" | grep -q "com.lifeos.sprint-memory-decay"; then
  CHECK_DECAY_OK=1
  CHECK_DECAY_DETAIL="registered"
else
  CHECK_DECAY_DETAIL="not registered — run: bash scripts/launchd/install-memory-decay.sh"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ── 5. graphify-out ─────────────────────────────────────────────────────────
if [ -f graphify-out/GRAPH_REPORT.md ]; then
  CHECK_GRAPHIFY_OK=1
  CHECK_GRAPHIFY_DETAIL="present"
else
  CHECK_GRAPHIFY_DETAIL="missing — run: pnpm graphify:rebuild"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ── 6. husky hooks ──────────────────────────────────────────────────────────
HOOK_COUNT=0
for h in pre-commit post-commit; do
  [ -x ".husky/$h" ] && HOOK_COUNT=$((HOOK_COUNT + 1))
done
if [ "$HOOK_COUNT" -eq 2 ]; then
  CHECK_HUSKY_OK=1
  CHECK_HUSKY_DETAIL="pre-commit + post-commit installed"
else
  CHECK_HUSKY_DETAIL="found $HOOK_COUNT of 2 hooks"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ── Print summary ───────────────────────────────────────────────────────────
echo "═══ Sprint precheck ($MODE mode) ═══"
[ -n "$SLUG" ] && echo "  Sprint: $SLUG"
echo ""
printf "  %s %-22s %s\n" "$([ $CHECK_DAEMON_OK -eq 1 ] && echo '✓' || echo '✗')"   "daemon"            "$CHECK_DAEMON_DETAIL"
printf "  %s %-22s %s\n" "$([ $CHECK_MCP_OK -eq 1 ] && echo '✓' || echo '✗')"      "mcp"               "$CHECK_MCP_DETAIL"
printf "  %s %-22s %s\n" "$([ $CHECK_MEMDB_OK -eq 1 ] && echo '✓' || echo '✗')"    "memory_db"         "$CHECK_MEMDB_DETAIL"
printf "  %s %-22s %s\n" "$([ $CHECK_DECAY_OK -eq 1 ] && echo '✓' || echo '✗')"    "memory_decay_cron" "$CHECK_DECAY_DETAIL"
printf "  %s %-22s %s\n" "$([ $CHECK_GRAPHIFY_OK -eq 1 ] && echo '✓' || echo '✗')" "graphify"          "$CHECK_GRAPHIFY_DETAIL"
printf "  %s %-22s %s\n" "$([ $CHECK_HUSKY_OK -eq 1 ] && echo '✓' || echo '✗')"    "husky_hooks"       "$CHECK_HUSKY_DETAIL"
echo ""

# ── Write JSON report ───────────────────────────────────────────────────────
if [ -n "$REPORT_JSON" ]; then
  cat > "$REPORT_JSON" <<JSON
{
  "checked_at": "$NOW_ISO",
  "mode": "$MODE",
  "critical_fail": $CRITICAL_FAIL,
  "warn_count": $WARN_COUNT,
  "checks": {
    "daemon":            { "ok": $CHECK_DAEMON_OK,   "detail": "$CHECK_DAEMON_DETAIL" },
    "mcp":               { "ok": $CHECK_MCP_OK,      "detail": "$CHECK_MCP_DETAIL" },
    "memory_db":         { "ok": $CHECK_MEMDB_OK,    "detail": "$CHECK_MEMDB_DETAIL" },
    "memory_decay_cron": { "ok": $CHECK_DECAY_OK,    "detail": "$CHECK_DECAY_DETAIL" },
    "graphify":          { "ok": $CHECK_GRAPHIFY_OK, "detail": "$CHECK_GRAPHIFY_DETAIL" },
    "husky_hooks":       { "ok": $CHECK_HUSKY_OK,    "detail": "$CHECK_HUSKY_DETAIL" }
  }
}
JSON
  echo "  Report: $REPORT_JSON"
fi

# ── Decision ────────────────────────────────────────────────────────────────
if [ "$STRICT" = "true" ] && [ "$CRITICAL_FAIL" -eq 1 ]; then
  echo ""
  echo "[!] CRITICAL component(s) down. Use SPRINT_PRECHECK_BYPASS=1 to override (logged)."
  if [ "${SPRINT_PRECHECK_BYPASS:-0}" = "1" ]; then
    echo "[i] BYPASS=1 — proceeding (logging to state.gate_bypasses[])."
    ACTIVE_SLUG=$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)
    if [ -n "$ACTIVE_SLUG" ] && command -v jq >/dev/null 2>&1; then
      SF="docs/sprints/$ACTIVE_SLUG/state.json"
      if [ -f "$SF" ]; then
        tmp=$(mktemp)
        jq --arg at "$(date -u +%FT%TZ)" \
          '.gate_bypasses = ((.gate_bypasses // []) + [{gate:"precheck", at:$at, reason:"SPRINT_PRECHECK_BYPASS=1"}])' \
          "$SF" > "$tmp" && mv "$tmp" "$SF"
      fi
    fi
    exit 0
  fi
  exit 1
fi

if [ "$WARN_COUNT" -gt 0 ] && [ "$STRICT" = "true" ]; then
  exit 2
fi

exit 0
