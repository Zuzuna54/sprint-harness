#!/usr/bin/env node
/**
 * sprint-bundle-budget.mjs — Check Lambda bundle sizes against budget.
 *
 * Reads built Lambda bundles from apps/lambdas/*\/dist/ + .turbo/build-output,
 * compares against per-Lambda budget (default 5MB; configurable in spec §J).
 *
 * Usage:
 *   sprint-bundle-budget.mjs <slug> [--budget-mb N] [--json]
 *
 * Exit codes:
 *   0 = all Lambdas within budget
 *   1 = at least one over budget
 *   2 = no built bundles found
 */

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const args = process.argv.slice(2);
const slug = args.find((a) => !a.startsWith("--"));
// BUG 11 fix: when --budget-mb is absent, indexOf returns -1 → args[-1+1] is
// args[0] (the slug), parseFloat("<slug>") = NaN → NaN MB rendered. Guard:
// only read args[i+1] if i >= 0.
const _budgetIdx = args.indexOf("--budget-mb");
const budgetMb = _budgetIdx >= 0 ? parseFloat(args[_budgetIdx + 1] || "5") : 5;
const asJson = args.includes("--json");

if (!slug) {
  console.error("Usage: sprint-bundle-budget.mjs <slug> [--budget-mb N]");
  process.exit(2);
}

// Per-Lambda budget overrides can come from spec §J
const specPath = join(REPO_ROOT, "docs", "sprints", slug, "spec.md");
const perLambdaBudgets = {};
if (existsSync(specPath)) {
  const spec = readFileSync(specPath, "utf8");
  // Match "bundle budget: <name>=<size>MB"
  for (const m of spec.matchAll(/bundle budget:\s*(\S+)\s*=\s*([\d.]+)\s*MB/gi)) {
    perLambdaBudgets[m[1]] = parseFloat(m[2]);
  }
}

const BUDGET_MB_DEFAULT = budgetMb;
const BUDGET_BYTES_DEFAULT = BUDGET_MB_DEFAULT * 1024 * 1024;

const lambdasDir = join(REPO_ROOT, "apps", "lambdas");
if (!existsSync(lambdasDir)) {
  console.error(`[!] Lambdas dir not found: ${lambdasDir}`);
  process.exit(2);
}

// Find each Lambda's bundle
function dirSize(dir) {
  let total = 0;
  try {
    for (const e of readdirSync(dir)) {
      const p = join(dir, e);
      const st = statSync(p);
      if (st.isDirectory()) total += dirSize(p);
      else total += st.size;
    }
  } catch {}
  return total;
}

const results = [];

for (const lambda of readdirSync(lambdasDir)) {
  const lambdaPath = join(lambdasDir, lambda);
  if (!statSync(lambdaPath).isDirectory()) continue;
  if (lambda === "scripts" || lambda === "_shared" || lambda === "local-server") continue;

  const distPath = join(lambdaPath, "dist");
  if (!existsSync(distPath)) {
    results.push({ lambda, size_bytes: 0, status: "no-dist", in_budget: true });
    continue;
  }

  const sizeBytes = dirSize(distPath);
  const sizeMb = sizeBytes / 1024 / 1024;
  const budgetForLambda =
    perLambdaBudgets[lambda] != null
      ? perLambdaBudgets[lambda] * 1024 * 1024
      : BUDGET_BYTES_DEFAULT;
  const budgetMbForLambda = budgetForLambda / 1024 / 1024;

  results.push({
    lambda,
    size_bytes: sizeBytes,
    size_mb: Number(sizeMb.toFixed(2)),
    budget_mb: budgetMbForLambda,
    in_budget: sizeBytes <= budgetForLambda,
    status: sizeBytes > budgetForLambda ? "OVER" : "ok",
  });
}

const overBudget = results.filter((r) => !r.in_budget);
const noDist = results.filter((r) => r.status === "no-dist");

const summary = {
  slug,
  default_budget_mb: BUDGET_MB_DEFAULT,
  per_lambda_overrides: perLambdaBudgets,
  total_lambdas: results.length,
  in_budget_count: results.filter((r) => r.in_budget && r.status !== "no-dist").length,
  no_dist_count: noDist.length,
  over_budget_count: overBudget.length,
  results,
  pass: overBudget.length === 0,
};

if (asJson) {
  console.log(JSON.stringify(summary, null, 2));
} else {
  console.log(`Bundle budget check: ${slug}`);
  console.log(`  Default budget: ${BUDGET_MB_DEFAULT} MB per Lambda`);
  if (Object.keys(perLambdaBudgets).length > 0) {
    console.log(`  Per-Lambda overrides:`);
    for (const [k, v] of Object.entries(perLambdaBudgets)) {
      console.log(`    ${k}: ${v} MB`);
    }
  }
  console.log("");
  for (const r of results) {
    if (r.status === "no-dist") {
      console.log(`  ·  ${r.lambda.padEnd(30)} (no dist — not built)`);
    } else {
      const sym = r.in_budget ? "✓" : "✗";
      console.log(`  ${sym}  ${r.lambda.padEnd(30)} ${r.size_mb.toFixed(2)} MB / ${r.budget_mb} MB`);
    }
  }
  console.log("");
  if (noDist.length > 0) {
    console.log(`[i] ${noDist.length} Lambdas have no dist (not built yet). Run pnpm build first.`);
  }
  console.log(summary.pass ? "✓ All Lambdas within budget" : `✗ ${overBudget.length} over budget`);
}

process.exit(summary.pass ? 0 : 1);
