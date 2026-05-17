#!/usr/bin/env node
/**
 * sprint-dashboard.mjs — Generate a local HTML dashboard for the active sprint.
 *
 * Writes docs/sprints/<slug>/dashboard.html with:
 *   - Hill chart (visual SVG)
 *   - AC checklist (with complex flags)
 *   - Drift timeline (per-commit scores)
 *   - Phase progression bar
 *   - Files-touched diff vs spec
 *   - Recent standup entries
 *
 * Auto-refresh: <meta http-equiv="refresh" content="60"> for dev box use.
 * Open in browser: open docs/sprints/<slug>/dashboard.html
 *
 * Usage:
 *   sprint-dashboard.mjs <slug>          # write dashboard.html, print path
 *   sprint-dashboard.mjs <slug> --open   # also open in default browser
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const [, , slugArg, ...flags] = process.argv;
if (!slugArg) {
  console.error("Usage: sprint-dashboard.mjs <slug> [--open]");
  process.exit(1);
}

const slug = slugArg;
const open = flags.includes("--open");
const sprintDir = join(REPO_ROOT, "docs", "sprints", slug);
const dashboardPath = join(sprintDir, "dashboard.html");

if (!existsSync(sprintDir)) {
  console.error(`[!] Sprint dir not found: ${sprintDir}`);
  process.exit(1);
}

const state = JSON.parse(readFileSync(join(sprintDir, "state.json"), "utf8"));
const partial = existsSync(join(sprintDir, "spec.partial.json"))
  ? JSON.parse(readFileSync(join(sprintDir, "spec.partial.json"), "utf8"))
  : null;

// Parse spec for ACs
const acs = [];
if (existsSync(join(sprintDir, "spec.md"))) {
  const spec = readFileSync(join(sprintDir, "spec.md"), "utf8");
  const matches = [...spec.matchAll(/\*\*AC-(\d+)\*\*\s*`?complex:\s*(true|false)`?/g)];
  for (const m of matches) {
    acs.push({
      id: `AC-${m[1]}`,
      complex: m[2] === "true",
      closed: (state.acs_closed_ids || []).includes(`AC-${m[1]}`),
    });
  }
}

// Phase progression
const phases = [
  "spec-wizard",
  "spec-locked",
  "design-locked",
  "building",
  "verifying",
  "pre-deploy",
  "deploying",
  "done",
];
const phaseIdx = phases.indexOf(state.phase);
const progress = phaseIdx >= 0 ? ((phaseIdx + 1) / phases.length) * 100 : 0;

// Drift timeline
const driftPoints = (state.drift_events || []).map((e) => ({
  at: e.at,
  score: e.score,
  msg: (e.msg || "").slice(0, 80),
}));

// Hill chart positions
const hillGroups = {
  uphill: acs.filter((a) => !a.closed),
  done: acs.filter((a) => a.closed),
};

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="refresh" content="60" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Sprint Dashboard: ${slug}</title>
  <style>
    :root { color-scheme: light dark; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Mono", Monaco, monospace;
      background: #0a0a0a;
      color: #e0e0e0;
      max-width: 1100px;
      margin: 2rem auto;
      padding: 0 1.5rem;
      line-height: 1.6;
    }
    h1, h2, h3 { color: #fff; font-weight: 600; }
    h1 { border-bottom: 1px solid #333; padding-bottom: 0.5rem; }
    .meta { color: #888; font-size: 0.9rem; }
    .grid { display: grid; gap: 1.5rem; grid-template-columns: 1fr 1fr; margin: 1.5rem 0; }
    .card {
      background: #141414;
      border: 1px solid #222;
      border-radius: 8px;
      padding: 1.25rem 1.5rem;
    }
    .card.full { grid-column: 1 / -1; }
    .progress-bar {
      width: 100%; height: 24px;
      background: #222; border-radius: 4px;
      overflow: hidden; margin: 0.5rem 0;
    }
    .progress-fill {
      height: 100%;
      background: linear-gradient(90deg, #4ade80, #22d3ee);
      width: ${progress}%;
      transition: width 0.3s;
    }
    .phase-list {
      display: flex; gap: 0.5rem; flex-wrap: wrap; font-size: 0.85rem;
      margin-top: 0.5rem;
    }
    .phase-pill {
      padding: 0.2rem 0.6rem; border-radius: 999px;
      border: 1px solid #333; color: #666;
    }
    .phase-pill.done { background: #14532d; color: #4ade80; border-color: #166534; }
    .phase-pill.current { background: #1e3a8a; color: #93c5fd; border-color: #1d4ed8; font-weight: 600; }
    .ac-list { list-style: none; padding: 0; }
    .ac-item {
      display: flex; align-items: center; gap: 0.6rem;
      padding: 0.4rem 0; border-bottom: 1px solid #1a1a1a;
    }
    .ac-item:last-child { border-bottom: none; }
    .ac-check { font-size: 1.1rem; width: 1.2rem; }
    .ac-id { font-weight: 600; min-width: 4rem; }
    .ac-tag {
      font-size: 0.75rem; padding: 0.1rem 0.4rem; border-radius: 3px;
      background: #2c1810; color: #fbbf24;
    }
    .drift-timeline {
      display: flex; align-items: flex-end; gap: 4px;
      height: 80px; margin-top: 0.5rem; padding: 0.5rem;
      background: #0d0d0d; border-radius: 4px;
    }
    .drift-bar {
      flex: 1; min-width: 6px;
      background: #4ade80;
      border-radius: 2px 2px 0 0;
      transition: height 0.3s;
    }
    .drift-bar.low { background: #ef4444; }
    .hill-svg { width: 100%; height: 180px; }
    .hill-svg path { fill: none; stroke: #555; stroke-width: 2; }
    .hill-dot { fill: #4ade80; }
    .hill-dot.complex { fill: #f59e0b; }
    .hill-dot.todo { fill: #6b7280; }
    code { background: #1a1a1a; padding: 0.1rem 0.3rem; border-radius: 3px; }
    .footer { color: #555; font-size: 0.85rem; margin-top: 2rem; text-align: center; }
  </style>
</head>
<body>
  <h1>🚀 Sprint: ${slug}</h1>
  <div class="meta">
    Phase: <code>${state.phase}</code> · Day ${state.day || 0}/${state.appetite_days || 14} ·
    Gates: ${(state.gates_passed || []).join(", ") || "(none)"} ·
    Auto-refresh: 60s
  </div>

  <div class="card full">
    <h3>Phase progression</h3>
    <div class="progress-bar"><div class="progress-fill"></div></div>
    <div class="phase-list">
      ${phases
        .map(
          (p, i) =>
            `<span class="phase-pill ${i < phaseIdx ? "done" : i === phaseIdx ? "current" : ""}">${p}</span>`
        )
        .join("")}
    </div>
  </div>

  <div class="grid">
    <div class="card">
      <h3>Hill chart</h3>
      <svg class="hill-svg" viewBox="0 0 600 180" preserveAspectRatio="xMidYMid meet">
        <path d="M 30 150 Q 300 -20, 570 150" />
        <text x="30" y="170" fill="#888" font-size="11">Figuring out</text>
        <text x="500" y="170" fill="#888" font-size="11">Making it happen</text>
        ${acs
          .map((ac, i) => {
            const x = ac.closed ? 540 + (i % 3) * 12 : 80 + (i % 8) * 30;
            const y = ac.closed ? 145 : Math.max(40, 145 - (i % 4) * 20);
            const cls = ac.closed ? "" : ac.complex ? "complex" : "todo";
            return `<circle class="hill-dot ${cls}" cx="${x}" cy="${y}" r="6"><title>${ac.id}${ac.complex ? " (complex)" : ""}</title></circle>`;
          })
          .join("")}
      </svg>
      <div class="meta">
        🟢 done (${hillGroups.done.length}) ·
        🟠 complex (${acs.filter((a) => a.complex && !a.closed).length}) ·
        ⚪ in progress (${acs.filter((a) => !a.complex && !a.closed).length})
      </div>
    </div>

    <div class="card">
      <h3>Acceptance criteria (${acs.filter((a) => a.closed).length}/${acs.length})</h3>
      <ul class="ac-list">
        ${
          acs.length === 0
            ? '<li class="ac-item"><em>No ACs yet — wizard still running?</em></li>'
            : acs
                .map(
                  (a) =>
                    `<li class="ac-item">
            <span class="ac-check">${a.closed ? "✅" : "⏳"}</span>
            <span class="ac-id">${a.id}</span>
            ${a.complex ? '<span class="ac-tag">complex · pair-mode</span>' : ""}
          </li>`
                )
                .join("")
        }
      </ul>
    </div>

    <div class="card">
      <h3>Drift timeline (last ${Math.min(driftPoints.length, 50)} commits)</h3>
      <div class="drift-timeline">
        ${
          driftPoints.length === 0
            ? '<span style="color:#666; font-size: 0.85rem;">No drift events yet</span>'
            : driftPoints
                .slice(-50)
                .map((d) => {
                  const h = d.score * 80;
                  const low = d.score < 0.75 ? "low" : "";
                  return `<div class="drift-bar ${low}" style="height:${h}px" title="${d.at}: ${d.score} — ${d.msg}"></div>`;
                })
                .join("")
        }
      </div>
      <div class="meta">Threshold: 0.75 (bars below this are red — drift detected)</div>
    </div>

    <div class="card">
      <h3>Drift events (recent)</h3>
      ${
        driftPoints.length === 0
          ? '<em style="color:#666">None — sprint stayed within spec.</em>'
          : `<ul style="padding-left: 1.2rem; font-size: 0.85rem;">${driftPoints
              .slice(-5)
              .map(
                (d) =>
                  `<li><code>${d.at}</code> score=${d.score}<br><em style="color:#888">${d.msg}</em></li>`
              )
              .join("")}</ul>`
      }
    </div>
  </div>

  <div class="card full">
    <h3>Files touched (claims scope)</h3>
    <ul style="font-family: monospace; font-size: 0.85rem;">
      ${(state.files_touched || ["(set at spec-lock)"]).map((f) => `<li>${f}</li>`).join("")}
    </ul>
  </div>

  <div class="footer">
    Auto-refreshes every 60 seconds. Updated: ${new Date().toISOString()}<br>
    Source: <code>${dashboardPath.replace(REPO_ROOT + "/", "")}</code> ·
    Regenerate: <code>node scripts/sprint-dashboard.mjs ${slug}</code>
  </div>
</body>
</html>
`;

writeFileSync(dashboardPath, html);
console.log(`[+] Dashboard written: ${dashboardPath}`);

if (open) {
  try {
    execSync(`open "${dashboardPath}"`, { stdio: "inherit" });
  } catch {
    console.log(`[i] Could not auto-open; visit:`);
    console.log(`    file://${dashboardPath}`);
  }
}
