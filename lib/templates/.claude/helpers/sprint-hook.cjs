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
  /\bpulumi\s+up\b/i, // deploy requires the <BRAND_SLUG>-deploy workflow gate
  /\bpulumi\s+destroy\b/i, // never
  /\brm\s+-rf\s+\//, // catastrophic
  /\brm\s+-rf\s+\.\b/, // also bad
  /\bdrop\s+table\b/i, // raw DROP TABLE outside tests
  /\bdelete\s+from\b(?!.*test)/i, // raw DELETE FROM outside test files (best-effort regex)
];

// AC-5: Block inline jq writes to state.phase outside the canonical mutator.
// Only sprint-advance-phase.sh may set .phase. This pattern matches:
//   `jq '.phase = "X"'`        — dot syntax
//   `jq ".phase=\"X\""`         — different quoting
//   `jq '.["phase"] = "X"'`     — bracket syntax (T2.6 fix from security review S3)
//   `jq ".[\"phase\"]=\"X\""`   — bracket with double quotes
const JQ_PHASE_WRITE = /\bjq\b[^\n]{0,200}?(\.phase|\[["']phase["']\])\s*=/i;

// T2.7 fix from security review S3: catch Bash `sed -i ... state.json` and
// `> docs/sprints/.../state.json` redirects that bypass the Edit-tool path
// block. State.json mutations must go through atomic_update_state ONLY.
// Exception: sprint-advance-phase.sh writes via atomic-state.sh which uses
// `mv tmp state.json` (not `>`), so this regex doesn't false-positive.
//
// L2 (closure sprint Wave A): EXTENDED to cover broader interpreters
// (jq -f / python / node / awk / perl / ruby) reading from stdin/heredoc
// or via --in-place into state.json. Security review S3 follow-up.
const SED_OR_REDIRECT_TO_STATE_JSON = /(\bsed\b[^\n]{0,200}?(-i|--in-place)[^\n]{0,200}?docs\/sprints\/[^\s]*state\.json|>[>\s]*docs\/sprints\/[^\s]+state\.json)/;
const INTERPRETER_WRITE_TO_STATE_JSON = /\b(jq|python|python3|node|awk|gawk|perl|ruby)\b[^\n]{0,200}?(-f[^\n]{0,5}\/dev\/stdin|-i|--in-place|<<<|<<\s*['"]?EOF)[^\n]{0,200}?docs\/sprints\/[^\s]+state\.json/i;
// L15 (closure sprint Wave C): block rm/mv targeting state.json. State.json
// deletions/moves bypass every gate. Security review S14 follow-up.
const RM_OR_MV_STATE_JSON = /\b(rm|mv|trash|unlink)\b[^\n]{0,200}?docs\/sprints\/[^\s]+state\.json/i;

// AC-5: Parent-process check — verify SPRINT_ADVANCE_PHASE_RUNNING=1 came
// from a real sprint-advance-phase.sh invocation, not env spoof.
//
// L1 (closure sprint Wave A): in real Claude Code flow, the ppid chain may
// look like: claude-code → bash (wrapper) → bash (advance-phase.sh) → bash
// (atomic_update_state subshell) → jq. process.ppid points at the IMMEDIATE
// parent which may be a wrapper shell, not advance-phase.sh directly. Walk
// up to 3 ancestors looking for the canonical script. Security review S-CL6
// caps depth to 3 to prevent DoS from fork-bomb-like attacks.
function parentIsAdvancePhase() {
  if (process.env.SPRINT_ADVANCE_PHASE_RUNNING !== "1") return false;
  try {
    const { execSync } = require("node:child_process");
    let pid = process.ppid;
    for (let depth = 0; depth < 3; depth++) {
      if (!pid || pid <= 1) break;
      const cmd = execSync(
        `ps -o command= -p ${pid} 2>/dev/null || ps -o comm= -p ${pid} 2>/dev/null`,
        { encoding: "utf8" }
      ).trim();
      if (/sprint-advance-phase\.sh/.test(cmd)) return true;
      // Walk to parent of this PID (macOS + Linux both support `ps -o ppid=`)
      const nextPidStr = execSync(`ps -o ppid= -p ${pid} 2>/dev/null`, { encoding: "utf8" }).trim();
      pid = parseInt(nextPidStr, 10);
      if (Number.isNaN(pid)) break;
    }
    return false;
  } catch {
    // Best-effort — if ps fails, fall back to env-only (still safer than nothing)
    return process.env.SPRINT_ADVANCE_PHASE_RUNNING === "1";
  }
}

function checkBash(active, input) {
  // input may be { command: "..." } or { tool_input: { command } }
  const command = input?.command || input?.tool_input?.command || input?.input?.command || "";
  if (!command) return allow();

  // ── AC-5: jq state.phase write — only sprint-advance-phase.sh may do this ──
  if (JQ_PHASE_WRITE.test(command)) {
    if (parentIsAdvancePhase()) {
      // Sanctioned. Continue to forbidden-action check below.
    } else {
      return block(
        `Direct state.phase mutation blocked: \`${command.slice(0, 100)}\`. ` +
          `Only \`scripts/sprint-advance-phase.sh\` may write state.phase. ` +
          `Use: bash scripts/sprint-advance-phase.sh <next-phase>. ` +
          `Bypass requires SPRINT_BYPASS_GATE=<gate> SPRINT_BYPASS_WHY='<reason>' on the advance-phase invocation.`
      );
    }
  }

  // ── T2.7: sed/redirect to state.json — block from ANY caller (security review S3) ──
  if (SED_OR_REDIRECT_TO_STATE_JSON.test(command)) {
    return block(
      `Bash sed/redirect to state.json blocked: \`${command.slice(0, 100)}\`. ` +
        `State.json mutations MUST go through scripts/lib/atomic-state.sh::atomic_update_state ` +
        `to preserve atomicity + flock + .bak recovery. ` +
        `For phase transitions: bash scripts/sprint-advance-phase.sh <next-phase>. ` +
        `This block has NO env-bypass — even SPRINT_ADVANCE_PHASE_RUNNING=1 cannot allow direct sed/redirect on state.json.`
    );
  }

  // ── L2 (closure Wave A): broader interpreter writes to state.json blocked ──
  if (INTERPRETER_WRITE_TO_STATE_JSON.test(command)) {
    return block(
      `Interpreter write to state.json blocked: \`${command.slice(0, 100)}\`. ` +
        `Closes security review S3 follow-up — jq -f, python, awk, perl, ruby writing state.json all rejected. ` +
        `Use scripts/lib/atomic-state.sh::atomic_update_state.`
    );
  }

  // ── L15 (closure Wave C): rm/mv targeting state.json blocked ──
  if (RM_OR_MV_STATE_JSON.test(command)) {
    return block(
      `rm/mv targeting state.json blocked: \`${command.slice(0, 100)}\`. ` +
        `Closes security review S14 follow-up — state.json deletion bypasses every gate. ` +
        `If you genuinely need to delete a sprint, run sprint-end.sh OR remove the whole sprint dir, not just state.json.`
    );
  }

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

  // Strip repo root prefix
  const rel = filePath.startsWith("/") ? path.relative(REPO_ROOT, filePath) : filePath;

  // ── AC-5: state.json edit-block (always blocked, no env exemption) ─────────
  // Direct Write/Edit on docs/sprints/<slug>/state.json is forbidden. State
  // must be mutated only via scripts/lib/atomic-state.sh::atomic_update_state.
  if (/^docs\/sprints\/[^/]+\/state\.json$/.test(rel)) {
    return block(
      `Direct edit of state.json blocked: \`${rel}\`. ` +
        `Use scripts/lib/atomic-state.sh::atomic_update_state for any state mutation. ` +
        `Use scripts/sprint-advance-phase.sh for phase transitions. ` +
        `This block has NO env-bypass — state.json mutations must be atomic.`
    );
  }

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
