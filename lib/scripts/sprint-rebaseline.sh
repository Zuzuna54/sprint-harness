#!/usr/bin/env bash
# sprint-rebaseline.sh — Re-embed the spec.md to update the drift baseline.
#
# Called after a spec amendment is approved. Archives the old baseline and
# writes a new one. Old baselines kept as `.baseline-embedding.day<N>.json`
# for history.
#
# Usage:
#   bash scripts/sprint-rebaseline.sh [<slug>]
#
# If slug omitted, uses the active sprint.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SLUG="${1:-$(bash scripts/sprint-status.sh --slug-only 2>/dev/null || true)}"
if [ -z "$SLUG" ]; then
  echo "[!] No active sprint and no slug given." >&2
  exit 1
fi

SPRINT_DIR="docs/sprints/$SLUG"
SPEC_FILE="$SPRINT_DIR/spec.md"
BASELINE_FILE="$SPRINT_DIR/.baseline-embedding.json"
STATE_FILE="$SPRINT_DIR/state.json"

if [ ! -f "$SPEC_FILE" ]; then
  echo "[!] spec.md not found: $SPEC_FILE" >&2
  exit 1
fi

# Archive existing baseline (if any) with the current day suffix
if [ -f "$BASELINE_FILE" ]; then
  DAY="$(grep -o '"day":[[:space:]]*[0-9]*' "$STATE_FILE" | head -1 | grep -o '[0-9]*$' || echo 0)"
  ARCHIVE="$SPRINT_DIR/.baseline-embedding.day${DAY}.json"
  cp "$BASELINE_FILE" "$ARCHIVE"
  echo "[+] Archived old baseline → $ARCHIVE"
fi

# P5c (gap #18): composite baseline = spec.md + graphify-out summary digest
# So drift score reflects BOTH spec intent AND current codebase architecture.
SPEC_TEXT="$(cat "$SPEC_FILE")"

GRAPH_DIGEST=""
GRAPH_HASH=""
GRAPH_REPORT="graphify-out/GRAPH_REPORT.md"
if [ -f "$GRAPH_REPORT" ]; then
  # AC-4 (sprint-system-100, Gap K): structured digest = top 5 god nodes +
  # top 3 communities (not "head -200"). Drift baseline now reflects spec
  # intent AND the current architectural shape — commits that drift the
  # codebase away from its god-node structure score lower.
  GRAPH_DIGEST="$(node -e "
    const fs=require('fs');
    const md=fs.readFileSync('$GRAPH_REPORT','utf8');
    const out=[];
    // Top 5 god nodes (numbered list under ## God Nodes)
    const godMatch=md.match(/## God Nodes[^\n]*\n([\s\S]*?)(?=\n## |\$)/);
    if(godMatch){
      const lines=godMatch[1].split('\n').filter(l=>/^\d+\.\s+\`/.test(l)).slice(0,5);
      out.push('---GOD-NODES---'); out.push(...lines);
    }
    // Top 3 communities by appearance order under ## Communities
    const commMatch=md.match(/## Communities[^\n]*\n([\s\S]*)/);
    if(commMatch){
      const blocks=commMatch[1].split(/(?=### Community )/).slice(0,3);
      out.push('---COMMUNITIES---'); out.push(...blocks.map(b=>b.trim().slice(0,500)));
    }
    process.stdout.write(out.join('\n'));
  ")"
  GRAPH_HASH="$(printf '%s' "$GRAPH_DIGEST" | shasum -a 256 | awk '{print $1}')"
  echo "[+] Composite baseline: spec.md + 5 god-nodes + top 3 communities ($(printf '%s' "$GRAPH_DIGEST" | wc -c | tr -d ' ') chars)"
else
  echo "[i] graphify-out/GRAPH_REPORT.md not found — baseline is spec.md only"
fi

COMPOSITE_TEXT="$(printf '%s\n\n---GRAPHIFY-DIGEST---\n%s\n' "$SPEC_TEXT" "$GRAPH_DIGEST")"
TMP_TEXT="$(mktemp)"
trap 'rm -f "$TMP_TEXT"' EXIT
printf '%s' "$COMPOSITE_TEXT" > "$TMP_TEXT"
# Re-export so downstream uses composite, not just spec
SPEC_TEXT="$COMPOSITE_TEXT"

# BUG 2 fix: `ruflo memory embed` doesn't exist as a subcommand in
# v3.7.0-alpha.42-44 (only init/store/retrieve/search/list/delete/stats/
# configure/cleanup/compress/export/import are documented). Previously this
# was getting the CLI usage text as $EMBEDDING_JSON, then writing baseline
# with model="Xenova/..." but embedding=[]. Until a real embed CLI ships,
# always use BoW fallback (drift-score handles it correctly).

NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Optional opt-in: if SPRINT_USE_RUFLO_EMBED=1 AND ruflo gains an embed CLI,
# this branch can be reactivated. For now, default to BoW fallback path.
if [ "${SPRINT_USE_RUFLO_EMBED:-0}" = "1" ] && command -v ruflo >/dev/null 2>&1 && \
   ruflo memory embed --help >/dev/null 2>&1; then
  EMBEDDING_JSON="$(ruflo memory embed --text "$SPEC_TEXT" 2>/dev/null || true)"
  cat > "$BASELINE_FILE" <<JSON
{
  "model": "Xenova/all-MiniLM-L6-v2",
  "dim": 384,
  "embedded_at": "$NOW_ISO",
  "spec_hash": "$(shasum -a 256 "$SPEC_FILE" | awk '{print $1}')",
  "embedding": $(echo "$EMBEDDING_JSON" | node -e "
    let raw = '';
    process.stdin.on('data', d => raw += d);
    process.stdin.on('end', () => {
      try {
        const j = JSON.parse(raw);
        console.log(JSON.stringify(j.embedding || j));
      } catch (e) {
        console.log('[]');
      }
    });
  ")
}
JSON
else
  # Fallback: store the raw text; drift-score falls back to BoW
  cat > "$BASELINE_FILE" <<JSON
{
  "model": "fallback-bow",
  "dim": 0,
  "embedded_at": "$NOW_ISO",
  "spec_hash": "$(shasum -a 256 "$SPEC_FILE" | awk '{print $1}')",
  "graph_hash": "$GRAPH_HASH",
  "composite": true,
  "text": $(node -e "
    const fs = require('fs');
    const t = fs.readFileSync('$TMP_TEXT', 'utf8');
    process.stdout.write(JSON.stringify(t));
  "),
  "embedding": []
}
JSON
fi

echo "[+] New baseline written: $BASELINE_FILE"
echo "    (model: $(grep -o '"model":[[:space:]]*"[^"]*"' "$BASELINE_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'))"
