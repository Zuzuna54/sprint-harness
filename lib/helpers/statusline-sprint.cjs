#!/usr/bin/env node
/**
 * statusline-sprint.cjs — Compact sprint status fragment for Claude Code statusline.
 *
 * Output (when sprint active):  [sprint:<slug> day N/14 phase:<phase> gates:N✓ drift:0.NN]
 * Output (no active sprint):    "" (empty — statusline omits this fragment)
 *
 * Intended to be invoked from settings.json's `statusline` field, or chained
 * with the existing statusline.cjs.
 *
 * Usage:
 *   node .claude/helpers/statusline-sprint.cjs
 */

const fs = require("node:fs");
const path = require("node:path");
const { execSync } = require("node:child_process");

let REPO_ROOT;
try {
  REPO_ROOT = execSync("git rev-parse --show-toplevel", {
    encoding: "utf8",
    stdio: ["pipe", "pipe", "ignore"],
  }).trim();
} catch {
  process.exit(0);
}

const sprintsDir = path.join(REPO_ROOT, "docs", "sprints");
if (!fs.existsSync(sprintsDir)) process.exit(0);

let active = null;
let latest = 0;
for (const d of fs.readdirSync(sprintsDir)) {
  if (d === "_template" || d === "README.md") continue;
  const statePath = path.join(sprintsDir, d, "state.json");
  if (!fs.existsSync(statePath)) continue;
  try {
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    if (state.phase === "done") continue;
    const mtime = fs.statSync(statePath).mtimeMs;
    if (mtime > latest) {
      latest = mtime;
      active = { slug: d, state };
    }
  } catch {}
}

if (!active) process.exit(0);

const s = active.state;
const phase = s.phase || "?";
const day = s.day != null ? s.day : "?";
const appetite = s.appetite_days || 14;
const gatesCount = (s.gates_passed || []).length;
const drift =
  s.drift_score_latest != null && s.drift_score_latest !== null
    ? Number(s.drift_score_latest).toFixed(2)
    : "—";

// Color codes (ANSI) — statusline supports them; falls back gracefully
const reset = "\x1b[0m";
let phaseColor = "\x1b[36m"; // cyan default
if (phase === "paused") phaseColor = "\x1b[33m";
if (phase === "deploying") phaseColor = "\x1b[35m";
if (phase === "building") phaseColor = "\x1b[32m";

const driftColor = drift !== "—" && Number(drift) < 0.75 ? "\x1b[31m" : "\x1b[32m";

const fragment = `[sprint:${active.slug} day ${day}/${appetite} ${phaseColor}${phase}${reset} gates:${gatesCount}✓ drift:${driftColor}${drift}${reset}]`;

process.stdout.write(fragment);
