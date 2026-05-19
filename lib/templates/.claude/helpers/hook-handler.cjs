#!/usr/bin/env node
/**
 * Claude Flow Hook Handler (Cross-Platform)
 * Dispatches hook events to the appropriate helper modules.
 *
 * Usage: node hook-handler.cjs <command> [args...]
 *
 * Commands:
 *   route          - Route a task to optimal agent (reads PROMPT from env/stdin)
 *   pre-bash       - Validate command safety before execution
 *   post-edit      - Record edit outcome for learning
 *   session-restore - Restore previous session state
 *   session-end    - End session and persist state
 */

const path = require('path');
const fs = require('fs');

const helpersDir = __dirname;

function safeRequire(modulePath) {
  try {
    if (fs.existsSync(modulePath)) {
      const origLog = console.log;
      const origError = console.error;
      console.log = () => {};
      console.error = () => {};
      try {
        const mod = require(modulePath);
        return mod;
      } finally {
        console.log = origLog;
        console.error = origError;
      }
    }
  } catch (e) {}
  return null;
}

function getHandler(name) {
  switch (name) {
    case 'route': return [safeRequire(path.join(helpersDir, 'router.js')), safeRequire(path.join(helpersDir, 'intelligence.cjs'))];
    case 'post-edit': return [safeRequire(path.join(helpersDir, 'session.js')), safeRequire(path.join(helpersDir, 'intelligence.cjs'))];
    case 'post-bash': return [safeRequire(path.join(helpersDir, 'session.js'))];
    case 'session-restore': return [safeRequire(path.join(helpersDir, 'session.js')), safeRequire(path.join(helpersDir, 'intelligence.cjs'))];
    case 'session-end': return [safeRequire(path.join(helpersDir, 'session.js')), safeRequire(path.join(helpersDir, 'intelligence.cjs'))];
    case 'pre-task': return [safeRequire(path.join(helpersDir, 'router.js'))];
    case 'post-task': return [safeRequire(path.join(helpersDir, 'intelligence.cjs'))];
    case 'stats': return [safeRequire(path.join(helpersDir, 'intelligence.cjs'))];
    default: return [];
  }
}

// Get the command from argv
const [,, command, ...args] = process.argv;

// Read stdin with timeout — Claude Code sends hook data as JSON via stdin.
// Timeout prevents hanging when stdin is not properly closed (common on Windows).
async function readStdin() {
  if (process.stdin.isTTY) return '';
  return new Promise((resolve) => {
    let data = '';
    const timer = setTimeout(() => {
      process.stdin.removeAllListeners();
      process.stdin.pause();
      resolve(data);
    }, 500);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => { clearTimeout(timer); resolve(data); });
    process.stdin.on('error', () => { clearTimeout(timer); resolve(data); });
    process.stdin.resume();
  });
}

async function main() {
  // Enforce HOOK_BUDGET_MS to prevent hooks from bloating context.
  // Budget is per-hook, not per-invocation of the full handler chain.
  // Default 3000ms (3s); set HOOK_BUDGET_MS=0 to disable.
  const HOOK_BUDGET_MS = parseInt(process.env.HOOK_BUDGET_MS || '3000', 10);
  const startTime = Date.now();
  function budgetCheck() {
    if (HOOK_BUDGET_MS > 0 && Date.now() - startTime > HOOK_BUDGET_MS) {
      console.log('[WARN] hook-handler budget exceeded, exiting');
      process.exit(0);
    }
  }

  let stdinData = '';
  try { stdinData = await readStdin(); } catch (e) { /* ignore stdin errors */ }

  // Budget check after stdin read (cheap ops only from here)
  budgetCheck();

  let hookInput = {};
  if (stdinData.trim()) {
    try { hookInput = JSON.parse(stdinData); } catch (e) { /* ignore parse errors */ }
  }

  // Merge stdin data into prompt resolution: prefer stdin fields, then env, then argv
  const prompt = hookInput.prompt || hookInput.command || hookInput.toolInput
    || process.env.PROMPT || process.env.TOOL_INPUT_command || args.join(' ') || '';

// Token-burn audit item #8: 30s cache on intelligence.getContext + skip
// hardcoded routing-recommendation table (~200 tokens of theater per prompt).
const _routeCache = { ctx: null, ts: 0 };
const ROUTE_CACHE_TTL_MS = 30000;

const handlers = {
  'route': () => {
    // Skip everything for trivial prompts (< 20 chars) — system messages,
    // tool acks, etc. — they don't need intelligence routing.
    if (!prompt || prompt.length < 20) return;
    const [router, intelligence] = getHandler('route');
    if (intelligence && intelligence.getContext) {
      try {
        if (Date.now() - _routeCache.ts < ROUTE_CACHE_TTL_MS && _routeCache.ctx) {
          console.log(_routeCache.ctx);
        } else {
          const ctx = intelligence.getContext(prompt);
          if (ctx) {
            _routeCache.ctx = ctx;
            _routeCache.ts = Date.now();
            console.log(ctx);
          }
        }
      } catch (e) { /* non-fatal */ }
    }
    // Only emit a one-line routing hint, not the 25-line theatrical table.
    // The original table was 80% hardcoded (latency, success probability,
    // alternative agents, semantic match percentages were all static).
    if (router && router.routeTask) {
      try {
        const result = router.routeTask(prompt);
        console.log(`[INFO] Routing → ${result.agent} (${(result.confidence * 100).toFixed(0)}% — ${result.reason.substring(0, 60)})`);
      } catch {}
    }
    return;
    // eslint-disable-next-line no-unreachable
    if (router && router.routeTask) {
      // unreachable — superseded by the early return above
    } else {
      console.log('[INFO] Router not available, using default routing');
    }
  },

  'pre-bash': () => {
    const cmd = (hookInput.command || prompt).toLowerCase();
    const dangerous = ['rm -rf /', 'format c:', 'del /s /q c:\\', ':(){:|:&};:'];
    for (const d of dangerous) {
      if (cmd.includes(d)) {
        console.error(`[BLOCKED] Dangerous command detected: ${d}`);
        process.exit(1);
      }
    }
    console.log('[OK] Command validated');
  },

  'post-edit': () => {
    const [session, intelligence] = getHandler('post-edit');
    if (session && session.metric) {
      try { session.metric('edits'); } catch (e) { /* no active session */ }
    }
    if (intelligence && intelligence.recordEdit) {
      try {
        const file = hookInput.file_path || (hookInput.toolInput && hookInput.toolInput.file_path)
          || process.env.TOOL_INPUT_file_path || args[0] || '';
        intelligence.recordEdit(file);
      } catch (e) { /* non-fatal */ }
    }
    console.log('[OK] Edit recorded');
  },

  'post-bash': () => {
    const [session] = getHandler('post-bash');
    if (session && session.metric) {
      try { session.metric('bash'); } catch (e) { /* no active session */ }
    }
    console.log('[OK] Bash completed');
  },

  'session-restore': () => {
    const [session, intelligence] = getHandler('session-restore');
    if (session) {
      const existing = session.restore && session.restore();
      if (!existing) session.start && session.start();
    } else {
      const sessionId = `session-${Date.now()}`;
      console.log(`[INFO] Restoring session: %SESSION_ID%`);
      console.log('');
      console.log(`[OK] Session restored from %SESSION_ID%`);
      console.log(`New session ID: ${sessionId}`);
      console.log('');
      console.log('Restored State');
      console.log('+----------------+-------+');
      console.log('| Item           | Count |');
      console.log('+----------------+-------+');
      console.log('| Tasks          |     0 |');
      console.log('| Agents         |     0 |');
      console.log('| Memory Entries |     0 |');
      console.log('+----------------+-------+');
    }
    if (intelligence && intelligence.init) {
      try {
        const result = intelligence.init();
        if (result && result.nodes > 0) {
          console.log(`[INTELLIGENCE] Loaded ${result.nodes} patterns, ${result.edges} edges`);
        }
      } catch (e) { /* non-fatal */ }
    }
  },

  'session-end': () => {
    const [session, intelligence] = getHandler('session-end');
    if (intelligence && intelligence.consolidate) {
      try {
        const result = intelligence.consolidate();
        if (result && result.entries > 0) {
          console.log(`[INTELLIGENCE] Consolidated: ${result.entries} entries, ${result.edges} edges${result.newEntries > 0 ? `, ${result.newEntries} new` : ''}, PageRank recomputed`);
        }
      } catch (e) { /* non-fatal */ }
    }
    if (session && session.end) {
      session.end();
    } else {
      console.log('[OK] Session ended');
    }
  },

  'pre-task': () => {
    const [router] = getHandler('pre-task');
    if (session && session.metric) {
      try { session.metric('tasks'); } catch (e) { /* no active session */ }
    }
    if (router && router.routeTask && prompt) {
      const result = router.routeTask(prompt);
      console.log(`[INFO] Task routed to: ${result.agent} (confidence: ${result.confidence})`);
    } else {
      console.log('[OK] Task started');
    }
  },

  'post-task': () => {
    const [intelligence] = getHandler('post-task');
    if (intelligence && intelligence.feedback) {
      try { intelligence.feedback(true); } catch (e) { /* non-fatal */ }
    }
    console.log('[OK] Task completed');
  },

  'stats': () => {
    const [intelligence] = getHandler('stats');
    if (intelligence && intelligence.stats) {
      intelligence.stats(args.includes('--json'));
    } else {
      console.log('[WARN] Intelligence module not available. Run session-restore first.');
    }
  },
};

  // Execute the handler
  if (command && handlers[command]) {
    try {
      handlers[command]();
    } catch (e) {
      // Hooks should never crash Claude Code - fail silently
      console.log(`[WARN] Hook ${command} encountered an error: ${e.message}`);
    }
  } else if (command) {
    // Unknown command - pass through without error
    console.log(`[OK] Hook: ${command}`);
  } else {
    console.log('Usage: hook-handler.cjs <route|pre-bash|post-edit|session-restore|session-end|pre-task|post-task|stats>');
  }
}

// Hooks must ALWAYS exit 0 — Claude Code treats non-zero as "hook error"
// and skips all subsequent hooks for the event.
process.exitCode = 0;
main().catch((e) => {
  try { console.log(`[WARN] Hook handler error: ${e.message}`); } catch (_) {}
}).finally(() => {
  process.exit(0);
});
