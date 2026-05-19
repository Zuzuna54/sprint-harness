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

const CACHE_TTL_MS = 300000; // 5 minutes
let _cache = { sprint: null, ts: 0 };
function cachedActiveSprint() {
  if (_cache.sprint && Date.now() - _cache.ts < CACHE_TTL_MS) return _cache.sprint;
  const s = getActiveSprintUncached();
  _cache = { sprint: s, ts: Date.now() };
  return s;
}
function clearSprintCache() { _cache = { sprint: null, ts: 0 }; }

const SLUG_RE = /^[a-z0-9-]{3,64}$/;
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

// Sprint harness-parallel-safety-v2 AC-2 / AC-12 — Resolution chain v2:
//   1. --slug arg parsed from Bash command (read by caller)
//   2. SPRINT_SLUG_OVERRIDE env var (explicit pick, with audit log)
//   3. ~/.claude/sessions/<CLAUDE_SESSION_ID>/sprint-slug file
//      - if pointed-to sprint is phase=done, remove the file (AC-12 stale check)
//      - and FALL THROUGH to the next step
//   4. Current git branch matches sprint/<slug> (legacy)
//   5. RETURN NULL — no mtime fallback. Callers decide what to do.
// Skips paused sprints (paused = no enforcement).

function validateSlug(slug) {
  return typeof slug === "string" && SLUG_RE.test(slug);
}

function loadSprint(slug) {
  if (!validateSlug(slug)) return null;
  const sprintsDir = path.join(REPO_ROOT, "docs", "sprints");
  const statePath = path.join(sprintsDir, slug, "state.json");
  if (!fs.existsSync(statePath)) return null;
  try {
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    if (state.phase === "done" || state.phase === "paused") return null;
    return { slug, state, statePath };
  } catch {
    return null;
  }
}

function getPhase(slug) {
  if (!validateSlug(slug)) return null;
  const statePath = path.join(REPO_ROOT, "docs", "sprints", slug, "state.json");
  if (!fs.existsSync(statePath)) return null;
  try {
    return JSON.parse(fs.readFileSync(statePath, "utf8")).phase;
  } catch {
    return null;
  }
}

function logOverride(slug) {
  // AC-2 follow-up F1: audit every SPRINT_SLUG_OVERRIDE use to retro.json
  // with ppid + tty + timestamp. Best-effort; never block on failure.
  try {
    const retroPath = path.join(REPO_ROOT, "docs", "sprints", slug, "retro.json");
    let retro = {};
    if (fs.existsSync(retroPath)) {
      try { retro = JSON.parse(fs.readFileSync(retroPath, "utf8")); } catch {}
    }
    retro.overrides = retro.overrides || [];
    retro.overrides.push({
      ts: new Date().toISOString(),
      ppid: process.ppid,
      tty: process.env.TTY || process.env.SSH_TTY || "",
      via: "SPRINT_SLUG_OVERRIDE",
    });
    fs.writeFileSync(retroPath, JSON.stringify(retro, null, 2));
  } catch {}
}

function sessionFilePath() {
  const sid = process.env.CLAUDE_SESSION_ID || process.env.CC_SESSION_ID;
  if (!sid) return null;
  return path.join(
    process.env.HOME || "/tmp",
    ".claude",
    "sessions",
    sid,
    "sprint-slug",
  );
}

function getActiveSprintUncached() {
  const sprintsDir = path.join(REPO_ROOT, "docs", "sprints");
  if (!fs.existsSync(sprintsDir)) return null;

  // 1. Bash --slug arg — surfaced by caller if applicable. (Inspected at call
  // site in checkBash; resolution-chain step is included for completeness.)
  // No-op here.

  // 2. Env override
  if (process.env.SPRINT_SLUG_OVERRIDE) {
    const slug = process.env.SPRINT_SLUG_OVERRIDE;
    if (validateSlug(slug)) {
      const s = loadSprint(slug);
      if (s) {
        logOverride(slug);
        return s;
      }
    } else {
      process.stderr.write(
        `[sprint-hook] SPRINT_SLUG_OVERRIDE=${slug} rejected (invalid slug format)\n`,
      );
    }
  }

  // 3. Session-file (AC-1 + AC-12 stale check)
  const sf = sessionFilePath();
  if (sf && fs.existsSync(sf)) {
    try {
      const slug = fs.readFileSync(sf, "utf8").trim();
      if (validateSlug(slug)) {
        const phase = getPhase(slug);
        if (phase === "done") {
          // AC-12: stale session-file — clean up + fall through
          try { fs.rmSync(sf); } catch {}
        } else {
          const s = loadSprint(slug);
          if (s) return s;
        }
      } else {
        try { fs.rmSync(sf); } catch {}
      }
    } catch {}
  }

  // 4. Current git branch (legacy)
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

  // 5. NO mtime fallback — return NULL. AC-2 enforces this.
  return null;
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
  /\bpulumi\s+up\b/i, // deploy requires the lifeos-deploy workflow gate
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
          `Use PR flow for code merges, lifeos-deploy workflow for deploys, soft-delete for data. ` +
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

const active = cachedActiveSprint();
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
