#!/usr/bin/env node
/**
 * sprint-hillchart.mjs — Generate / refresh the Shape Up hill chart for a sprint.
 *
 * Each scope (AC) is a dot on the curve:
 *   - **Uphill**: AC where design questions remain (in_progress + has open questions)
 *   - **Top**: AC where approach is clear, implementation hasn't started
 *   - **Downhill**: AC where implementation is underway
 *   - **At bottom**: AC closed
 *
 * Usage:
 *   sprint-hillchart.mjs <slug>             # print to stdout
 *   sprint-hillchart.mjs <slug> --refresh   # write to hill-chart.md
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const [, , slug, ...flags] = process.argv;
if (!slug) {
  console.error("Usage: sprint-hillchart.mjs <slug> [--refresh]");
  process.exit(1);
}

const refresh = flags.includes("--refresh");
const sprintDir = join(REPO_ROOT, "docs", "sprints", slug);
const statePath = join(sprintDir, "state.json");
const hillPath = join(sprintDir, "hill-chart.md");
const specPath = join(sprintDir, "spec.md");

if (!existsSync(statePath)) {
  console.error(`[!] state.json missing: ${statePath}`);
  process.exit(1);
}

const state = JSON.parse(readFileSync(statePath, "utf8"));

// Pull AC list from state if present, else parse §I of spec
let acs = [];
if (state.acs_detail && Array.isArray(state.acs_detail)) {
  acs = state.acs_detail;
} else if (existsSync(specPath)) {
  // Best-effort parse: find lines starting with "**AC-N**"
  const spec = readFileSync(specPath, "utf8");
  const matches = [...spec.matchAll(/\*\*AC-(\d+)\*\*\s*`?complex:\s*(true|false)`?/g)];
  acs = matches.map((m) => ({
    id: `AC-${m[1]}`,
    complex: m[2] === "true",
    state: "uphill", // default — orchestrator updates as work progresses
  }));
}

if (acs.length === 0) {
  acs = [{ id: "(none yet)", state: "uphill", complex: false }];
}

// Group by state
const groups = { uphill: [], top: [], downhill: [], done: [] };
for (const ac of acs) {
  const s = ac.state || (state.acs_closed_ids?.includes(ac.id) ? "done" : "uphill");
  if (groups[s]) groups[s].push(ac);
  else groups.uphill.push(ac);
}

// Build ASCII hill chart
const dots = (arr) =>
  arr.length === 0 ? "·" : arr.map((a) => (a.complex ? "◆" : "●")).join("");

const chart = `\`\`\`
  Figuring out                                                Making it happen
   ─────────────────────────────────────────────────────────────────────────
                      Uphill          Top of hill          Downhill           Done

                   ${dots(groups.uphill).padEnd(12)}      ${dots(groups.top).padEnd(8)}            ${dots(groups.downhill).padEnd(12)}      ${dots(groups.done)}

   ─────────────────────────────────────────────────────────────────────────
\`\`\`

Legend:
  ●  simple AC
  ◆  complex AC (auto pair-mode in build phase)
`;

const total = acs.length;
const done = groups.done.length;
const downhill = groups.downhill.length;
const top = groups.top.length;
const uphill = groups.uphill.length;
const dayLine = `**Day:** ${state.day || 0} of ${state.appetite_days || 14}`;
const phaseLine = `**Phase:** ${state.phase || "unknown"}`;
const progressLine = `**Progress:** ${done}/${total} done · ${downhill} downhill · ${top} top · ${uphill} uphill`;

const md = `# Hill Chart: ${slug}

Updated: ${new Date().toISOString()}

${dayLine} · ${phaseLine}

${progressLine}

${chart}

## Scopes

| AC | Complex | State |
|----|---------|-------|
${acs.map((a) => `| ${a.id} | ${a.complex ? "◆ yes" : "● no"} | ${a.state || "uphill"} |`).join("\n")}
`;

if (refresh) {
  writeFileSync(hillPath, md);
  console.log(`[+] Hill chart updated: ${hillPath}`);
} else {
  console.log(md);
}
