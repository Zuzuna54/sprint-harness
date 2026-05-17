#!/usr/bin/env node
/**
 * sprint-wizard-grep-runner.mjs — Actually run the grep heuristics for a section.
 *
 * The wizard SKILL.md asks Claude to grep. Previously, `sprint-wizard-context.mjs`
 * only EMITTED grep commands as strings for Claude to run manually. This script
 * EXECUTES them, returning top-N matches as JSON. Closes gap #14.
 *
 * Usage:
 *   sprint-wizard-grep-runner.mjs <slug> <section> [--limit N]
 *
 * Output: JSON to stdout with shape:
 *   {
 *     slug, section,
 *     greps_run: [{pattern, path, reason, match_count, top_matches: [{file, line, snippet}]}],
 *     errors: []
 *   }
 *
 * Uses ripgrep (rg) if available, falls back to grep -r.
 */

import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync, spawnSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const args = process.argv.slice(2);
const slug = args.find((a) => !a.startsWith("--") && !args[args.indexOf(a) - 1]?.startsWith("--limit"));
const section = args[args.indexOf(slug) + 1];
const limit = parseInt(args[args.indexOf("--limit") + 1] || "10", 10);

if (!slug || !section) {
  console.error("Usage: sprint-wizard-grep-runner.mjs <slug> <section> [--limit N]");
  process.exit(1);
}

// Per-section grep heuristics (mirror of sprint-wizard-context.mjs)
const GREP_HEURISTICS = {
  A: [
    {
      pattern: "(MealPrepSession|TimeBlock|WorkoutSet|HealthLog|SupplementLog)",
      path: "packages/db/src/schema",
      reason: "existing entities to ground problem statement",
    },
  ],
  B: [
    {
      pattern: "^export (const|function|class|type)",
      path: "packages/utils",
      reason: "existing domain logic helpers",
    },
  ],
  C: [
    {
      pattern: "pgTable\\(",
      path: "packages/db/src/schema",
      reason: "existing schema patterns",
    },
    {
      pattern: "CREATE POLICY",
      path: "packages/db/src/migrations",
      reason: "existing RLS policy patterns",
    },
  ],
  D: [
    {
      pattern: "export const manifest",
      path: "apps/lambdas",
      reason: "existing route manifests",
    },
    {
      pattern: "z\\.object\\(",
      path: "apps/lambdas",
      reason: "existing Zod schemas",
    },
  ],
  E: [
    {
      pattern: "'use client'",
      path: "apps/web/components",
      reason: "existing client components",
    },
    {
      pattern: "^export default function",
      path: "apps/web/components",
      reason: "existing default-exported components",
    },
  ],
  F: [
    {
      pattern: "(toast|Sonner|useMutation)",
      path: "apps/web",
      reason: "existing toast/optimistic patterns",
    },
  ],
  G: [
    {
      pattern: "from \"lucide-react\"",
      path: "apps/web",
      reason: "existing Lucide icon usage",
    },
  ],
  H: [
    {
      pattern: "(GoogleGenerativeAI|generativelanguage|Gemini)",
      path: "apps/lambdas",
      reason: "existing Gemini integration",
    },
  ],
  I: [
    {
      pattern: "(describe\\(|it\\(|GIVEN|WHEN|THEN)",
      path: "apps",
      reason: "existing test patterns",
    },
  ],
  J: [
    {
      pattern: "(requireUser|auth\\.uid|RLS)",
      path: "apps/lambdas",
      reason: "existing auth/RLS surfaces",
    },
  ],
};

const heuristics = GREP_HEURISTICS[section] || [];

// Detect ripgrep availability
let useRg = true;
try {
  execSync("which rg", { stdio: ["pipe", "pipe", "ignore"] });
} catch {
  useRg = false;
}

function runGrep(pattern, path, reason) {
  const target = join(REPO_ROOT, path);
  if (!existsSync(target)) {
    return { pattern, path, reason, error: "path not found", match_count: 0, top_matches: [] };
  }

  let stdout = "";
  if (useRg) {
    const r = spawnSync(
      "rg",
      ["-n", "--no-heading", "-g", "!**/node_modules/**", "-g", "!**/dist/**", "-g", "!**/.next/**", pattern, target],
      { encoding: "utf8", maxBuffer: 5 * 1024 * 1024 }
    );
    stdout = r.stdout || "";
  } else {
    const r = spawnSync(
      "grep",
      ["-rn", "--include=*.ts", "--include=*.tsx", "--include=*.sql", "--exclude-dir=node_modules", "--exclude-dir=dist", "--exclude-dir=.next", "-E", pattern, target],
      { encoding: "utf8", maxBuffer: 5 * 1024 * 1024 }
    );
    stdout = r.stdout || "";
  }

  const lines = stdout.trim().split("\n").filter(Boolean);
  const matches = [];
  for (const line of lines.slice(0, limit)) {
    // ripgrep: file:line:snippet  /  grep -rn: file:line:snippet
    const m = line.match(/^(.+?):(\d+):(.*)$/);
    if (m) {
      matches.push({
        file: m[1].replace(REPO_ROOT + "/", ""),
        line: +m[2],
        snippet: m[3].trim().slice(0, 120),
      });
    }
  }

  return {
    pattern,
    path,
    reason,
    match_count: lines.length,
    top_matches: matches,
  };
}

const greps_run = [];
const errors = [];

for (const h of heuristics) {
  try {
    const result = runGrep(h.pattern, h.path, h.reason);
    greps_run.push(result);
  } catch (e) {
    errors.push({ heuristic: h, error: e.message });
  }
}

const bundle = {
  slug,
  section,
  tool: useRg ? "ripgrep" : "grep",
  heuristics_total: heuristics.length,
  greps_run,
  errors,
};

console.log(JSON.stringify(bundle, null, 2));
