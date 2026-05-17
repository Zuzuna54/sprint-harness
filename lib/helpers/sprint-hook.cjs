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
 *
 * See:
 *   .claude/skills/sprint-orchestrator/SKILL.md "Drift control responsibilities"
 *   /Users/gio/.claude/plans/hazy-gathering-kettle.md "Drift control architecture"
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
// mode: "pre-bash" | "pre-edit" | "auto" (autodetect from input)

// ── Helpers ──────────────────────────────────────────────────────────────────

function allow() {
  process.exit(0);
}
function block(reason) {
  process.stderr.write(`BLOCK ${reason}\n`);
  process.exit(2); // non-zero blocks the tool call
}

function readHookInput() {
  // Claude Code passes tool input as JSON via $hookInput env or stdin
  const envInput = process.env.hookInput || process.env.CLAUDE_HOOK_INPUT;
  if (envInput) {
    try {
      return JSON.parse(envInput);
    } catch {}
  }
  // Try stdin
  try {
    const raw = fs.readFileSync(0, "utf8");
    if (raw) return JSON.parse(raw);
  } catch {}
  return null;
}

function getActiveSprint() {
  // Branch-aware resolution (2026-05-17 multi-sprint parallel support).
  // Resolution chain:
  //   1. SPRINT_SLUG_OVERRIDE env var (explicit pick)
  //   2. Current git branch matches sprint/<slug>
  //   3. Fallback: most-recently-modified non-done sprint
  // Skips paused sprints (paused = no enforcement).
  const sprintsDir = path.join(REPO_ROOT, "docs", "sprints");
  if (!fs.existsSync(sprintsDir)) return null;

  const loadSprint = (slug) => {
    const statePath = path.join(sprintsDir, slug, "state.json");
    if (!fs.existsSync(statePath)) return null;
    try {
      const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
      if (state.phase === "done" || state.phase === "paused") return null;
      return { slug, state, statePath };
    } catch {
      return null;
    }
  };

  // 1. Env override
  if (process.env.SPRINT_SLUG_OVERRIDE) {
    const s = loadSprint(process.env.SPRINT_SLUG_OVERRIDE);
    if (s) return s;
  }

  // 2. Current git branch
  try {
    const branch = require("child_process")
      .execSync("git rev-parse --abbrev-ref HEAD", {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      })
      .trim();
    const m = branch.match(/^sprint\/(.+)$/);
    if (m) {
      const s = loadSprint(m[1]);
      if (s) return s;
    }
  } catch {}

  // 3. Fallback: most-recently-modified non-done sprint
  let active = null;
  let latest = 0;
  for (const d of fs.readdirSync(sprintsDir)) {
    if (d === "_template" || d === "README.md") continue;
    const statePath = path.join(sprintsDir, d, "state.json");
    if (!fs.existsSync(statePath)) continue;
    try {
      const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
      if (state.phase === "done" || state.phase === "paused") continue;
      const mtime = fs.statSync(statePath).mtimeMs;
      if (mtime > latest) {
        latest = mtime;
        active = { slug: d, state, statePath };
      }
    } catch {}
  }
  return active;
}

function getPartial(slug) {
  try {
    const p = path.join(REPO_ROOT, "docs", "sprints", slug, "spec.partial.json");
    if (!fs.existsSync(p)) return null;
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return null;
  }
}

// ── Forbidden-action check (pre-bash) ────────────────────────────────────────

const FORBIDDEN_PATTERNS = [
  /\bgit\s+push\b/i, // any git push during a sprint — PR flow only
  /\bpulumi\s+up\b/i, // deploy requires the <BRAND_SLUG>-deploy workflow gate
  /\bpulumi\s+destroy\b/i, // never
  /\brm\s+-rf\s+\//, // catastrophic
  /\brm\s+-rf\s+\.\b/, // also bad
  /\bdrop\s+table\b/i, // raw DROP TABLE outside tests
  /\bdelete\s+from\b(?!.*test)/i, // raw DELETE FROM outside test files (best-effort regex)
];

function checkBash(active, input) {
  // input may be { command: "..." } or { tool_input: { command } }
  const command = input?.command || input?.tool_input?.command || input?.input?.command || "";
  if (!command) return allow();

  // Allow if BYPASS env set
  if (process.env.SPRINT_DRIFT_BYPASS === "1") {
    process.stderr.write(`[sprint-hook] BYPASS=1 — allowing\n`);
    return allow();
  }

  for (const pat of FORBIDDEN_PATTERNS) {
    if (pat.test(command)) {
      return block(
        `Forbidden during sprint ${active.slug}: \`${command.slice(0, 80)}\` matches ${pat}. ` +
          `Use PR flow for code merges, <BRAND_SLUG>-deploy workflow for deploys, soft-delete for data. ` +
          `Bypass with SPRINT_DRIFT_BYPASS=1.`
      );
    }
  }

  return allow();
}

// ── Out-of-scope file check (pre-edit) ───────────────────────────────────────

function checkEdit(active, input) {
  // input may be { file_path: "..." } or { tool_input: { file_path } } or { input: { file_path } }
  const filePath =
    input?.file_path ||
    input?.tool_input?.file_path ||
    input?.input?.file_path ||
    input?.file ||
    "";
  if (!filePath) return allow();

  // Always-allowed paths: sprint dir itself, test files, the spec file, CLAUDE.md
  const slug = active.slug;
  const alwaysAllowed = [
    new RegExp(`^docs/sprints/${slug}/`),
    new RegExp(`\\.test\\.[jt]sx?$`),
    new RegExp(`__tests__/`),
    new RegExp(`^CLAUDE\\.md$`),
    new RegExp(`^.*/CLAUDE\\.md$`),
    new RegExp(`^docs/`), // doc edits never count as drift
  ];

  // Strip repo root prefix
  const rel = filePath.startsWith("/") ? path.relative(REPO_ROOT, filePath) : filePath;

  for (const r of alwaysAllowed) {
    if (r.test(rel)) return allow();
  }

  // BYPASS
  if (process.env.SPRINT_DRIFT_BYPASS === "1") {
    process.stderr.write(`[sprint-hook] BYPASS=1 — allowing\n`);
    return allow();
  }

  // Phases where out-of-scope check applies: post spec-lock
  if (active.state.phase === "spec-wizard" || active.state.phase === "spec-locked-pending-review") {
    return allow(); // wizard phase — spec not finalized
  }

  // Look up spec's "files touched" list
  const partial = getPartial(slug);
  const filesTouched = collectFilesTouched(partial, active.state);

  if (filesTouched.length === 0) {
    // No spec yet — allow but log
    process.stderr.write(`[sprint-hook] no files_touched in state — allowing ${rel}\n`);
    return allow();
  }

  // Check if rel matches any pattern (exact match or glob prefix)
  if (matchesAny(rel, filesTouched)) return allow();

  // Out of scope — block with prompt
  return block(
    `Out-of-scope edit during sprint ${active.slug}: \`${rel}\` is not in spec's \`Files touched\` list. ` +
      `Options: (a) amend spec — run \`bash scripts/sprint-amend-spec.sh\`; ` +
      `(b) skip this edit; (c) override once with SPRINT_DRIFT_BYPASS=1.`
  );
}

function collectFilesTouched(partial, state) {
  const list = new Set();
  // From state.files_touched (set at spec-lock)
  if (state?.files_touched && Array.isArray(state.files_touched)) {
    for (const f of state.files_touched) list.add(f);
  }
  // From partial.sections_answers.H.files_touched
  const H = partial?.sections_answers?.H;
  if (H?.files_touched) {
    for (const f of Array.isArray(H.files_touched) ? H.files_touched : [H.files_touched]) {
      if (typeof f === "string") list.add(f);
    }
  }
  // From any section's `files` field
  for (const sec of Object.values(partial?.sections_answers || {})) {
    if (sec?.files && Array.isArray(sec.files)) for (const f of sec.files) list.add(f);
  }
  return Array.from(list);
}

function matchesAny(filePath, patterns) {
  for (const pat of patterns) {
    if (!pat) continue;
    // Treat trailing /** or /* as glob-prefix
    if (pat.endsWith("/**") || pat.endsWith("/*")) {
      const prefix = pat.replace(/\/(\*\*?)$/, "/");
      if (filePath.startsWith(prefix)) return true;
    }
    // Exact match
    if (filePath === pat) return true;
    // Directory prefix
    if (pat.endsWith("/") && filePath.startsWith(pat)) return true;
    // Token match (file path contains pattern)
    if (pat.length > 5 && filePath.includes(pat)) return true;
  }
  return false;
}

// ── Entry ────────────────────────────────────────────────────────────────────

const active = getActiveSprint();
if (!active) return allow(); // no sprint → no enforcement

const input = readHookInput();
if (!input) return allow(); // can't parse → fail open

const detectedMode =
  mode === "auto"
    ? input.tool === "Bash" || input.tool_name === "Bash"
      ? "pre-bash"
      : "pre-edit"
    : mode;

if (detectedMode === "pre-bash") {
  checkBash(active, input);
} else if (detectedMode === "pre-edit") {
  checkEdit(active, input);
} else {
  allow();
}
