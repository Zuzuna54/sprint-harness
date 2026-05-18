#!/usr/bin/env node
/**
 * sprint-hook.cjs — Pre-tool-use enforcement when a sprint is active.
 *
 * Hooked into Claude Code settings.json:
 *   - PreToolUse:Bash → forbidden-action check
 *   - PreToolUse:Write|Edit|MultiEdit → out-of-scope file check
 *
 * Output: prints "BLOCK <reason>" to stderr + exits non-zero to block the tool
 *         call. Returns 0 to allow.
 *
 * Reads tool input from $hookInput env or stdin JSON.
 */

const fs = require("node:fs");
const path = require("node:path");
const { execSync } = require("node:child_process");

const REPO_ROOT = execSync("git rev-parse --show-toplevel", {
  encoding: "utf8",
  stdio: ["pipe", "pipe", "ignore"],
})
  .trim() || process.cwd();

const [, , mode = "auto"] = process.argv;

const CACHE_TTL_MS = 300000;
let _cache = { sprint: null, ts: 0 };
function cachedActiveSprint() {
  if (_cache.sprint && Date.now() - _cache.ts < CACHE_TTL_MS) return _cache.sprint;
  const s = getActiveSprintUncached();
  _cache = { sprint: s, ts: Date.now() };
  return s;
}
function clearSprintCache() { _cache = { sprint: null, ts: 0 }; }

const SLUG_RE = /^[a-z0-9-]{3,64}$/;

function allow() { process.exit(0); }
function block(reason) { process.stderr.write(`BLOCK ${reason}\n`); process.exit(2); }

function readHookInput() {
  const envInput = process.env.hookInput || process.env.CLAUDE_HOOK_INPUT;
  if (envInput) {
    try { return JSON.parse(envInput); } catch {}
  }
  try {
    const raw = fs.readFileSync(0, "utf8");
    if (raw) return JSON.parse(raw);
  } catch {}
  return null;
}

function validateSlug(slug) {
  return typeof slug === "string" && SLUG_RE.test(slug);
}

function loadSprint(slug) {
  if (!validateSlug(slug)) return null;
  const statePath = path.join(REPO_ROOT, "docs", "sprints", slug, "state.json");
  if (!fs.existsSync(statePath)) return null;
  try {
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    if (state.phase === "done" || state.phase === "paused") return null;
    return { slug, state, statePath };
  } catch { return null; }
}

function getPhase(slug) {
  if (!validateSlug(slug)) return null;
  const statePath = path.join(REPO_ROOT, "docs", "sprints", slug, "state.json");
  if (!fs.existsSync(statePath)) return null;
  try { return JSON.parse(fs.readFileSync(statePath, "utf8")).phase; } catch { return null; }
}

function logOverride(slug) {
  try {
    const retroPath = path.join(REPO_ROOT, "docs", "sprints", slug, "retro.json");
    let retro = {};
    if (fs.existsSync(retroPath)) {
      try { retro = JSON.parse(fs.readFileSync(retroPath, "utf8")); } catch {}
    }
    retro.overrides = retro.overrides || [];
    retro.overrides.push({ ts: new Date().toISOString(), ppid: process.ppid, tty: process.env.TTY || "", via: "SPRINT_SLUG_OVERRIDE" });
    fs.writeFileSync(retroPath, JSON.stringify(retro, null, 2));
  } catch {}
}

function sessionFilePath() {
  const sid = process.env.CLAUDE_SESSION_ID || process.env.CC_SESSION_ID;
  if (!sid) return null;
  return path.join(process.env.HOME || "/tmp", ".claude", "sessions", sid, "sprint-slug");
}

function getActiveSprintUncached() {
  const sprintsDir = path.join(REPO_ROOT, "docs", "sprints");
  if (!fs.existsSync(sprintsDir)) return null;

  if (process.env.SPRINT_SLUG_OVERRIDE) {
    const slug = process.env.SPRINT_SLUG_OVERRIDE;
    if (validateSlug(slug)) {
      const s = loadSprint(slug);
      if (s) { logOverride(slug); return s; }
    } else {
      process.stderr.write(`[sprint-hook] SPRINT_SLUG_OVERRIDE=${slug} rejected (invalid slug format)\n`);
    }
  }

  const sf = sessionFilePath();
  if (sf && fs.existsSync(sf)) {
    try {
      const slug = fs.readFileSync(sf, "utf8").trim();
      if (validateSlug(slug)) {
        const phase = getPhase(slug);
        if (phase === "done") { try { fs.rmSync(sf); } catch {} }
        else { const s = loadSprint(slug); if (s) return s; }
      } else { try { fs.rmSync(sf); } catch {} }
    } catch {}
  }

  try {
    const branch = require("child_process").execSync("git rev-parse --abbrev-ref HEAD", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    const m = branch.match(/^sprint\/(.+)$/);
    if (m) { const s = loadSprint(m[1]); if (s) return s; }
  } catch {}

  return null;
}

function getPartial(slug) {
  try {
    const p = path.join(REPO_ROOT, "docs", "sprints", slug, "spec.partial.json");
    if (!fs.existsSync(p)) return null;
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch { return null; }
}

const FORBIDDEN_PATTERNS = [
  /\bgit\s+push\b/i,
  /\bpulumi\s+up\b/i,
  /\bpulumi\s+destroy\b/i,
  /\brm\s+-rf\s+\//,
  /\brm\s+-rf\s+\.\b/,
  /\bdrop\s+table\b/i,
  /\bdelete\s+from\b(?!.*test)/i,
];

function checkBash(active, input) {
  const command = input?.command || input?.tool_input?.command || input?.input?.command || "";
  if (!command) return allow();
  if (process.env.SPRINT_DRIFT_BYPASS === "1") {
    process.stderr.write(`[sprint-hook] BYPASS=1 — allowing\n`); return allow();
  }
  for (const pat of FORBIDDEN_PATTERNS) {
    if (pat.test(command)) {
      return block(`Forbidden during sprint ${active.slug}: \`${command.slice(0, 80)}\` matches ${pat}. Use PR flow for code merges, lifeos-deploy workflow for deploys, soft-delete for data. Bypass with SPRINT_DRIFT_BYPASS=1.`);
    }
  }
  return allow();
}

function checkEdit(active, input) {
  const filePath = input?.file_path || input?.tool_input?.file_path || input?.input?.file_path || input?.file || "";
  if (!filePath) return allow();
  const slug = active.slug;
  const alwaysAllowed = [
    new RegExp(`^docs/sprints/${slug}/`),
    new RegExp(`\\.test\\.[jt]sx?$`),
    new RegExp(`__tests__/`),
    new RegExp(`^CLAUDE\\.md$`),
    new RegExp(`^.*/CLAUDE\\.md$`),
    new RegExp(`^docs/`),
  ];
  const rel = filePath.startsWith("/") ? path.relative(REPO_ROOT, filePath) : filePath;
  for (const r of alwaysAllowed) { if (r.test(rel)) return allow(); }
  if (process.env.SPRINT_DRIFT_BYPASS === "1") {
    process.stderr.write(`[sprint-hook] BYPASS=1 — allowing\n`); return allow();
  }
  if (active.state.phase === "spec-wizard" || active.state.phase === "spec-locked-pending-review") return allow();
  const partial = getPartial(slug);
  const filesTouched = collectFilesTouched(partial, active.state);
  if (filesTouched.length === 0) { process.stderr.write(`[sprint-hook] no files_touched in state — allowing ${rel}\n`); return allow(); }
  if (matchesAny(rel, filesTouched)) return allow();
  return block(`Out-of-scope edit during sprint ${active.slug}: \`${rel}\` is not in spec's \`Files touched\` list. Options: (a) amend spec — run \`bash scripts/sprint-amend-spec.sh\`; (b) skip this edit; (c) override once with SPRINT_DRIFT_BYPASS=1.`);
}

function collectFilesTouched(partial, state) {
  const list = new Set();
  if (state?.files_touched && Array.isArray(state.files_touched)) {
    for (const f of state.files_touched) list.add(f);
  }
  const H = partial?.sections_answers?.H;
  if (H?.files_touched) {
    for (const f of Array.isArray(H.files_touched) ? H.files_touched : [H.files_touched]) {
      if (typeof f === "string") list.add(f);
    }
  }
  for (const sec of Object.values(partial?.sections_answers || {})) {
    if (sec?.files && Array.isArray(sec.files)) for (const f of sec.files) list.add(f);
  }
  return Array.from(list);
}

function matchesAny(filePath, patterns) {
  for (const pat of patterns) {
    if (!pat) continue;
    if (pat.endsWith("/**") || pat.endsWith("/*")) {
      const prefix = pat.replace(/\/(\*\*?)$/, "/");
      if (filePath.startsWith(prefix)) return true;
    }
    if (filePath === pat) return true;
    if (pat.endsWith("/") && filePath.startsWith(pat)) return true;
    if (pat.length > 5 && filePath.includes(pat)) return true;
  }
  return false;
}

const active = cachedActiveSprint();
if (!active) return allow();
const input = readHookInput();
if (!input) return allow();
const detectedMode = mode === "auto"
  ? (input.tool === "Bash" || input.tool_name === "Bash" ? "pre-bash" : "pre-edit")
  : mode;
if (detectedMode === "pre-bash") checkBash(active, input);
else if (detectedMode === "pre-edit") checkEdit(active, input);
else allow();