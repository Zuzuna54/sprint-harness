#!/usr/bin/env bash
# sprint-workers-shim.sh — Run the substitutes for ruflo's missing daemon workers.
#
# ────────────────────────────────────────────────────────────────────────────
# Installed by launchctl via scripts/launchd/com.<BRAND_SLUG>.sprint-workers-shim.plist.
# Fires hourly when registered. To install:
#   launchctl bootstrap gui/$(id -u) scripts/launchd/com.<BRAND_SLUG>.sprint-workers-shim.plist
# To remove:
#   launchctl bootout gui/$(id -u)/com.<BRAND_SLUG>.sprint-workers-shim
# ────────────────────────────────────────────────────────────────────────────
#
# Ruflo v3.7.0-alpha.44 only implements 7 of 12 documented workers. This shim
# runs OUR substitutes for the missing ones on the same cadence the missing
# workers would have run at. Driven by launchd (macOS) or cron (Linux).
#
# Missing workers + our substitutes:
#   ultralearn  (1h)  → scripts/sprint-memory-decay.mjs (continuous pattern aging)
#   deepdive    (4h)  → pnpm graphify:rebuild         (architecture map refresh)
#   refactor    (2h)  → INTENTIONALLY SKIPPED         (drift risk during sprint)
#   benchmark   (4h)  → SKIPPED                       (perf-bar-check runs at verify)
#   preload     (30m) → SKIPPED                       (imperceptible perf benefit)
#
# Usage:
#   bash scripts/sprint-workers-shim.sh ultralearn
#   bash scripts/sprint-workers-shim.sh deepdive
#   bash scripts/sprint-workers-shim.sh all          # run both
#   bash scripts/sprint-workers-shim.sh install      # install launchd plist (macOS)
#   bash scripts/sprint-workers-shim.sh uninstall    # remove launchd plist
#   bash scripts/sprint-workers-shim.sh status       # show install state + last run

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ACTION="${1:-}"
LOG_DIR="$REPO_ROOT/.claude-flow/shim-logs"
mkdir -p "$LOG_DIR"

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
PLIST_ULTRALEARN="$LAUNCHD_DIR/com.<BRAND_SLUG>.sprint.ultralearn-shim.plist"
PLIST_DEEPDIVE="$LAUNCHD_DIR/com.<BRAND_SLUG>.sprint.deepdive-shim.plist"

# ── Worker substitute runners ────────────────────────────────────────────────

run_ultralearn() {
  local LOG="$LOG_DIR/ultralearn-$(date +%Y%m%d).log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ultralearn-shim → sprint-memory-decay.mjs" >> "$LOG"
  node "$REPO_ROOT/scripts/sprint-memory-decay.mjs" >> "$LOG" 2>&1
  local rc=$?
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ultralearn-shim done (exit $rc)" >> "$LOG"
  return $rc
}

run_deepdive() {
  local LOG="$LOG_DIR/deepdive-$(date +%Y%m%d).log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] deepdive-shim → pnpm graphify:rebuild" >> "$LOG"
  # Only run if no sprint is in active build phase (avoid stomping)
  if [ -x "$REPO_ROOT/scripts/sprint-status.sh" ]; then
    PHASE="$(bash "$REPO_ROOT/scripts/sprint-status.sh" --json 2>/dev/null | grep -oE '"phase":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || echo "")"
    if [ "$PHASE" = "building" ] || [ "$PHASE" = "verifying" ] || [ "$PHASE" = "deploying" ]; then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] skipped — active sprint phase=$PHASE" >> "$LOG"
      return 0
    fi
  fi
  cd "$REPO_ROOT" && pnpm graphify:rebuild >> "$LOG" 2>&1
  local rc=$?
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] deepdive-shim done (exit $rc)" >> "$LOG"
  return $rc
}

# ── launchd installer (macOS) ────────────────────────────────────────────────

install_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "[!] launchd install only supported on macOS. Use cron on Linux."
    return 2
  fi
  mkdir -p "$LAUNCHD_DIR"

  cat > "$PLIST_ULTRALEARN" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.<BRAND_SLUG>.sprint.ultralearn-shim</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$REPO_ROOT/scripts/sprint-workers-shim.sh</string>
    <string>ultralearn</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/ultralearn-launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/ultralearn-launchd.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO_ROOT</string>
</dict>
</plist>
EOF

  cat > "$PLIST_DEEPDIVE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.<BRAND_SLUG>.sprint.deepdive-shim</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$REPO_ROOT/scripts/sprint-workers-shim.sh</string>
    <string>deepdive</string>
  </array>
  <key>StartInterval</key>
  <integer>14400</integer>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/deepdive-launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/deepdive-launchd.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO_ROOT</string>
</dict>
</plist>
EOF

  launchctl unload "$PLIST_ULTRALEARN" 2>/dev/null || true
  launchctl unload "$PLIST_DEEPDIVE" 2>/dev/null || true
  launchctl load -w "$PLIST_ULTRALEARN"
  launchctl load -w "$PLIST_DEEPDIVE"

  echo "[+] Installed launchd shim agents:"
  echo "    - com.<BRAND_SLUG>.sprint.ultralearn-shim (every 1h, runs memory-decay)"
  echo "    - com.<BRAND_SLUG>.sprint.deepdive-shim   (every 4h, runs graphify:rebuild)"
  echo ""
  echo "Logs: $LOG_DIR"
  echo "Status: bash scripts/sprint-workers-shim.sh status"
  echo "Uninstall: bash scripts/sprint-workers-shim.sh uninstall"
}

uninstall_macos() {
  if [ -f "$PLIST_ULTRALEARN" ]; then
    launchctl unload "$PLIST_ULTRALEARN" 2>/dev/null || true
    rm -f "$PLIST_ULTRALEARN"
    echo "[+] Removed ultralearn-shim"
  fi
  if [ -f "$PLIST_DEEPDIVE" ]; then
    launchctl unload "$PLIST_DEEPDIVE" 2>/dev/null || true
    rm -f "$PLIST_DEEPDIVE"
    echo "[+] Removed deepdive-shim"
  fi
  echo "[+] Uninstall complete."
}

status() {
  echo "═══ Sprint workers shim status ═══"
  echo ""
  echo "Ruflo daemon (7 real workers):"
  if command -v ruflo >/dev/null 2>&1; then
    ruflo daemon status 2>&1 | sed -n '/Worker/,/Worker/p' | head -15 | sed 's/^/  /'
  fi
  echo ""
  echo "Shim agents (substitutes for missing 5 workers):"
  # NOTE: `launchctl list | grep` matches the LABEL column. The PID column shows
  # `-` when the agent is loaded but not currently running (waiting for next
  # interval) — that's normal for scheduled agents. We treat presence in the
  # output as "loaded".
  if [ -f "$PLIST_ULTRALEARN" ]; then
    LINE="$(launchctl list 2>/dev/null | awk '/com.<BRAND_SLUG>.sprint.ultralearn-shim/{print}')"
    if [ -n "$LINE" ]; then
      LAST="$(ls -t $LOG_DIR/ultralearn-*.log 2>/dev/null | head -1)"
      LAST_EXIT="$(echo "$LINE" | awk '{print $2}')"
      echo "  ✓ ultralearn-shim — loaded (cadence: 1h, last exit: $LAST_EXIT)"
      [ -n "$LAST" ] && echo "    last log: $LAST ($(stat -f '%Sm' "$LAST" 2>/dev/null || stat -c '%y' "$LAST" 2>/dev/null))"
    else
      echo "  ⚠ ultralearn-shim plist present but not registered with launchd"
      echo "    Try: launchctl load -w $PLIST_ULTRALEARN"
    fi
  else
    echo "  ✗ ultralearn-shim NOT installed (run: bash scripts/sprint-workers-shim.sh install)"
  fi
  if [ -f "$PLIST_DEEPDIVE" ]; then
    LINE="$(launchctl list 2>/dev/null | awk '/com.<BRAND_SLUG>.sprint.deepdive-shim/{print}')"
    if [ -n "$LINE" ]; then
      LAST="$(ls -t $LOG_DIR/deepdive-*.log 2>/dev/null | head -1)"
      LAST_EXIT="$(echo "$LINE" | awk '{print $2}')"
      echo "  ✓ deepdive-shim — loaded (cadence: 4h, last exit: $LAST_EXIT)"
      [ -n "$LAST" ] && echo "    last log: $LAST ($(stat -f '%Sm' "$LAST" 2>/dev/null || stat -c '%y' "$LAST" 2>/dev/null))"
    else
      echo "  ⚠ deepdive-shim plist present but not registered with launchd"
      echo "    Try: launchctl load -w $PLIST_DEEPDIVE"
    fi
  else
    echo "  ✗ deepdive-shim NOT installed"
  fi
  echo ""
  echo "Intentionally not shimmed: refactor (drift risk), benchmark (perf-bar-check), preload (imperceptible)"
}

# ── Dispatch ────────────────────────────────────────────────────────────────

case "$ACTION" in
  ultralearn)  run_ultralearn ;;
  deepdive)    run_deepdive ;;
  all)         run_ultralearn; run_deepdive ;;
  install)     install_macos ;;
  uninstall)   uninstall_macos ;;
  status)      status ;;
  ""|help|-h|--help)
    echo "Usage: $0 <ultralearn|deepdive|all|install|uninstall|status>"
    echo ""
    echo "Shim for ruflo's 5 missing daemon workers in v3.7.0-alpha.42-44."
    echo "  ultralearn / deepdive — run the substitute now"
    echo "  install               — schedule via launchd (macOS)"
    echo "  uninstall             — remove launchd agents"
    echo "  status                — show ruflo daemon + shim state"
    ;;
  *)
    echo "[!] Unknown action: $ACTION"
    exit 1
    ;;
esac
