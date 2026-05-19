#!/usr/bin/env bash
# apply-ruflo-trigger-race.sh — apply the ruflo trigger race patch idempotently.
#
# Patches `ruflo daemon trigger` to await async init before firing the
# worker, so headless mode (real Claude calls) is correctly selected
# instead of falling through to local stubs.
#
# Run after every `npm i -g ruflo` to re-apply (the patch is to a file
# inside global node_modules, which npm overwrites on reinstall).
#
# Detects existing patch via the "LIFEOS PATCH 2026-05-19" sentinel
# comment, so re-running is safe.
#
# Usage:
#   bash scripts/patches/apply-ruflo-trigger-race.sh
#
# Exit 0: patch applied or already present.
# Exit 1: target file not found, or patch failed to apply.

set -euo pipefail

# Locate the target. Prefer Homebrew npm global; fall back to other locations.
TARGET=""
for candidate in \
  /opt/homebrew/lib/node_modules/ruflo/node_modules/@claude-flow/cli/dist/src/commands/daemon.js \
  /usr/local/lib/node_modules/ruflo/node_modules/@claude-flow/cli/dist/src/commands/daemon.js \
  "$HOME/.local/share/nvm/versions"/*/lib/node_modules/ruflo/node_modules/@claude-flow/cli/dist/src/commands/daemon.js; do
  if [ -f "$candidate" ]; then
    TARGET="$candidate"
    break
  fi
done

if [ -z "$TARGET" ]; then
  echo "[!] ruflo daemon.js not found in known npm global locations" >&2
  echo "    Search: /opt/homebrew, /usr/local, ~/.local/share/nvm/*" >&2
  exit 1
fi

echo "[apply-patch] target: $TARGET"

# Idempotency check: sentinel comment from the patch.
if grep -q "LIFEOS PATCH 2026-05-19" "$TARGET"; then
  echo "[apply-patch] ✓ already applied (LIFEOS PATCH 2026-05-19 sentinel present)"
  exit 0
fi

# Apply the patch via in-place edit. Anchor: the existing line
# `const daemon = getDaemon(process.cwd());` inside the trigger handler.
# Append our await-isAvailable block after the daemon construction.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

awk '
  /const daemon = getDaemon\(process\.cwd\(\)\);/ && !patched {
    print
    print "            // LIFEOS PATCH 2026-05-19: await headless executor`s async init so"
    print "            // triggerWorker() sees headlessAvailable=true. Without this, the"
    print "            // ephemeral daemon instance fires triggerWorker before its async"
    print "            // initHeadlessExecutor() resolves and always falls back to local"
    print "            // mode. Race documented in headless-worker-executor.js + worker-"
    print "            // daemon.js line 95. Re-apply after `npm i -g ruflo`. ~3 LOC."
    print "            if (daemon && daemon.headlessExecutor && typeof daemon.headlessExecutor.isAvailable === `function`) {"
    print "                try { daemon.headlessAvailable = await daemon.headlessExecutor.isAvailable(); } catch {}"
    print "            }"
    patched = 1
    next
  }
  { print }
' "$TARGET" > "$TMP"

if ! grep -q "LIFEOS PATCH 2026-05-19" "$TMP"; then
  echo "[apply-patch] ✗ awk transform did not inject the sentinel — anchor missed" >&2
  echo "    Inspect $TARGET around line 737 manually." >&2
  exit 1
fi

# Validate the result is still parseable Node before swapping.
if ! node --check "$TMP" 2>/dev/null; then
  echo "[apply-patch] ✗ patched file fails node --check — refusing to swap" >&2
  exit 1
fi

cp "$TARGET" "$TARGET.bak"
mv "$TMP" "$TARGET"
echo "[apply-patch] ✓ patch applied (backup at $TARGET.bak)"
echo "    Smoke test:  ruflo daemon trigger -w audit"
echo "    Expect:      .mode == 'headless' in .claude-flow/metrics/security-audit.json"
