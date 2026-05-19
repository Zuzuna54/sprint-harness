#!/usr/bin/env node
/**
 * sprint-cross-pattern-audit.mjs — Did this sprint recall patterns from prior sprints?
 *
 * For sprint N, checks:
 *   - Patterns stored at retro in sprints 1..N-1
 *   - Patterns actually recalled (per docs/sprints/<prior>/recalled-patterns.json) in sprint N
 *
 * Reports:
 *   - "Reused" — patterns from old sprints that THIS sprint surfaced
 *   - "Never recalled" — patterns from old sprints with 0 recalls across all sprints; candidates for prune
 *   - "Fresh stores" — patterns added in THIS sprint
 *
 * Run at sprint-end (called by lifeos-retro.yaml).
 *
 * Usage:
 *   sprint-cross-pattern-audit.mjs <current-slug> [--json]
 *
 * Exit codes:
 *   0 = audit completed
 *   2 = config error
 */

import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const args = process.argv.slice(2);
const currentSlug = args.find((a) => !a.startsWith("--"));
const asJson = args.includes("--json");

if (!currentSlug) {
  console.error("Usage: sprint-cross-pattern-audit.mjs <slug> [--json]");
  process.exit(2);
}

const sprintsDir = join(REPO_ROOT, "docs", "sprints");
if (!existsSync(sprintsDir)) {
  console.error(`[!] Sprints dir not found: ${sprintsDir}`);
  process.exit(2);
}

// ── Collect prior sprint slugs (excluding current + _template) ────────────────
const allSprints = readdirSync(sprintsDir)
  .filter((d) => {
    if (d === "_template" || d === "README.md" || d.endsWith(".md") || d === currentSlug) return false;
    return existsSync(join(sprintsDir, d, "state.json"));
  })
  .sort();

const currentDir = join(sprintsDir, currentSlug);
if (!existsSync(currentDir)) {
  console.error(`[!] Current sprint dir not found: ${currentDir}`);
  process.exit(2);
}

// ── Collect patterns stored at retro per prior sprint ────────────────────────
// Heuristic: parse retro.md "## Patterns extracted" section (lines like "- lifeos-*-pattern")
function patternsStoredIn(slug) {
  const retroPath = join(sprintsDir, slug, "retro.md");
  if (!existsSync(retroPath)) return [];
  const text = readFileSync(retroPath, "utf8");
  const sec = text.match(/## Patterns extracted[\s\S]*?(?=\n##|\n---|$)/);
  if (!sec) return [];
  return [...sec[0].matchAll(/`?(lifeos-[\w-]+)`?/g)].map((m) => m[1]);
}

// ── Collect patterns recalled per sprint ─────────────────────────────────────
function patternsRecalledIn(slug) {
  const recalledPath = join(sprintsDir, slug, "recalled-patterns.json");
  if (!existsSync(recalledPath)) return [];
  try {
    const arr = JSON.parse(readFileSync(recalledPath, "utf8"));
    if (!Array.isArray(arr)) return [];
    return arr.filter((r) => r.accepted).map((r) => r.key).filter(Boolean);
  } catch {
    return [];
  }
}

// ── Build the audit ──────────────────────────────────────────────────────────
const priorStored = new Map(); // pattern -> [slugs that stored it]
for (const s of allSprints) {
  for (const p of patternsStoredIn(s)) {
    if (!priorStored.has(p)) priorStored.set(p, []);
    priorStored.get(p).push(s);
  }
}

const allRecalls = new Map(); // pattern -> [slugs that recalled it]
for (const s of [...allSprints, currentSlug]) {
  for (const p of patternsRecalledIn(s)) {
    if (!allRecalls.has(p)) allRecalls.set(p, []);
    allRecalls.get(p).push(s);
  }
}

const currentRecalls = patternsRecalledIn(currentSlug);
const currentStored = patternsStoredIn(currentSlug);

const reused = currentRecalls.filter((p) => priorStored.has(p));
const neverRecalled = [...priorStored.keys()].filter((p) => !allRecalls.has(p));
const freshStores = currentStored;

const reusePercent = priorStored.size > 0 ? (reused.length / priorStored.size) * 100 : 0;

const result = {
  current_slug: currentSlug,
  prior_sprints_count: allSprints.length,
  prior_patterns_stored_count: priorStored.size,
  reused_in_current: reused,
  reuse_percent: Number(reusePercent.toFixed(1)),
  never_recalled: neverRecalled,
  fresh_stores_in_current: freshStores,
};

if (asJson) {
  console.log(JSON.stringify(result, null, 2));
} else {
  console.log(`Cross-pattern audit: ${currentSlug}`);
  console.log("");
  console.log(`Prior sprints: ${allSprints.length}`);
  console.log(`Prior patterns stored: ${priorStored.size}`);
  console.log(`Reused in current sprint: ${reused.length} (${reusePercent.toFixed(1)}%)`);
  console.log(`Never recalled (prune candidates): ${neverRecalled.length}`);
  console.log(`Fresh stores in current: ${freshStores.length}`);
  console.log("");
  if (reused.length > 0) {
    console.log("✓ Patterns reused this sprint:");
    for (const p of reused) console.log(`  - ${p}`);
    console.log("");
  }
  if (neverRecalled.length > 0) {
    console.log("⚠ Never-recalled patterns (consider archiving):");
    for (const p of neverRecalled.slice(0, 10)) console.log(`  - ${p}`);
    if (neverRecalled.length > 10) console.log(`  ... (+${neverRecalled.length - 10} more)`);
    console.log("");
    console.log("To archive: ruflo memory archive --key <name>");
  }
}
