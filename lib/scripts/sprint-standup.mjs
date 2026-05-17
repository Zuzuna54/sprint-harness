#!/usr/bin/env node
/**
 * sprint-standup.mjs — Generate today's standup entry for the active sprint.
 *
 * Appends to docs/sprints/<slug>/standup.md:
 *   - YESTERDAY: commits + tests passed + ACs closed
 *   - TODAY: planned (next AC from spec §I)
 *   - BLOCKERS: open questions from spec + drift events
 *
 * Intended to be invoked daily by daemon's `document` worker (paused during
 * sprint per protocol, so this script fills the gap) or manually.
 *
 * Usage:
 *   sprint-standup.mjs [<slug>]
 *   sprint-standup.mjs --all       # for all active sprints (currently max 1)
 */

import { readFileSync, writeFileSync, existsSync, appendFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const [, , slugArg] = process.argv;

function getActiveSlug() {
  try {
    const out = execSync(`bash ${join(REPO_ROOT, "scripts/sprint-status.sh")} --slug-only`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "ignore"],
    }).trim();
    return out || null;
  } catch {
    return null;
  }
}

const slug = slugArg || getActiveSlug();
if (!slug) {
  console.log("[i] No active sprint; nothing to stand-up.");
  process.exit(0);
}

const sprintDir = join(REPO_ROOT, "docs", "sprints", slug);
const statePath = join(sprintDir, "state.json");
const standupPath = join(sprintDir, "standup.md");
const specPath = join(sprintDir, "spec.md");

if (!existsSync(statePath)) {
  console.error(`[!] state.json missing: ${statePath}`);
  process.exit(1);
}

const state = JSON.parse(readFileSync(statePath, "utf8"));

// Yesterday's commits on the sprint branch
let recentCommits = [];
try {
  const branch = state.git_branch || "HEAD";
  const out = execSync(
    `git log --since="24 hours ago" --oneline ${branch}`,
    { cwd: REPO_ROOT, encoding: "utf8", stdio: ["pipe", "pipe", "ignore"] }
  );
  recentCommits = out.trim().split("\n").filter(Boolean);
} catch {}

// ACs closed in the last 24h (heuristic from state)
const acsClosedYesterday = (state.acs_closed_ids || []).filter((id) => {
  const closedAt = state.acs_closed_at?.[id];
  if (!closedAt) return false;
  return Date.now() - new Date(closedAt).getTime() < 86400000;
});

// Drift events in the last 24h
const recentDrift = (state.drift_events || []).filter(
  (e) => Date.now() - new Date(e.at).getTime() < 86400000
);

// Next AC to work on (first AC not yet closed)
let nextAC = null;
if (existsSync(specPath)) {
  const spec = readFileSync(specPath, "utf8");
  const matches = [...spec.matchAll(/\*\*AC-(\d+)\*\*/g)];
  for (const m of matches) {
    const id = `AC-${m[1]}`;
    if (!(state.acs_closed_ids || []).includes(id)) {
      nextAC = id;
      break;
    }
  }
}

// Open questions from spec §J.J4
let openQuestions = [];
if (existsSync(specPath)) {
  const spec = readFileSync(specPath, "utf8");
  const j4Section = spec.match(/### Open questions[\s\S]*?(?=\n##|\n---|$)/);
  if (j4Section) {
    openQuestions = j4Section[0]
      .split("\n")
      .filter((l) => l.trim().startsWith("- ") && !l.includes("decided"))
      .slice(0, 5);
  }
}

const today = new Date().toISOString().slice(0, 10);
const day = state.day || 0;

const entry = `
## Day ${day} — ${today}

### Yesterday
${
  recentCommits.length > 0
    ? recentCommits.map((c) => `- ${c}`).join("\n")
    : "_(no commits in last 24h)_"
}

**ACs closed:** ${acsClosedYesterday.length > 0 ? acsClosedYesterday.join(", ") : "_(none)_"}

### Today
**Next AC:** ${nextAC || "_(no remaining ACs — verify phase?)_"}

### Blockers
${
  recentDrift.length > 0
    ? recentDrift.map((d) => `- DRIFT @ ${d.at}: score ${d.score} — ${(d.msg || "").slice(0, 80)}`).join("\n")
    : "_(no drift events)_"
}

${
  openQuestions.length > 0
    ? `**Open questions:**\n${openQuestions.join("\n")}`
    : "_(no open questions blocking)_"
}

---
`;

// Initialize file if missing
if (!existsSync(standupPath)) {
  writeFileSync(standupPath, `# Standup: ${slug}\n\nDaily auto-generated entries. Manual notes welcome between sections.\n\n`);
}

appendFileSync(standupPath, entry);
console.log(`[+] Standup appended to: ${standupPath}`);
console.log("");
console.log(entry);
