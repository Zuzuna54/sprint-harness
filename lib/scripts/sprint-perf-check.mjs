#!/usr/bin/env node
/**
 * sprint-perf-check.mjs — Compare measured perf against §I performance bars.
 *
 * Reads spec §I "Performance bars" section + output of
 * `mcp__claude-flow__performance_profile`, fails if any bar exceeded.
 *
 * Default bars (LifeOS standard):
 *   - P95 lambda response: < 800ms
 *   - Payload: < 50KB
 *   - DB queries per request: ≤ 2
 *
 * Spec can override per-AC; this script reads "Performance bars" block + any
 * AC-specific overrides.
 *
 * Usage:
 *   sprint-perf-check.mjs <slug> [--profile-output <path>] [--json]
 *
 * Exit codes:
 *   0  = all bars met
 *   1  = at least one bar violated
 *   2  = config error (no spec or no profile data)
 */

import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const args = process.argv.slice(2);
const slug = args.find((a) => !a.startsWith("--"));
const profileOutputIdx = args.indexOf("--profile-output");
const profileOutputPath = profileOutputIdx >= 0 ? args[profileOutputIdx + 1] : null;
const asJson = args.includes("--json");

if (!slug) {
  console.error("Usage: sprint-perf-check.mjs <slug> [--profile-output <path>] [--json]");
  process.exit(2);
}

const specPath = join(REPO_ROOT, "docs", "sprints", slug, "spec.md");
if (!existsSync(specPath)) {
  console.error(`[!] spec.md missing: ${specPath}`);
  process.exit(2);
}

const spec = readFileSync(specPath, "utf8");

// ── Parse §I performance bars ────────────────────────────────────────────────
// Looks for:
//   - P95 lambda response: < 800ms
//   - Payload: < 50KB
//   - DB queries per request: ≤ 2

const DEFAULT_BARS = {
  p95_ms: 800,
  payload_kb: 50,
  db_queries: 2,
};

function parseBars(specText) {
  const bars = { ...DEFAULT_BARS };
  const perfSection = specText.match(/### Performance bars[\s\S]*?(?=\n###|\n##|\n---|$)/);
  if (!perfSection) return bars;
  const txt = perfSection[0];

  let m;
  if ((m = txt.match(/P95[^<]*<\s*(\d+)\s*ms/i))) bars.p95_ms = +m[1];
  if ((m = txt.match(/[Pp]ayload[^<]*<\s*(\d+)\s*KB/i))) bars.payload_kb = +m[1];
  if ((m = txt.match(/queries[^≤<]*[≤<]=?\s*(\d+)/i))) bars.db_queries = +m[1];

  return bars;
}

const bars = parseBars(spec);

// ── Parse profile output (if provided) ───────────────────────────────────────
// Expected shape (from mcp__claude-flow__performance_profile or pnpm perf):
//   { p95_ms: 720, payload_kb: 38, db_queries: 1, ... }
// or stdout lines like "p95_ms=720"

const measurements = {};

if (profileOutputPath && existsSync(profileOutputPath)) {
  const raw = readFileSync(profileOutputPath, "utf8");
  // Try JSON first
  try {
    const parsed = JSON.parse(raw);
    Object.assign(measurements, parsed);
  } catch {
    // Try line-format: key=value
    for (const line of raw.split("\n")) {
      const m = line.match(/^(\w+)\s*[=:]\s*([0-9.]+)/);
      if (m) measurements[m[1]] = parseFloat(m[2]);
    }
  }
}

// ── Compare ──────────────────────────────────────────────────────────────────
const results = [];

if (measurements.p95_ms != null) {
  results.push({
    bar: "p95_ms",
    target: bars.p95_ms,
    actual: measurements.p95_ms,
    pass: measurements.p95_ms <= bars.p95_ms,
  });
}
if (measurements.payload_kb != null) {
  results.push({
    bar: "payload_kb",
    target: bars.payload_kb,
    actual: measurements.payload_kb,
    pass: measurements.payload_kb <= bars.payload_kb,
  });
}
if (measurements.db_queries != null) {
  results.push({
    bar: "db_queries",
    target: bars.db_queries,
    actual: measurements.db_queries,
    pass: measurements.db_queries <= bars.db_queries,
  });
}

const allPass = results.length > 0 && results.every((r) => r.pass);
const skipped = results.length === 0;

const output = {
  slug,
  bars_from_spec: bars,
  measurements,
  results,
  all_pass: allPass,
  skipped,
};

if (asJson) {
  console.log(JSON.stringify(output, null, 2));
} else {
  console.log(`Performance bar check: ${slug}`);
  console.log("");
  console.log("Bars (from spec §I):");
  for (const [k, v] of Object.entries(bars)) console.log(`  ${k}: ≤ ${v}`);
  console.log("");
  if (skipped) {
    console.log("[i] No measurements provided — skipping comparison (advisory).");
    console.log("    Pass --profile-output <path> to a JSON file with measurements.");
    process.exit(0);
  }
  console.log("Results:");
  for (const r of results) {
    const sym = r.pass ? "✓" : "✗";
    console.log(`  ${sym} ${r.bar.padEnd(15)} target=${r.target} actual=${r.actual}`);
  }
  console.log("");
  console.log(allPass ? "✓ All bars met" : "✗ At least one bar exceeded");
}

process.exit(allPass || skipped ? 0 : 1);
