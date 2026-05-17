#!/usr/bin/env node
/**
 * sprint-pr-body.mjs — Auto-fill PR body from spec.md when PR opens on a sprint branch.
 *
 * Reads spec.md, computes diff vs spec (what's done, what's left), and writes
 * a markdown PR body that aligns reviewers with the sprint's intent.
 *
 * Used by: .github/workflows/sprint-pr-body.yml (PR open trigger)
 *
 * Usage:
 *   sprint-pr-body.mjs <slug>          # print PR body to stdout
 *   sprint-pr-body.mjs --pr <number>   # update specific PR
 *   sprint-pr-body.mjs --from-branch   # infer slug from current branch sprint/<slug>
 */

import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const args = process.argv.slice(2);

let slug = null;
let prNumber = null;

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--from-branch") {
    const branch = execSync("git branch --show-current", { encoding: "utf8" }).trim();
    const m = branch.match(/^sprint\/(.+)$/);
    if (m) slug = m[1];
  } else if (args[i] === "--pr") {
    prNumber = args[++i];
  } else if (!slug && !args[i].startsWith("--")) {
    slug = args[i];
  }
}

if (!slug) {
  console.error("Usage: sprint-pr-body.mjs <slug> | --from-branch [--pr <number>]");
  process.exit(1);
}

const sprintDir = join(REPO_ROOT, "docs", "sprints", slug);
const specPath = join(sprintDir, "spec.md");
const statePath = join(sprintDir, "state.json");

if (!existsSync(specPath)) {
  console.error(`[!] spec.md missing: ${specPath}`);
  process.exit(1);
}

const spec = readFileSync(specPath, "utf8");
const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};

// Extract sections we want in the PR body
function extractSection(re) {
  const m = spec.match(re);
  return m ? m[0].replace(/^##.*\n/, "").trim() : "";
}

const problem = (extractSection(/### Problem statement[\s\S]*?(?=\n###|\n##|\n---)/) || "")
  .replace(/^### Problem statement\s*/, "")
  .trim()
  .slice(0, 500);

const successVision = (extractSection(/### Success vision[\s\S]*?(?=\n###|\n##|\n---)/) || "")
  .replace(/^### Success vision\s*/, "")
  .trim()
  .slice(0, 400);

// Pull AC list
const acMatches = [...spec.matchAll(/\*\*AC-(\d+)\*\*\s*`?complex:\s*(true|false)`?/g)];
const acsTotal = acMatches.length;
const acsClosed = (state.acs_closed_ids || []).length;

// Find DoD checklist
const dodMatch = spec.match(/## Module DoD[\s\S]*?(?=\n##|\n---|$)/);
const dodChecklist = dodMatch ? dodMatch[0] : "_(see spec.md)_";

// Compute diff vs spec
let filesTouchedActual = [];
try {
  const out = execSync(`git diff --name-only main...HEAD`, {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });
  filesTouchedActual = out.trim().split("\n").filter(Boolean);
} catch {}

const filesTouchedSpec = state.files_touched || [];
const unexpectedFiles = filesTouchedActual.filter(
  (f) =>
    !filesTouchedSpec.some(
      (s) => f === s || f.startsWith(s.replace(/\*\*?$/, "")) || s.includes(f.split("/")[0])
    )
);

const body = `## Sprint: \`${slug}\`

**Phase:** ${state.phase || "?"} · **Day:** ${state.day || 0} of 14 · **Gates:** ${(state.gates_passed || []).join(", ") || "(none)"}

---

### Problem

${problem || "_(see spec.md §A)_"}

### Success vision

${successVision || "_(see spec.md §A)_"}

---

### Acceptance criteria (${acsClosed}/${acsTotal} closed)

| AC | Status |
|----|--------|
${acMatches
  .map((m) => {
    const id = `AC-${m[1]}`;
    const closed = (state.acs_closed_ids || []).includes(id);
    return `| ${id} | ${closed ? "✅ closed" : "⏳ open"} |`;
  })
  .join("\n") || "| _(no ACs parsed)_ | |"}

---

### Files in this PR (${filesTouchedActual.length})

\`\`\`
${filesTouchedActual.slice(0, 40).join("\n")}
${filesTouchedActual.length > 40 ? `... (+${filesTouchedActual.length - 40} more)` : ""}
\`\`\`

${
  unexpectedFiles.length > 0
    ? `\n⚠️ **Files outside spec scope:**\n${unexpectedFiles.slice(0, 10).map((f) => `- \`${f}\``).join("\n")}\n\nReviewer: confirm intentional scope expansion or request revert.\n`
    : ""
}

---

### Module DoD

${dodChecklist.replace(/^## Module DoD.*\n/, "")}

---

### Spec + design

- Full spec: [\`${specPath.replace(REPO_ROOT + "/", "")}\`](./${specPath.replace(REPO_ROOT + "/", "")})
- Hill chart: [\`${sprintDir.replace(REPO_ROOT + "/", "")}/hill-chart.md\`](./${sprintDir.replace(REPO_ROOT + "/", "")}/hill-chart.md)
- Retro (post-merge): [\`${sprintDir.replace(REPO_ROOT + "/", "")}/retro.md\`](./${sprintDir.replace(REPO_ROOT + "/", "")}/retro.md)

---

### Drift events during sprint

${
  (state.drift_events || []).length === 0
    ? "_(none — no commits flagged below 0.75 threshold)_"
    : (state.drift_events || [])
        .slice(-5)
        .map((d) => `- \`${d.at}\` score=${d.score} — \`${(d.msg || "").slice(0, 60)}\``)
        .join("\n")
}

---

<sub>PR body auto-generated by \`scripts/sprint-pr-body.mjs\`. Edit freely below this line if needed.</sub>
`;

if (prNumber) {
  // Update PR via gh
  try {
    execSync(`gh pr edit ${prNumber} --body-file -`, {
      cwd: REPO_ROOT,
      input: body,
      stdio: ["pipe", "inherit", "inherit"],
    });
    console.log(`[+] PR #${prNumber} body updated.`);
  } catch (e) {
    console.error(`[!] gh pr edit failed: ${e.message}`);
    process.exit(1);
  }
} else {
  console.log(body);
}
