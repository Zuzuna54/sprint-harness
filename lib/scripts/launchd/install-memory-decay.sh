#!/usr/bin/env bash
# install-memory-decay.sh — Install or refresh the <BRAND_SLUG_TITLE> memory-decay cron.
#
# Copies scripts/launchd/com.<BRAND_SLUG>.sprint-memory-decay.plist into
# ~/Library/LaunchAgents/ and reloads it. Nightly at 02:00 local time,
# `sprint-memory-decay.mjs` decays unused pattern confidence in
# `.swarm/memory.db` so stale knowledge ages out automatically.
#
# AC-6 (sprint-system-100, Gap J).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/scripts/launchd/com.<BRAND_SLUG>.sprint-memory-decay.plist"
DEST="$HOME/Library/LaunchAgents/com.<BRAND_SLUG>.sprint-memory-decay.plist"

if [ ! -f "$SRC" ]; then
  echo "[!] Source plist not found: $SRC" >&2
  exit 1
fi

# Validate plist before installing
plutil -lint "$SRC" >/dev/null || {
  echo "[!] Plist failed lint: $SRC" >&2
  exit 1
}

mkdir -p "$HOME/Library/LaunchAgents"

# Unload old version if present (ignore errors — may not be loaded)
if launchctl list | grep -q com.<BRAND_SLUG>.sprint-memory-decay; then
  launchctl unload "$DEST" 2>/dev/null || true
fi

# Copy fresh plist
cp "$SRC" "$DEST"
echo "[+] Copied plist to $DEST"

# Load it
launchctl load "$DEST" 2>&1 || {
  echo "[!] launchctl load failed. Try: launchctl bootstrap gui/\$(id -u) \"$DEST\"" >&2
  exit 1
}

echo "[+] LaunchAgent loaded: com.<BRAND_SLUG>.sprint-memory-decay"
echo "    Schedule:  nightly 02:00"
echo "    Stdout:    $REPO_ROOT/.swarm/memory-decay.log"
echo "    Stderr:    $REPO_ROOT/.swarm/memory-decay.err"
echo ""
echo "Verify with:    launchctl list | grep <BRAND_SLUG>"
echo "Force run now:  launchctl start com.<BRAND_SLUG>.sprint-memory-decay"
echo "Uninstall:      launchctl unload \"$DEST\" && rm \"$DEST\""
