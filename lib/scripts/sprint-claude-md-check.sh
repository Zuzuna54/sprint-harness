#!/usr/bin/env bash
# sprint-claude-md-check.sh — Scan CLAUDE.md for stale references.
#
# Looks for file paths, function names, slash commands, etc. in CLAUDE.md
# and verifies they still exist in the repo. Flags any references to
# missing files/symbols.
#
# Usage: bash scripts/sprint-claude-md-check.sh [--all] [<slug>]
#   --all : scan all CLAUDE.md files (root + apps/web + apps/lambdas/*)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCAN_ALL=false
AUTO_FIX=false
SLUG=""
for arg in "$@"; do
  case "$arg" in
    --all) SCAN_ALL=true ;;
    --auto-fix) AUTO_FIX=true ;;  # AC-26: delete stale lines + commit
    --*) ;;
    *) [ -z "$SLUG" ] && SLUG="$arg" ;;
  esac
done

if [ "$SCAN_ALL" = true ]; then
  CLAUDE_FILES=$(find . -name "CLAUDE.md" -not -path "*/node_modules/*" -not -path "*/.turbo/*" -not -path "*/dist/*" -not -path "*/apps/web.OLD/*")
else
  CLAUDE_FILES="CLAUDE.md"
fi

STALE_COUNT=0
TOTAL_REFS=0
REPORT=""
# AC-26: collect stale paths to delete from CLAUDE.md when --auto-fix
STALE_PATHS_TO_REMOVE=""

for f in $CLAUDE_FILES; do
  [ -f "$f" ] || continue
  REPORT="$REPORT\n=== $f ===\n"

  # Extract file paths — MUST contain a directory separator (rules out type/var refs)
  # AND extension AND at least one / AND no shell glob chars
  PATHS=$(grep -oE '`[a-zA-Z0-9_./-]+/[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|md|json|sql|yaml|yml|sh|cjs|mjs)`' "$f" 2>/dev/null | \
            tr -d '`' | sort -u || true)
  for p in $PATHS; do
    # Skip globs, leading dots-only, or relative-only refs without dir
    if [[ "$p" == *"*"* ]] || [[ "$p" == *"\$"* ]] || [[ "$p" == "{"* ]]; then continue; fi
    # Skip if it looks like a fenced code-block sample (TypeScript snippet showing path-like strings)
    if [[ "$p" == "/"* ]] && [[ ! -e "$p" ]]; then continue; fi
    TOTAL_REFS=$((TOTAL_REFS + 1))
    # Check existence relative to repo root + relative to the CLAUDE.md file's dir
    if [ ! -e "$p" ] && [ ! -e "$(dirname "$f")/$p" ]; then
      STALE_COUNT=$((STALE_COUNT + 1))
      REPORT="$REPORT  ✗ STALE: $p\n"
      STALE_PATHS_TO_REMOVE="$STALE_PATHS_TO_REMOVE$p"$'\n'
    fi
  done

  # Extract slash commands (heuristic: /command-name in single line)
  SLASH_CMDS=$(grep -oE '`/[a-z-]+(:[a-z-]+)?`' "$f" 2>/dev/null | tr -d '`' | sort -u || true)
  for cmd in $SLASH_CMDS; do
    # Strip leading / and check if a matching skill or command exists
    CMD_NAME="${cmd#/}"

    # BUG 13 fix: whitelist Claude Code built-ins + global ~/.claude/skills/
    # commands that aren't in this repo. Without whitelist, these surface as
    # false-positive "stale" entries.
    case "$CMD_NAME" in
      # Claude Code built-ins
      clear|help|init|model|review|memory|exit|quit|config|status|continue|fast|slow|loop|schedule)
        continue ;;
      # Global skills (~/.claude/skills/)
      graphify|journal|todo|explain-code|verify-install)
        continue ;;
      # Anthropic-shipped slash commands
      security-review|review)
        continue ;;
    esac

    # Has colon? It's a namespaced command (e.g., /sparc:ask, /github:pr-manager)
    if [[ "$CMD_NAME" == *":"* ]]; then
      NS="${CMD_NAME%%:*}"
      NAME="${CMD_NAME#*:}"
      if [ ! -f ".claude/commands/$NS:$NAME.md" ] && [ ! -d ".claude/skills/sparc-$NAME" ]; then
        : # could be a sparc/github/etc subcommand — skip for now
      fi
    else
      # Plain command — check repo skills + commands + global skills
      if [ ! -f ".claude/commands/$CMD_NAME.md" ] && \
         [ ! -d ".claude/skills/$CMD_NAME" ] && \
         [ ! -d "$HOME/.claude/skills/$CMD_NAME" ]; then
        TOTAL_REFS=$((TOTAL_REFS + 1))
        STALE_COUNT=$((STALE_COUNT + 1))
        REPORT="$REPORT  ✗ STALE command: /$CMD_NAME\n"
      fi
    fi
  done
done

echo "CLAUDE.md staleness check"
echo "  Total references found: $TOTAL_REFS"
echo "  Stale references:       $STALE_COUNT"
echo ""

if [ "$STALE_COUNT" -gt 0 ]; then
  echo -e "$REPORT"
  echo ""
  echo "⚠  $STALE_COUNT stale reference(s) found. Update CLAUDE.md before sprint-end."

  # ── AC-26 (sprint-system-100): auto-delete with safety cap ───────────────
  if [ "$AUTO_FIX" = true ]; then
    PRIMARY_CLAUDE_MD="CLAUDE.md"
    [ ! -f "$PRIMARY_CLAUDE_MD" ] && { echo "[!] no root CLAUDE.md to fix"; exit 1; }

    TOTAL_LINES="$(wc -l < "$PRIMARY_CLAUDE_MD")"
    # Count how many lines would be deleted
    DELETIONS_TO_MAKE=0
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      LINE_HITS="$(grep -cE "\`$path\`" "$PRIMARY_CLAUDE_MD" 2>/dev/null || echo 0)"
      DELETIONS_TO_MAKE=$((DELETIONS_TO_MAKE + LINE_HITS))
    done <<< "$STALE_PATHS_TO_REMOVE"

    PCT=$((DELETIONS_TO_MAKE * 100 / TOTAL_LINES))
    echo ""
    echo "  AC-26 auto-fix mode:"
    echo "    Total CLAUDE.md lines: $TOTAL_LINES"
    echo "    Lines to delete:       $DELETIONS_TO_MAKE ($PCT%)"

    if [ "$PCT" -gt 20 ]; then
      echo "  [!] Safety cap: >20% deletion ($PCT%) — refusing auto-fix."
      echo "      Run manual review instead."
      exit 1
    fi

    # Backup
    cp "$PRIMARY_CLAUDE_MD" "$PRIMARY_CLAUDE_MD.bak"
    echo "    Backup written: $PRIMARY_CLAUDE_MD.bak"

    # Delete each stale-path line
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      # Escape for sed
      esc_path="$(printf '%s' "$path" | sed 's/[\/&]/\\&/g')"
      sed -i.tmp "/\`${esc_path}\`/d" "$PRIMARY_CLAUDE_MD"
    done <<< "$STALE_PATHS_TO_REMOVE"
    rm -f "$PRIMARY_CLAUDE_MD.tmp"

    NEW_LINES="$(wc -l < "$PRIMARY_CLAUDE_MD")"
    ACTUAL_DELETIONS=$((TOTAL_LINES - NEW_LINES))
    echo "    Actual deletions: $ACTUAL_DELETIONS lines"

    # Commit
    SLUG_FOR_MSG="${SLUG:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || echo unknown)}"
    if command -v git >/dev/null 2>&1 && [ -n "$(git status --porcelain CLAUDE.md 2>/dev/null)" ]; then
      SPRINT_DRIFT_BYPASS=1 SPRINT_DUP_BYPASS=1 git add CLAUDE.md
      SPRINT_DRIFT_BYPASS=1 SPRINT_DUP_BYPASS=1 git commit -m "chore(claude.md): auto-clean stale refs (sprint $SLUG_FOR_MSG)" 2>&1 | tail -2
    fi
  fi

  # Strict mode (env-controlled, separate from auto-fix)
  if [ "${SPRINT_CLAUDE_MD_STRICT:-0}" = "1" ] && [ "$AUTO_FIX" != true ]; then
    exit 1
  fi
else
  echo "✓ No stale references found."
fi

exit 0
