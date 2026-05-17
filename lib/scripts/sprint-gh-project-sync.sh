#!/usr/bin/env bash
# sprint-gh-project-sync.sh — Sync sprint state to a GitHub Project (v2) board.
#
# Robust against gh CLI version variance (gap #30). Detects:
#   - gh installed + version
#   - auth status + required scopes (`project`, `read:project`)
#   - project create/list/item-create command availability
#
# Modes:
#   --check    : diagnostic — print what works without changing anything
#   --create   : create new project + add ACs as draft issues
#   --update   : update existing project items (best-effort)
#   --close    : close the project
#   (default)  : auto — create if missing, update if exists
#
# Usage:
#   bash scripts/sprint-gh-project-sync.sh [<slug>] [--check|--create|--update|--close]
#
# Exit codes:
#   0 = success (or no-op if --check shows blockers)
#   1 = something failed at sync time
#   2 = config error (no gh, no auth, missing scope)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG=""
MODE="auto"
for arg in "$@"; do
  case "$arg" in
    --check)   MODE="check" ;;
    --create)  MODE="create" ;;
    --update)  MODE="update" ;;
    --close)   MODE="close" ;;
    --*)       echo "[!] unknown flag: $arg" >&2 ;;
    *)         [ -z "$SLUG" ] && SLUG="$arg" ;;
  esac
done

if [ -z "$SLUG" ] && [ "$MODE" != "check" ]; then
  SLUG="$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)"
fi

# ── Diagnostic helpers ──────────────────────────────────────────────────────

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "  ✗ gh CLI not installed"
    echo "    Install: brew install gh"
    return 2
  fi
  local v
  v="$(gh --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  echo "  ✓ gh CLI installed: $v"
  return 0
}

check_auth() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "  ✗ gh not authenticated"
    echo "    Run: gh auth login"
    return 2
  fi
  echo "  ✓ gh authenticated"
}

check_scope() {
  # Need 'project' (read+write) scope for sync; 'read:project' for read-only
  local SCOPES
  SCOPES="$(gh auth status 2>&1 | grep -oE 'Token scopes:.*' | head -1 || true)"
  if echo "$SCOPES" | grep -qE "'(project|read:project)'"; then
    echo "  ✓ project scope granted"
    return 0
  fi
  echo "  ✗ project scope MISSING"
  echo "    Run: gh auth refresh -s project"
  echo "    (read-only alternative: gh auth refresh -s read:project)"
  return 2
}

check_commands() {
  # Verify the gh project subcommands we use exist
  local MISSING=0
  for sub in create list item-create close; do
    if gh project "$sub" --help >/dev/null 2>&1; then
      echo "  ✓ gh project $sub"
    else
      echo "  ✗ gh project $sub not available"
      MISSING=$((MISSING + 1))
    fi
  done
  return $MISSING
}

# ── Modes ────────────────────────────────────────────────────────────────────

case "$MODE" in
  check)
    echo "═══ gh project sync diagnostic ═══"
    echo ""
    echo "Tool:"
    require_gh || exit 0  # check mode shouldn't exit-fail
    echo ""
    echo "Auth:"
    check_auth || exit 0
    echo ""
    echo "Scopes:"
    check_scope || true  # warn-only in check mode
    echo ""
    echo "Commands:"
    check_commands || true
    echo ""
    echo "Repo:"
    if gh repo view >/dev/null 2>&1; then
      REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "?")"
      echo "  ✓ in a GitHub repo: $REPO"
    else
      echo "  ⚠ not inside a GitHub repo (script still works for personal projects)"
    fi
    echo ""
    echo "Existing sprint projects:"
    if gh project list --owner @me --limit 50 --format json 2>/dev/null | grep -q '"title":'; then
      gh project list --owner @me --limit 50 --format json 2>/dev/null | \
        grep -oE '"title":"Sprint:[^"]*"' | sed 's/^/  /' | head -10
    else
      echo "  (none or no project read access)"
    fi
    exit 0
    ;;
esac

# ── Non-check modes need the full toolkit ────────────────────────────────────

if [ -z "$SLUG" ]; then
  echo "[!] No active sprint and no slug given." >&2
  exit 2
fi

if ! require_gh >/dev/null 2>&1; then
  echo "[i] gh CLI not installed — skipping project sync (local dashboard still works)."
  exit 0
fi

if ! check_auth >/dev/null 2>&1; then
  echo "[i] gh not authenticated — skipping project sync."
  exit 0
fi

if ! check_scope >/dev/null 2>&1; then
  echo "[i] project scope missing — skipping project sync."
  echo "    To enable: gh auth refresh -s project"
  exit 0
fi

SPRINT_DIR="docs/sprints/$SLUG"
STATE_FILE="$SPRINT_DIR/state.json"
SPEC_FILE="$SPRINT_DIR/spec.md"
PROJECT_TITLE="Sprint: $SLUG"

if [ ! -f "$STATE_FILE" ]; then
  echo "[!] state.json missing: $STATE_FILE" >&2
  exit 1
fi

# Discover existing project by title
EXISTING_PROJECT_NUM=""
PROJECTS_JSON="$(gh project list --owner @me --limit 100 --format json 2>/dev/null || echo '{}')"
if command -v jq >/dev/null 2>&1; then
  EXISTING_PROJECT_NUM="$(echo "$PROJECTS_JSON" | jq -r ".projects[]? | select(.title == \"$PROJECT_TITLE\") | .number" 2>/dev/null | head -1)"
else
  # Fallback: grep approach
  if echo "$PROJECTS_JSON" | grep -q "\"title\":\"$PROJECT_TITLE\""; then
    EXISTING_PROJECT_NUM="$(echo "$PROJECTS_JSON" | grep -oE "\"title\":\"$PROJECT_TITLE\",\"number\":[0-9]+" | grep -oE "[0-9]+$" || true)"
  fi
fi

# Auto: create if missing, update if exists
if [ "$MODE" = "auto" ]; then
  if [ -z "$EXISTING_PROJECT_NUM" ]; then
    MODE="create"
  else
    MODE="update"
  fi
fi

case "$MODE" in
  create)
    if [ -n "$EXISTING_PROJECT_NUM" ]; then
      echo "[i] Project '$PROJECT_TITLE' already exists (#$EXISTING_PROJECT_NUM)."
      echo "    Use --update or --close."
      exit 0
    fi

    echo "[+] Creating GitHub Project: $PROJECT_TITLE"
    CREATE_OUT="$(gh project create --owner @me --title "$PROJECT_TITLE" --format json 2>&1)"
    if [ $? -ne 0 ]; then
      echo "[!] Failed: $CREATE_OUT" >&2
      exit 1
    fi

    if command -v jq >/dev/null 2>&1; then
      PROJECT_NUM="$(echo "$CREATE_OUT" | jq -r '.number' 2>/dev/null)"
    else
      PROJECT_NUM="$(echo "$CREATE_OUT" | grep -oE '"number":[0-9]+' | grep -oE '[0-9]+' | head -1)"
    fi

    if [ -z "$PROJECT_NUM" ] || [ "$PROJECT_NUM" = "null" ]; then
      echo "[!] Could not extract project number from create output." >&2
      exit 1
    fi

    # Persist project number in state
    if command -v jq >/dev/null 2>&1; then
      tmp="$(mktemp)"
      jq ".github_project = $PROJECT_NUM" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    fi

    echo "[+] Project created: #$PROJECT_NUM"
    echo "    Web: gh project view $PROJECT_NUM --owner @me --web"

    # Add each AC from spec as draft issue
    if [ -f "$SPEC_FILE" ]; then
      ADDED=0
      while IFS= read -r AC; do
        AC_ID="$(echo "$AC" | grep -oE 'AC-[0-9]+' | head -1)"
        [ -z "$AC_ID" ] && continue
        AC_TITLE="$AC_ID — $SLUG"
        gh project item-create "$PROJECT_NUM" --owner @me --title "$AC_TITLE" >/dev/null 2>&1 && \
          ADDED=$((ADDED + 1)) || true
      done < <(grep -E '^\*\*AC-[0-9]+\*\*' "$SPEC_FILE")
      echo "[+] Added $ADDED ACs as project items"
    fi
    ;;

  update)
    if [ -z "$EXISTING_PROJECT_NUM" ]; then
      echo "[!] No existing project for '$PROJECT_TITLE'. Use --create." >&2
      exit 1
    fi
    echo "[+] Updating project #$EXISTING_PROJECT_NUM"

    # List items, count
    ITEMS_JSON="$(gh project item-list "$EXISTING_PROJECT_NUM" --owner @me --limit 100 --format json 2>/dev/null || echo '{}')"
    if command -v jq >/dev/null 2>&1; then
      ITEM_COUNT="$(echo "$ITEMS_JSON" | jq '.items | length' 2>/dev/null || echo 0)"
    else
      ITEM_COUNT="$(echo "$ITEMS_JSON" | grep -oE '"id":' | wc -l | tr -d ' ')"
    fi
    echo "    Existing items: $ITEM_COUNT"

    # Add any new ACs not yet in project (best-effort by title match)
    if [ -f "$SPEC_FILE" ]; then
      ADDED=0
      while IFS= read -r AC; do
        AC_ID="$(echo "$AC" | grep -oE 'AC-[0-9]+' | head -1)"
        [ -z "$AC_ID" ] && continue
        AC_TITLE="$AC_ID — $SLUG"
        # Check if already present
        if echo "$ITEMS_JSON" | grep -qF "$AC_TITLE"; then
          continue
        fi
        gh project item-create "$EXISTING_PROJECT_NUM" --owner @me --title "$AC_TITLE" >/dev/null 2>&1 && \
          ADDED=$((ADDED + 1)) || true
      done < <(grep -E '^\*\*AC-[0-9]+\*\*' "$SPEC_FILE")
      echo "    Added $ADDED new ACs as items"
    fi

    echo "[+] Sync done."
    ;;

  close)
    if [ -z "$EXISTING_PROJECT_NUM" ]; then
      echo "[i] No project to close."
      exit 0
    fi
    gh project close "$EXISTING_PROJECT_NUM" --owner @me 2>&1 | head -3
    echo "[+] Project #$EXISTING_PROJECT_NUM closed."
    ;;
esac

echo ""
echo "[+] Done (mode: $MODE)"
