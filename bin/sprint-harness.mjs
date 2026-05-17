#!/usr/bin/env node
/**
 * sprint-harness — installer CLI for @ordex/sprint-harness
 *
 * Subcommands:
 *   install [--non-interactive] [--target <dir>]   Install harness into target repo
 *   verify                                          Check all 71 ACs reachable in target
 *   doctor                                          Dependency health check
 *   uninstall                                       Revert install cleanly
 *   update [--from <version>]                       Update to latest, preserve customizations
 *
 * Locked premise: target machine has ONLY Claude Code installed. Installer
 * handles every other dependency.
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, copyFileSync, rmSync } from 'node:fs';
import { join, dirname, basename, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync, spawnSync } from 'node:child_process';
import { createInterface } from 'node:readline';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const PKG_ROOT = join(__dirname, '..');
const LIB = join(PKG_ROOT, 'lib');
// AC #3: read version from package.json instead of hardcoding
const PKG = JSON.parse(readFileSync(join(PKG_ROOT, 'package.json'), 'utf8'));
const HARNESS_VERSION = PKG.version;

// ── CLI args ─────────────────────────────────────────────────────────────────
const [, , cmd, ...rest] = process.argv;
const args = new Set(rest);
const nonInteractive = args.has('--non-interactive');
const targetDir = (() => {
  const i = rest.indexOf('--target');
  return i >= 0 ? rest[i + 1] : process.cwd();
})();

// ── Helpers ──────────────────────────────────────────────────────────────────
const log = (...m) => console.log(...m);
const ok = (...m) => console.log('  ✓', ...m);
const warn = (...m) => console.warn('  ⚠', ...m);
const err = (...m) => console.error('  ✗', ...m);

function which(bin) {
  try {
    return execSync(`command -v ${bin}`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

function version(bin, arg = '--version') {
  try {
    return execSync(`${bin} ${arg}`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim().split('\n')[0];
  } catch {
    return null;
  }
}

async function prompt(question, defaultYes = true) {
  if (nonInteractive) return defaultYes;
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${question} ${defaultYes ? '[Y/n]' : '[y/N]'} `, (a) => {
      rl.close();
      const trimmed = a.trim().toLowerCase();
      if (!trimmed) return resolve(defaultYes);
      resolve(trimmed === 'y' || trimmed === 'yes');
    });
  });
}

function detectPM(target) {
  if (existsSync(join(target, 'pnpm-lock.yaml'))) return 'pnpm';
  if (existsSync(join(target, 'yarn.lock'))) return 'yarn';
  if (existsSync(join(target, 'package-lock.json'))) return 'npm';
  return null;
}

// AC #5: Sonar / Sonar admin pw / future secrets go to $HOME/.sprint-harness/
function secretsDir() {
  const dir = join(process.env.HOME || '', '.sprint-harness');
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
    try { execSync(`chmod 0700 "${dir}"`); } catch {}
  }
  return dir;
}

// AC #10: WSL detection — Linux kernel with `microsoft` substring
function isWSL() {
  if (detectOS() !== 'linux') return false;
  try { return /microsoft/i.test(execSync('uname -r', { encoding: 'utf8' })); }
  catch { return false; }
}

function detectOS() {
  return process.platform === 'darwin' ? 'macos' : process.platform === 'linux' ? 'linux' : process.platform;
}

function copyTree(src, dest, opts = {}) {
  const { mergeMode = false } = opts;
  mkdirSync(dest, { recursive: true });
  for (const entry of readdirSync(src)) {
    const sp = join(src, entry), dp = join(dest, entry);
    if (statSync(sp).isDirectory()) {
      copyTree(sp, dp, opts);
    } else if (mergeMode && existsSync(dp)) {
      warn(`exists, kept (.bak created): ${relative(targetDir, dp)}`);
      copyFileSync(dp, dp + '.bak');
      copyFileSync(sp, dp);
    } else {
      copyFileSync(sp, dp);
    }
  }
}

// ── Subcommands ──────────────────────────────────────────────────────────────

function cmdDoctor() {
  log('═══ sprint-harness doctor ═══');
  log('');
  log('  Tier 1 (critical):');
  const tier1 = [
    ['claude (CLI)', 'claude', '--version'],
    ['node',         'node',   '--version'],
    ['git',          'git',    '--version'],
    ['jq',           'jq',     '--version'],
    ['pnpm or npm',  detectPM(targetDir) || 'npm', '--version'],
    ['ruflo',        'ruflo',  '--version'],
    ['husky',        existsSync(join(targetDir, '.husky')) ? 'husky-installed' : null, ''],
  ];
  let tier1Missing = 0;
  for (const [name, bin, arg] of tier1) {
    if (bin === 'husky-installed') { ok(`${name.padEnd(20)} installed`); continue; }
    if (!bin) { err(`${name.padEnd(20)} not installed (CRITICAL)`); tier1Missing++; continue; }
    const v = which(bin) ? version(bin, arg) : null;
    if (v) ok(`${name.padEnd(20)} ${v}`);
    else { err(`${name.padEnd(20)} not installed (CRITICAL)`); tier1Missing++; }
  }
  log('');

  // ruflo daemon
  try {
    const status = execSync('ruflo daemon status 2>&1', { encoding: 'utf8' });
    if (/RUNNING|active/i.test(status)) ok(`ruflo daemon         RUNNING`);
    else { warn(`ruflo daemon         NOT RUNNING — run: ruflo daemon start --workspace .`); }
  } catch { warn(`ruflo daemon         NOT RUNNING`); }
  log('');

  log('  Tier 2 (recommended):');
  for (const [name, bin] of [['gh', 'gh'], ['sonar-scanner', 'sonar-scanner'], ['docker', 'docker'], ['playwright', 'npx playwright']]) {
    const v = which(bin.split(' ')[0]) ? version(bin.split(' ')[0], '--version') : null;
    if (v) ok(`${name.padEnd(20)} ${v}`);
    else warn(`${name.padEnd(20)} not installed (optional)`);
  }
  log('');

  log('  Tier 3 (on-demand via dlx — verified at first use)');
  log('');

  // AC #4: Verify v0.3 installed surfaces match .sprintrc.json claims
  log('  Tier 2 installed surfaces (per .sprintrc.json):');
  const rcPath = join(targetDir, '.sprintrc.json');
  let surfaceMiss = 0;
  if (existsSync(rcPath)) {
    let rc = {};
    try { rc = JSON.parse(readFileSync(rcPath, 'utf8')); } catch {}
    // launchctl
    if (Array.isArray(rc.launchctl_loaded) && rc.launchctl_loaded.length) {
      try {
        const uid = execSync('id -u', { encoding: 'utf8' }).trim();
        const list = execSync(`launchctl print gui/${uid} 2>&1 || true`, { encoding: 'utf8' });
        const matched = rc.launchctl_loaded.filter((p) => list.includes(p.replace(/\.plist$/, '')));
        if (matched.length === rc.launchctl_loaded.length) ok(`launchctl plists    ${matched.length}/${rc.launchctl_loaded.length} loaded`);
        else { warn(`launchctl plists    ${matched.length}/${rc.launchctl_loaded.length} loaded`); surfaceMiss++; }
      } catch { warn(`launchctl plists    unable to verify`); }
    }
    // systemd
    if (Array.isArray(rc.systemd_loaded) && rc.systemd_loaded.length) {
      let active = 0;
      for (const unit of rc.systemd_loaded) {
        try { execSync(`systemctl --user is-active "${unit}" 2>&1 || true`, { stdio: 'pipe' }); active++; } catch {}
      }
      if (active === rc.systemd_loaded.length) ok(`systemd timers      ${active}/${rc.systemd_loaded.length} active`);
      else warn(`systemd timers      ${active}/${rc.systemd_loaded.length} active`);
    }
    // sonar token
    if (rc.sonar_token_path) {
      if (existsSync(rc.sonar_token_path)) ok(`sonar token         ${rc.sonar_token_path}`);
      else { err(`sonar token         missing at ${rc.sonar_token_path}`); surfaceMiss++; }
    }
    // playwright
    if (rc.playwright_installed) {
      const v = version('npx', '--version'); // proxy
      if (which('npx')) ok(`playwright          installed (recorded)`);
      else warn(`playwright          recorded installed but npx missing`);
    }
    // gh labels
    if (Array.isArray(rc.gh_labels_created) && rc.gh_labels_created.length) {
      ok(`gh labels           ${rc.gh_labels_created.join(', ')} (recorded)`);
    }
    // ruflo init
    if (rc.ruflo_init_ran === true) ok(`ruflo init          ran`);
    else if (rc.ruflo_init_ran === false) { err(`ruflo init          FAILED — run \`ruflo init\``); surfaceMiss++; }
    // mcp wire-up
    if (rc.mcp_configured === true) {
      const mcp = join(targetDir, '.mcp.json');
      if (existsSync(mcp)) {
        try {
          const j = JSON.parse(readFileSync(mcp, 'utf8'));
          if (j.mcpServers && j.mcpServers.ruflo) ok(`mcp .mcp.json       has ruflo entry`);
          else { err(`mcp .mcp.json       no ruflo entry`); surfaceMiss++; }
        } catch { err(`mcp .mcp.json       invalid JSON`); surfaceMiss++; }
      } else { err(`mcp .mcp.json       missing`); surfaceMiss++; }
    }
    // memory.db isolation
    if (rc.memoryStrategy === 'per-project') {
      const dbPath = join(targetDir, '.swarm/memory.db');
      if (existsSync(dbPath)) ok(`memory.db isolation .swarm/memory.db present`);
      else { warn(`memory.db isolation .swarm/memory.db missing`); }
    }
  } else {
    warn(`.sprintrc.json not found in target — run install first`);
  }
  log('');

  if (tier1Missing === 0 && surfaceMiss === 0) {
    log('  Result: TIER 1 COMPLETE ✓ — all 71 capabilities reachable');
    process.exit(0);
  } else {
    log(`  Result: ${tier1Missing} TIER 1 dep(s) missing, ${surfaceMiss} surface(s) degraded — run: npx @ordex/sprint-harness install`);
    process.exit(1);
  }
}

async function cmdInstall() {
  log('═══ sprint-harness install ═══');
  log(`  Target: ${targetDir}`);
  log(`  OS:     ${detectOS()}`);
  log('');

  // 1. Detect existing artifacts that the installer must NOT overwrite
  const existing = {
    husky: existsSync(join(targetDir, '.husky')),
    claudeSettings: existsSync(join(targetDir, '.claude/settings.json')),
    sprintsDir: existsSync(join(targetDir, 'docs/sprints')),
    sprintrc: existsSync(join(targetDir, '.sprintrc.json')),
  };
  if (existing.sprintrc) {
    err('Already installed (`.sprintrc.json` exists). Use `update` instead.');
    process.exit(1);
  }

  // AC #2: Brand prompts FIRST so subsequent steps can write into `config`
  log('Step 0 — Brand configuration');
  const config = await brandPrompts();
  log('');

  // AC #10: Windows native is unsupported. WSL2 falls through to Linux branch but
  // systemd-user may not be enabled; warn rather than block.
  if (process.platform === 'win32') {
    err('Windows native is not supported in v0.4. Use WSL2 with systemd enabled.');
    process.exit(2);
  }
  if (isWSL()) {
    warn('WSL2 detected — systemd-user step requires systemd enabled in /etc/wsl.conf');
  }

  // 2. Auto-install Tier 1 deps
  log('Step 1 — Verify/install Tier 1 deps');
  // AC #9: Tier 1 is hard-fail (node/git aren't 'instructive only' anymore — if they're
  // genuinely missing, downstream steps will crash with cryptic errors. Bail early.)
  for (const bin of ['node', 'git']) {
    if (!which(bin)) {
      err(`${bin} is required but not installed.`);
      log(`    macOS: brew install ${bin}`);
      log(`    Linux: sudo apt-get install -y ${bin}`);
      process.exit(2);
    }
    ok(`${bin.padEnd(20)} ${version(bin)}`);
  }
  await ensureDep('jq', detectOS() === 'macos' ? 'brew install jq' : 'sudo apt install -y jq');
  const pm = detectPM(targetDir) || 'pnpm';
  if (!which(pm)) await ensureDep(pm, `corepack enable && corepack prepare ${pm}@latest --activate`);
  await ensureDep('ruflo', 'npm install -g ruflo@latest');

  // AC #8: husky init can clobber package.json's `prepare` script. Snapshot first
  // and chain the previous prepare value if it gets overwritten.
  if (!existing.husky) {
    const pkgPath = join(targetDir, 'package.json');
    let preexistingPrepare = null;
    if (existsSync(pkgPath)) {
      try {
        const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
        preexistingPrepare = pkg.scripts && pkg.scripts.prepare ? pkg.scripts.prepare : null;
      } catch {}
    }
    await ensureDep('husky-init', `${pm === 'npm' ? 'npx' : pm + ' dlx'} husky init`);
    if (preexistingPrepare && existsSync(pkgPath)) {
      try {
        const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
        if (pkg.scripts && pkg.scripts.prepare === 'husky' && preexistingPrepare !== 'husky') {
          pkg.scripts.prepare = `${preexistingPrepare} && husky`;
          writeFileSync(pkgPath, JSON.stringify(pkg, null, 2));
          ok(`preserved existing prepare script: "${preexistingPrepare}" (chained husky)`);
          config.preexisting_prepare_script = preexistingPrepare;
        }
      } catch {}
    }
  }
  // Optional Tier 2 (prompt only)
  log('');
  log('Step 1b — Tier 2 deps (optional)');
  if (!which('gh')) {
    const proceed = await prompt('Install gh (GitHub CLI) for sprint-pr-body + sprint-gh-mirror?', false);
    if (proceed) await ensureDep('gh', detectOS() === 'macos' ? 'brew install gh' : 'see https://cli.github.com/');
  } else ok(`gh ${version('gh')}`);
  if (!which('sonar-scanner')) {
    const proceed = await prompt('Install sonar-scanner?', false);
    if (proceed) await ensureDep('sonar-scanner', 'brew install sonar-scanner');
  } else ok(`sonar-scanner present`);

  // AC-2: Docker auto-install (macOS)
  if (!which('docker')) {
    if (detectOS() === 'macos') {
      const proceed = await prompt('Install Docker Desktop via brew cask?', false);
      if (proceed) {
        try {
          execSync('brew install --cask docker', { stdio: 'inherit' });
          execSync('open -a Docker 2>&1 || true');
          let dockerUp = false;
          for (let i = 0; i < 15; i++) {
            try { execSync('docker info', { stdio: 'pipe' }); dockerUp = true; break; }
            catch { execSync('sleep 2'); }
          }
          if (dockerUp) ok('docker daemon RUNNING');
        } catch (e) { warn(`Docker install: ${e.message.split('\n')[0]}`); }
      }
    } else warn('docker missing — Linux: docs.docker.com/engine/install/');
  } else ok(`docker ${version('docker')}`);

  // AC-3 + AC #5 + AC #11: SonarQube bootstrap (idempotent across re-runs).
  //   - Token at $HOME/.sprint-harness/sonar-token (0600), NOT /tmp/.
  //   - Admin pw at $HOME/.sprint-harness/sonar-admin (0600).
  //   - Detects container state: not-exists / exists-stopped / exists-running.
  //   - If already-initialized (pw changed): read admin pw from secrets dir or prompt.
  if (which('docker') && which('sonar-scanner')) {
    try {
      execSync('docker info', { stdio: 'pipe' });
      const SECRETS = secretsDir();
      const ADMIN_PW_FILE = join(SECRETS, 'sonar-admin');
      const TOKEN_FILE = join(SECRETS, 'sonar-token');
      let containerState = 'not-exists';
      try {
        const out = execSync('docker ps -a --filter name=^/sonarqube$ --format "{{.Names}}:{{.State}}"', { encoding: 'utf8' }).trim();
        if (out) containerState = out.includes(':running') ? 'running' : 'stopped';
      } catch {}

      if (containerState === 'not-exists') {
        const proceed = await prompt('Bootstrap SonarQube container?', false);
        if (proceed) {
          execSync('docker run -d --name sonarqube -p 9000:9000 -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true sonarqube:community', { stdio: 'inherit' });
          containerState = 'running';
        }
      } else if (containerState === 'stopped') {
        execSync('docker start sonarqube', { stdio: 'inherit' });
        containerState = 'running';
        ok('SonarQube container restarted');
      } else ok('SonarQube container already running');

      if (containerState === 'running') {
        log('  Waiting for Sonar UP (~60s)...');
        for (let i = 0; i < 60; i++) {
          try { if (execSync('curl -s http://localhost:9000/api/system/status', { encoding: 'utf8' }).includes('"UP"')) { ok('Sonar UP'); break; } } catch {}
          execSync('sleep 2');
        }
        // Determine admin password — read cached or attempt change_password from admin:admin
        let adminPw = null;
        if (existsSync(ADMIN_PW_FILE)) {
          try { adminPw = readFileSync(ADMIN_PW_FILE, 'utf8').trim(); } catch {}
        }
        if (!adminPw) {
          try {
            const newPw = `sh-admin-${Date.now().toString(36)}`;
            const out = execSync(`curl -s -o /dev/null -w "%{http_code}" -u admin:admin -X POST "http://localhost:9000/api/users/change_password" -d "login=admin&password=${newPw}&previousPassword=admin"`, { encoding: 'utf8' });
            if (out.startsWith('2')) {
              writeFileSync(ADMIN_PW_FILE, newPw);
              execSync(`chmod 0600 "${ADMIN_PW_FILE}"`);
              adminPw = newPw;
              ok(`Sonar admin pw → ${ADMIN_PW_FILE}`);
            }
          } catch {}
        }
        if (adminPw) {
          try {
            const t = (execSync(`curl -s -u admin:${adminPw} -X POST "http://localhost:9000/api/user_tokens/generate?name=sh-${Date.now()}"`, { encoding: 'utf8' }).match(/"token":"([^"]+)"/) || [])[1];
            if (t) {
              writeFileSync(TOKEN_FILE, t);
              execSync(`chmod 0600 "${TOKEN_FILE}"`);
              ok(`Sonar token → ${TOKEN_FILE}`);
              config.sonar_token_path = TOKEN_FILE;
            } else warn('Sonar token generation returned empty');
          } catch (e) { warn(`Sonar token: ${e.message.split('\n')[0]}`); }
        } else warn('Sonar admin password unknown — set $HOME/.sprint-harness/sonar-admin manually');
      }
    } catch { warn('docker daemon down — Sonar skipped'); }
  }

  // AC-6: Playwright
  const proceedPw = await prompt('Install Playwright browsers?', false);
  if (proceedPw) {
    try {
      execSync(`${pm === 'npm' ? 'npx' : pm + ' dlx'} playwright install`, { cwd: targetDir, stdio: 'inherit' });
      ok('Playwright installed');
      config.playwright_installed = true;
    } catch (e) { warn(`Playwright: ${e.message.split('\n')[0]}`); }
  }
  log('');

  // 4. Copy files (with template substitution)
  log('Step 3 — Copy harness into target');
  copyWithSubstitution(join(LIB, 'scripts'),  join(targetDir, 'scripts'),       config);
  copyWithSubstitution(join(LIB, 'workflows'), join(targetDir, 'docs/workflows'), config);
  copyWithSubstitution(join(LIB, 'skills'),   join(targetDir, '.claude/skills'), config);
  copyWithSubstitution(join(LIB, 'helpers'),  join(targetDir, '.claude/helpers'), config);
  copyWithSubstitution(join(LIB, 'templates/sprints'), join(targetDir, 'docs/sprints'), config);
  // AC-12/AC-13: GH Actions YAMLs into .github/workflows/
  if (existsSync(join(LIB, 'templates/github/workflows'))) {
    copyWithSubstitution(join(LIB, 'templates/github/workflows'), join(targetDir, '.github/workflows'), config);
  }
  // AC C2: 6 custom subagents into .claude/agents/
  if (existsSync(join(LIB, 'templates/agents'))) {
    copyWithSubstitution(join(LIB, 'templates/agents'), join(targetDir, '.claude/agents'), config);
    ok('copied 6 custom agents → .claude/agents/');
  }
  // AC C3: autopilot configs into .claude-flow/autopilot/
  if (existsSync(join(LIB, 'templates/claude-flow/autopilot'))) {
    copyWithSubstitution(join(LIB, 'templates/claude-flow/autopilot'), join(targetDir, '.claude-flow/autopilot'), config);
    ok('copied 3 autopilot configs → .claude-flow/autopilot/');
  }
  ok(`copied scripts, workflows, skills, helpers, sprint docs, GH Action YAMLs, agents, autopilot configs`);
  log('');

  // 5. Merge husky hooks
  log('Step 4 — Merge husky hooks');
  for (const hook of ['pre-commit', 'post-commit', 'pre-push', 'post-merge']) {
    mergeHusky(join(LIB, 'templates/husky', hook), join(targetDir, '.husky', hook));
  }
  log('');

  // 6. Merge .claude/settings.json hooks
  log('Step 5 — Merge .claude/settings.json hooks');
  mergeClaudeSettings(join(targetDir, '.claude/settings.json'));
  log('');

  // 7. Install launchd plists (macOS only)
  if (detectOS() === 'macos') {
    log('Step 6 — Install launchd plists (macOS)');
    installLaunchdPlists(config);
    log('');
  } else {
    warn('Step 6 — Linux/Windows: instructive only. See docs/PREREQUISITES.md');
    log('');
  }

  // 8. Write .sprintrc.json
  log('Step 7 — Write .sprintrc.json');
  writeFileSync(join(targetDir, '.sprintrc.json'), JSON.stringify({
    ...config,
    os: detectOS(),
    packageManager: pm,
    installedAt: new Date().toISOString(),
    installedDeps: ['ruflo', 'jq', 'husky'].filter((d) => which(d) || d === 'husky'),
    harnessVersion: HARNESS_VERSION,
  }, null, 2));
  ok('.sprintrc.json written');
  log('');

  // 9. Start ruflo daemon + verify (AC-13: 30s polling)
  log('Step 8 — Start ruflo daemon + poll for RUNNING (30s)');
  try {
    execSync('ruflo daemon start --workspace .', { cwd: targetDir, stdio: 'inherit' });
    let running = false;
    for (let i = 0; i < 15; i++) {
      try {
        const out = execSync('ruflo daemon status', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
        if (/RUNNING|active/i.test(out)) { running = true; break; }
      } catch {}
      execSync('sleep 2');
    }
    if (running) ok('daemon RUNNING (verified within 30s)');
    else warn('daemon did not RUNNING within 30s — harness degraded');
  } catch (e) { warn(`daemon start failed: ${e.message}`); }
  log('');

  // AC C1: ruflo init populates target's .claude/skills and .claude/helpers from ruflo.
  // Without this, installed projects only get the 2 sprint-specific skills the harness ships.
  log('Step 8b — ruflo init (populate .claude/skills + helpers)');
  try {
    execSync('ruflo init --workspace . --yes', { cwd: targetDir, stdio: 'inherit' });
    config.ruflo_init_ran = true;
    ok('ruflo init complete');
  } catch (e) {
    try {
      execSync('ruflo init --workspace .', { cwd: targetDir, stdio: 'inherit' });
      config.ruflo_init_ran = true;
      ok('ruflo init complete (no --yes flag)');
    } catch (e2) {
      warn(`ruflo init failed: ${e2.message.split('\n')[0]} — run \`ruflo init\` manually`);
      config.ruflo_init_ran = false;
    }
  }
  log('');

  // AC #6 + AC C4: MCP wire-up.
  //   - If target has no .mcp.json, copy from lib/templates/mcp.json (with brand substitution).
  //   - If target has one, idempotently merge a `ruflo` entry into mcpServers.
  log('Step 8c — Wire ruflo MCP into .mcp.json');
  try {
    const mcpPath = join(targetDir, '.mcp.json');
    if (!existsSync(mcpPath)) {
      const tpl = join(LIB, 'templates/mcp.json');
      if (existsSync(tpl)) {
        let content = readFileSync(tpl, 'utf8');
        content = content.replace(/<BRAND_SLUG>/g, config.codebaseIdentifier);
        writeFileSync(mcpPath, content);
        ok('.mcp.json created from template (ruflo wired)');
      } else {
        writeFileSync(mcpPath, JSON.stringify({ mcpServers: { ruflo: { command: 'ruflo', args: ['mcp', 'start'] } } }, null, 2));
        ok('.mcp.json created (ruflo wired)');
      }
    } else {
      let mcp = { mcpServers: {} };
      try { mcp = JSON.parse(readFileSync(mcpPath, 'utf8')); }
      catch { warn('.mcp.json exists but is invalid JSON — preserving by backing up to .mcp.json.bak'); writeFileSync(mcpPath + '.bak', readFileSync(mcpPath, 'utf8')); }
      mcp.mcpServers = mcp.mcpServers || {};
      if (!mcp.mcpServers.ruflo) {
        mcp.mcpServers.ruflo = { command: 'ruflo', args: ['mcp', 'start'] };
        writeFileSync(mcpPath, JSON.stringify(mcp, null, 2));
        ok('.mcp.json updated with ruflo entry');
      } else ok('.mcp.json already has ruflo entry');
    }
    config.mcp_configured = true;
  } catch (e) {
    warn(`MCP wire-up failed: ${e.message.split('\n')[0]}`);
    config.mcp_configured = false;
  }
  log('');

  // 10. AC-9 per-project memory.db isolation
  log('Step 9 — Per-project memory.db isolation');
  if (config.memoryStrategy === 'per-project') {
    const swarmDir = join(targetDir, '.swarm');
    mkdirSync(swarmDir, { recursive: true });
    if (!existsSync(join(swarmDir, 'memory.db'))) {
      writeFileSync(join(swarmDir, 'memory.db'), '');
      ok(`.swarm/memory.db created (isolated)`);
    } else ok(`.swarm/memory.db already exists`);
  } else {
    ok(`memoryStrategy=shared-namespaced — global with "${config.memoryNamespace}-" prefix`);
  }
  log('');

  // AC-5: Linux systemd-user auto-install
  if (detectOS() === 'linux') {
    log('Step 10 — systemd-user (Linux)');
    const systemdDir = join(LIB, 'templates/systemd');
    if (existsSync(systemdDir)) {
      const userSystemd = `${process.env.HOME}/.config/systemd/user`;
      mkdirSync(userSystemd, { recursive: true });
      const loaded = [];
      for (const unit of readdirSync(systemdDir).filter((f) => f.endsWith('.service') || f.endsWith('.timer'))) {
        let content = readFileSync(join(systemdDir, unit), 'utf8');
        content = content.replace(/<BRAND_NAME>/g, config.brand).replace(/<BRAND_SLUG>/g, config.codebaseIdentifier).replace(/<REPO_ROOT>/g, targetDir);
        const destName = unit.replace(/<BRAND_SLUG>/g, config.codebaseIdentifier);
        writeFileSync(join(userSystemd, destName), content);
        if (destName.endsWith('.timer')) {
          try { execSync(`systemctl --user enable --now "${destName}"`); loaded.push(destName); ok(`systemd: ${destName}`); }
          catch (e) { warn(`systemctl ${destName}: ${e.message.split('\n')[0]}`); }
        }
      }
      config.systemd_loaded = loaded;
    }
    log('');
  }

  // 11. AC-4 + AC E5 launchctl auto-bootstrap (macOS): prefer plists in
  // ~/Library/LaunchAgents/ (recorded by installLaunchdPlists in config._launchd_plists).
  // Fall back to scratch plists in target/scripts/launchd/ for older harness installs.
  if (detectOS() === 'macos') {
    log('Step 11 — Auto-bootstrap launchd plists');
    const userId = execSync('id -u', { encoding: 'utf8' }).trim();
    const loaded = [];
    const sourcePlists = (config._launchd_plists && config._launchd_plists.length)
      ? config._launchd_plists
      : (() => {
          const dir = join(targetDir, 'scripts/launchd');
          if (!existsSync(dir)) return [];
          return readdirSync(dir).filter((p) => p.endsWith('.plist')).map((p) => ({
            name: p,
            userPath: join(dir, p),
          }));
        })();
    for (const { name, userPath } of sourcePlists) {
      try {
        execSync(`launchctl bootstrap gui/${userId} "${userPath}" 2>&1 || true`, { encoding: 'utf8' });
        loaded.push(name);
        ok(`launchctl: ${name} bootstrapped`);
      } catch (e) {
        warn(`launchctl ${name}: ${e.message.split('\n')[0]}`);
      }
    }
    config.launchctl_loaded = loaded;
    delete config._launchd_plists; // internal; don't persist
    log('');
  }

  // 12. AC-10 + AC #7 GH labels (with auth prompt if needed)
  if (which('gh')) {
    log('Step 12 — Auto-create GH labels (idempotent)');
    let authed = false;
    try { execSync('gh auth status 2>&1', { encoding: 'utf8', stdio: 'pipe' }); authed = true; } catch {}
    if (!authed) {
      const proceed = await prompt('gh is installed but not authenticated. Run `gh auth login` now?', false);
      if (proceed) {
        try { execSync('gh auth login', { cwd: targetDir, stdio: 'inherit' }); authed = true; }
        catch (e) { warn(`gh auth login failed: ${e.message.split('\n')[0]}`); }
      } else {
        warn('gh auth skipped — labels skipped. Run `gh auth login` manually to re-enable.');
        config.gh_auth_skipped = true;
      }
    }
    if (!authed) { log(''); }
    if (authed) try {
      execSync('gh auth status 2>&1', { encoding: 'utf8', stdio: 'pipe' });
      for (const [label, color, desc] of [
        ['sprint', '0E8A16', 'sprint-harness AC tracking'],
        ['epic',   'B60205', 'sprint-harness epic'],
        ['task',   'FBCA04', 'sprint-harness task'],
      ]) {
        try {
          execSync(`gh label create "${label}" --color "${color}" --description "${desc}" 2>&1`, { cwd: targetDir, stdio: 'pipe' });
          ok(`label: ${label}`);
        } catch (e) {
          if (/already exists/.test(e.message)) ok(`label: ${label} (exists)`);
          else warn(`label ${label}: ${e.message.split('\n')[0]}`);
        }
      }
      config.gh_labels_created = ['sprint', 'epic', 'task'];
    } catch { warn('gh not authenticated — labels skipped'); }
    log('');
  }

  // AC #12: .gitignore managed block
  log('Step 13 — .gitignore managed block');
  updateGitignore();
  log('');

  // AC #13: package.json sprint:* aliases
  log('Step 14 — package.json sprint:* aliases');
  addPackageScripts();
  log('');

  // Rewrite .sprintrc.json now that all post-Step-7 config fields are populated
  // (ruflo_init_ran, mcp_configured, launchctl_loaded, systemd_loaded,
  //  playwright_installed, sonar_token_path, gh_labels_created)
  writeFileSync(join(targetDir, '.sprintrc.json'), JSON.stringify({
    ...config,
    os: detectOS(),
    packageManager: pm,
    installedAt: new Date().toISOString(),
    installedDeps: ['ruflo', 'jq', 'husky'].filter((d) => which(d) || d === 'husky'),
    harnessVersion: HARNESS_VERSION,
  }, null, 2));

  log('═══════════════════════════════════════════════════════════════════');
  log('  Install complete!');
  log('═══════════════════════════════════════════════════════════════════');
  log('');
  log('  Next steps:');
  log('    1. Verify:  npx @ordex/sprint-harness verify');
  log('    2. Doctor:  npx @ordex/sprint-harness doctor');
  log('    3. Start a sprint:');
  log('       bash scripts/sprint-start.sh first-sprint --no-issue');
  log('       Then in Claude Code: "start the spec wizard"');
  log('');
  // AC #16: BRAND_SLUG override hint for wizard memory recall
  log(`  Memory recall uses BRAND_SLUG = "${config.codebaseIdentifier}"`);
  log(`    Override via env:  export BRAND_SLUG=my-other-codebase`);
  log(`    Or edit:           .sprintrc.json → codebaseIdentifier`);
  log('');
}

async function ensureDep(name, installCmd) {
  if (name === 'husky-init') {
    if (!existsSync(join(targetDir, '.husky'))) {
      const proceed = await prompt(`Install husky? (${installCmd})`, true);
      if (proceed) try { execSync(installCmd, { cwd: targetDir, stdio: 'inherit' }); ok('husky initialized'); } catch (e) { err(`husky init failed: ${e.message}`); }
      else warn('skipped husky');
    } else ok(`husky already initialized`);
    return;
  }
  // For instructive-only deps (curl-pipe-to-shell, etc), just warn — never auto-execute
  if (installCmd && (installCmd.includes('curl') || installCmd.includes('see http'))) {
    if (which(name)) { ok(`${name} ${version(name)}`); }
    else { warn(`${name} not installed — manual install needed: ${installCmd}`); }
    return;
  }
  if (which(name)) { ok(`${name} ${version(name)}`); return; }
  const proceed = await prompt(`${name} not installed. Run: ${installCmd}?`, true);
  if (proceed) {
    try { execSync(installCmd, { stdio: 'inherit' }); ok(`${name} installed`); }
    catch (e) { err(`${name} install failed: ${e.message}`); }
  } else warn(`skipped ${name} — harness may be degraded`);
}

async function brandPrompts() {
  if (nonInteractive) {
    return {
      brand: 'MyProduct',
      codebaseIdentifier: 'myproduct',
      memoryNamespace: 'myproduct',
      memoryStrategy: 'per-project',   // AC-15
      gitHubOrg: 'your-username',
      awsProfile: null,
      packageManager: detectPM(targetDir) || 'pnpm',
    };
  }
  const ask = async (q, def) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((r) => rl.question(`${q} (default: ${def}) `, (a) => { rl.close(); r(a.trim() || def); }));
  };
  const brand = await ask('Brand name (e.g. "Ordex"):', 'MyProduct');
  const codebase = await ask('Codebase slug (e.g. "lifeos"):', 'myproduct');
  // AC-15: memory namespacing strategy
  const memStrategyAns = await ask('Memory strategy — per-project (isolated) or shared-namespaced (cross-project recall)?', 'per-project');
  return {
    brand,
    codebaseIdentifier: codebase,
    memoryNamespace: await ask('Memory namespace prefix:', codebase),
    memoryStrategy: memStrategyAns === 'shared-namespaced' ? 'shared-namespaced' : 'per-project',
    gitHubOrg: await ask('GitHub org/user:', 'your-username'),
    awsProfile: await ask('AWS profile name (or "none"):', 'none'),
    packageManager: detectPM(targetDir) || 'pnpm',
  };
}

function copyWithSubstitution(src, dest, config) {
  // AC E6: caller may pass a non-existent source — fail loudly with a useful message
  // rather than silently emitting nothing.
  if (!existsSync(src)) {
    err(`copyWithSubstitution: source missing: ${src}`);
    throw new Error(`Missing template dir: ${src}`);
  }
  mkdirSync(dest, { recursive: true });
  for (const entry of readdirSync(src)) {
    const sp = join(src, entry);
    let dn = entry;
    // Substitute template tokens in filename
    dn = dn.replace(/<BRAND_SLUG>/g, config.codebaseIdentifier);
    const dp = join(dest, dn);
    if (statSync(sp).isDirectory()) {
      copyWithSubstitution(sp, dp, config);
    } else {
      let content = readFileSync(sp, 'utf8');
      content = content
        .replace(/<BRAND_NAME>/g, config.brand)
        .replace(/<BRAND_NAME_UPPER>/g, config.brand.toUpperCase())
        .replace(/<BRAND_SLUG>/g, config.codebaseIdentifier)
        .replace(/<BRAND_SLUG_UPPER>/g, config.codebaseIdentifier.toUpperCase())
        .replace(/<BRAND_SLUG_TITLE>/g, config.codebaseIdentifier.charAt(0).toUpperCase() + config.codebaseIdentifier.slice(1))
        .replace(/<NAMESPACE>/g, config.codebaseIdentifier)
        .replace(/<GITHUB_ORG>/g, config.gitHubOrg)
        // AC B7: empty AWS profile would leave `profile=""` (bash syntax issue) and trip downstream scripts.
        // Substitute `default` when user opted out, so AWS_PROFILE=default resolves to the user's
        // default profile (no-op if not used) rather than an empty string.
        .replace(/<AWS_PROFILE_NAME>/g, !config.awsProfile || config.awsProfile === 'none' ? 'default' : config.awsProfile)
        .replace(/<AWS_ACCOUNT_ID>/g, '000000000000')
        .replace(/<REPO_ROOT>/g, targetDir);
      // AC-16: package-manager adapter — rewrite pnpm dlx to detected PM
      const pm = config.packageManager || 'pnpm';
      if (pm === 'npm') {
        content = content.replace(/\bpnpm dlx\b/g, 'npx').replace(/\bpnpm /g, 'npm run ');
      } else if (pm === 'yarn') {
        content = content.replace(/\bpnpm dlx\b/g, 'yarn dlx').replace(/\bpnpm /g, 'yarn ');
      }
      writeFileSync(dp, content);
      // Preserve executable bit on shell scripts
      if (sp.endsWith('.sh') || sp.endsWith('.mjs')) {
        try { execSync(`chmod +x "${dp}"`); } catch {}
      }
    }
  }
}

function mergeHusky(src, dest) {
  if (!existsSync(src)) return;
  const srcContent = readFileSync(src, 'utf8');
  if (existsSync(dest)) {
    const existing = readFileSync(dest, 'utf8');
    // Already merged?
    if (existing.includes('# sprint-harness:start')) { ok(`${basename(dest)} already merged`); return; }
    const merged = existing + '\n\n# sprint-harness:start\n' + srcContent + '\n# sprint-harness:end\n';
    writeFileSync(dest, merged);
    ok(`${basename(dest)} merged (appended)`);
  } else {
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, '#!/usr/bin/env sh\n\n# sprint-harness:start\n' + srcContent + '\n# sprint-harness:end\n');
    try { execSync(`chmod +x "${dest}"`); } catch {}
    ok(`${basename(dest)} created`);
  }
}

function mergeClaudeSettings(dest) {
  // AC B10: cover all hook lifecycle phases, not only PreToolUse.
  // AC B9: dedupe by matcher (a re-install must not double-fire each hook).
  const harnessHooks = {
    PreToolUse: [
      { matcher: 'Bash', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/sprint-hook.cjs" pre-bash\'', timeout: 4000 }] },
      { matcher: 'Write|Edit|MultiEdit', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/sprint-hook.cjs" pre-edit\'', timeout: 4000 }] },
      { matcher: 'WebSearch', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/websearch-pii-redact.cjs"\'', timeout: 3000 }] },
    ],
    PostToolUse: [
      { matcher: 'Bash', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/sprint-hook.cjs" post-bash 2>/dev/null || true\'', timeout: 3000 }] },
    ],
    SessionStart: [
      { matcher: '*', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/sprint-hook.cjs" session-start 2>/dev/null || true\'', timeout: 5000 }] },
    ],
    SubagentStop: [
      { matcher: '*', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/sprint-hook.cjs" subagent-stop 2>/dev/null || true\'', timeout: 3000 }] },
    ],
  };
  const dedupe = (existing, additions) => {
    const seen = new Set(existing.map((h) => h.matcher));
    return existing.concat(additions.filter((a) => !seen.has(a.matcher)));
  };
  let merged;
  if (existsSync(dest)) {
    const existing = JSON.parse(readFileSync(dest, 'utf8'));
    existing.hooks = existing.hooks || {};
    for (const phase of Object.keys(harnessHooks)) {
      existing.hooks[phase] = dedupe(existing.hooks[phase] || [], harnessHooks[phase]);
    }
    merged = existing;
    ok('.claude/settings.json: PreToolUse + PostToolUse + SessionStart + SubagentStop hooks merged (deduped)');
  } else {
    mkdirSync(dirname(dest), { recursive: true });
    merged = { hooks: harnessHooks };
    ok('.claude/settings.json: created');
  }
  writeFileSync(dest, JSON.stringify(merged, null, 2));
}

// AC #12: append managed .gitignore block (idempotent — only adds if marker absent)
function updateGitignore() {
  const giPath = join(targetDir, '.gitignore');
  const MARK_START = '# sprint-harness (managed) — DO NOT EDIT';
  const MARK_END = '# /sprint-harness';
  const block = [
    MARK_START,
    '.sprint-harness/',
    '.swarm/memory.db',
    '.swarm/memory.db-*',
    'docs/sprints/**/*.lock',
    'docs/sprints/**/jscpd-report/',
    'docs/sprints/**/reuse-audit.json',
    '.sprint-harness-backup-*/',
    MARK_END,
    '',
  ].join('\n');
  let cur = existsSync(giPath) ? readFileSync(giPath, 'utf8') : '';
  if (cur.includes(MARK_START)) { ok('.gitignore already managed'); return; }
  if (cur.length && !cur.endsWith('\n')) cur += '\n';
  writeFileSync(giPath, cur + '\n' + block);
  ok('.gitignore updated with managed block');
}

// AC #13: idempotently add sprint:* aliases to target package.json
function addPackageScripts() {
  const pkgPath = join(targetDir, 'package.json');
  if (!existsSync(pkgPath)) return;
  let pkg;
  try { pkg = JSON.parse(readFileSync(pkgPath, 'utf8')); } catch { return; }
  pkg.scripts = pkg.scripts || {};
  const aliases = {
    'sprint:start':  'bash scripts/sprint-start.sh',
    'sprint:status': 'bash scripts/sprint-status.sh',
    'sprint:end':    'bash scripts/sprint-end.sh',
    'sprint:pause':  'bash scripts/sprint-pause.sh',
    'sprint:resume': 'bash scripts/sprint-resume.sh',
    'sprint:doctor': 'npx @ordex/sprint-harness doctor',
    'sprint:verify': 'npx @ordex/sprint-harness verify',
  };
  let added = 0;
  for (const [k, v] of Object.entries(aliases)) {
    if (!pkg.scripts[k]) { pkg.scripts[k] = v; added++; }
  }
  if (added) {
    writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
    ok(`package.json: +${added} sprint:* aliases`);
  } else {
    ok('package.json: sprint:* aliases already present');
  }
}

function installLaunchdPlists(config) {
  // AC B3 + E5: read from lib/templates/launchd/ (canonical), fall back to lib/scripts/launchd/
  // for back-compat. Write to ~/Library/LaunchAgents/ first (macOS 12+ requires this),
  // then mirror a copy into target's scripts/launchd/ for reference + uninstall.
  let plistDir = join(LIB, 'templates/launchd');
  if (!existsSync(plistDir)) plistDir = join(LIB, 'scripts/launchd');
  if (!existsSync(plistDir)) return;

  const home = process.env.HOME || '';
  const userLaunchAgents = join(home, 'Library/LaunchAgents');
  mkdirSync(userLaunchAgents, { recursive: true });
  const targetPlistDir = join(targetDir, 'scripts/launchd');
  mkdirSync(targetPlistDir, { recursive: true });

  const installed = [];
  for (const plist of readdirSync(plistDir).filter((p) => p.endsWith('.plist'))) {
    const src = join(plistDir, plist);
    let content = readFileSync(src, 'utf8');
    content = content
      .replace(/<BRAND_SLUG>/g, config.codebaseIdentifier)
      .replace(/<REPO_ROOT>/g, targetDir);
    const renamed = plist.replace(/<BRAND_SLUG>/g, config.codebaseIdentifier);
    const userDest = join(userLaunchAgents, renamed);
    const refDest = join(targetPlistDir, renamed);
    writeFileSync(userDest, content);
    writeFileSync(refDest, content);
    installed.push({ name: renamed, userPath: userDest });
    ok(`plist: ${renamed} → ~/Library/LaunchAgents/`);
  }
  // Expose installed plists for auto-bootstrap loop downstream
  config._launchd_plists = installed;
}

function cmdVerify() {
  log('═══ sprint-harness verify ═══');
  const checks = [
    ['scripts/sprint-start.sh',            'state machine entry'],
    ['scripts/sprint-spec-wizard.mjs',     'wizard orchestrator'],
    ['scripts/sprint-inject-violation.sh', 'inject-catch-restore helper'],
    ['scripts/sprint-harness-readiness.mjs', 'proof aggregator'],
    ['scripts/run-workflow.sh',            'workflow shim'],
    ['scripts/sprint-pii-redact.sh',       'PII redact primitive'],
    ['.claude/skills/sprint-orchestrator/SKILL.md', 'orchestrator skill'],
    ['.claude/skills/sprint-spec-wizard/SKILL.md',  'wizard skill'],
    ['.claude/helpers/sprint-hook.cjs',    'PreToolUse hook'],
    ['.claude/helpers/websearch-pii-redact.cjs', 'WebSearch PII hook'],
    ['.husky/pre-commit',                  'drift check hook'],
    ['.husky/post-commit',                 'reuse audit hook'],
    ['docs/workflows',                     'workflow YAMLs dir'],
    ['docs/sprints/_template/spec.md',     'spec template'],
    ['.sprintrc.json',                     'sprint configuration'],
  ];
  let ok_n = 0, miss = 0;
  for (const [p, desc] of checks) {
    if (existsSync(join(targetDir, p))) { ok(`${p.padEnd(50)} ${desc}`); ok_n++; }
    else { err(`${p.padEnd(50)} MISSING (${desc})`); miss++; }
  }
  log('');
  log(`  ${ok_n}/${checks.length} expected artifacts present.`);
  process.exit(miss > 0 ? 1 : 0);
}

function cmdUninstall() {
  log('═══ sprint-harness uninstall ═══');
  warn('This removes installed scripts/skills/helpers/workflows but preserves docs/sprints/ history and .sprintrc.json.');
  // Remove harness blocks from husky hooks
  for (const h of ['pre-commit', 'post-commit', 'pre-push', 'post-merge']) {
    const f = join(targetDir, '.husky', h);
    if (!existsSync(f)) continue;
    const c = readFileSync(f, 'utf8');
    const stripped = c.replace(/\n\n# sprint-harness:start[\s\S]*?# sprint-harness:end\n/g, '\n');
    writeFileSync(f, stripped);
    ok(`husky/${h}: harness block removed`);
  }
  // Remove copied scripts/skills/helpers/workflows
  for (const d of ['scripts', '.claude/skills/sprint-orchestrator', '.claude/skills/sprint-spec-wizard', '.claude/helpers/sprint-hook.cjs', '.claude/helpers/websearch-pii-redact.cjs', 'docs/workflows']) {
    const f = join(targetDir, d);
    if (existsSync(f)) {
      try { rmSync(f, { recursive: true, force: true }); ok(`removed ${d}`); } catch (e) { warn(`could not remove ${d}: ${e.message}`); }
    }
  }
  ok('uninstall complete. docs/sprints/ + .sprintrc.json preserved.');
}

async function cmdUpdate() {
  // AC-18: update preserves .sprintrc.json + user customizations
  log('═══ sprint-harness update ═══');
  const sprintrcPath = join(targetDir, '.sprintrc.json');
  if (!existsSync(sprintrcPath)) {
    err('No .sprintrc.json — run `install` first, not `update`.');
    process.exit(1);
  }
  const config = JSON.parse(readFileSync(sprintrcPath, 'utf8'));
  ok(`Preserving config: brand=${config.brand}, ns=${config.codebaseIdentifier}, pm=${config.packageManager}`);

  // Backup mutable surfaces before overwrite
  const backupRoot = join(targetDir, `.sprint-harness-backup-${Date.now()}`);
  mkdirSync(backupRoot, { recursive: true });
  for (const p of ['scripts', '.claude/skills/sprint-orchestrator', '.claude/skills/sprint-spec-wizard', '.claude/helpers/sprint-hook.cjs', '.claude/helpers/websearch-pii-redact.cjs', 'docs/workflows']) {
    const src = join(targetDir, p);
    if (!existsSync(src)) continue;
    const dst = join(backupRoot, p);
    mkdirSync(dirname(dst), { recursive: true });
    execSync(`cp -r "${src}" "${dst}"`);
  }
  ok(`Backup at: ${backupRoot}`);

  // Copy fresh harness with same config
  copyWithSubstitution(join(LIB, 'scripts'),  join(targetDir, 'scripts'),       config);
  copyWithSubstitution(join(LIB, 'workflows'), join(targetDir, 'docs/workflows'), config);
  copyWithSubstitution(join(LIB, 'skills'),   join(targetDir, '.claude/skills'), config);
  copyWithSubstitution(join(LIB, 'helpers'),  join(targetDir, '.claude/helpers'), config);
  ok('Files refreshed (existing files overwritten; backup preserved at above path)');

  // Record update history
  config.update_history = (config.update_history || []).concat([{
    at: new Date().toISOString(),
    from: config.harnessVersion || 'unknown',
    to: '0.2.0',
    backupPath: backupRoot,
  }]);
  config.harnessVersion = '0.2.0';
  writeFileSync(sprintrcPath, JSON.stringify(config, null, 2));
  ok('.sprintrc.json updated with version + history');
  log('');
  log(`Update complete: ${config.update_history[config.update_history.length - 2]?.to || '0.1.0'} → 0.2.0`);
  log(`Review changes:  diff -r ${backupRoot}/scripts scripts | head -50`);
  log(`Rollback:        rm -rf scripts docs/workflows .claude && cp -r ${backupRoot}/* .`);
}

// ── Dispatch ─────────────────────────────────────────────────────────────────
const SUB = {
  install: cmdInstall, doctor: cmdDoctor, verify: cmdVerify,
  uninstall: cmdUninstall, update: cmdUpdate,
};
if (!cmd || !SUB[cmd]) {
  log('Usage: sprint-harness <install|verify|doctor|uninstall|update> [options]');
  log('       sprint-harness install [--non-interactive] [--target <dir>]');
  log('       sprint-harness doctor');
  log('       sprint-harness verify');
  log('       sprint-harness uninstall');
  log('       sprint-harness update [--from <version>]');
  process.exit(cmd ? 1 : 0);
}
try { await SUB[cmd](); } catch (e) {
  err(e.message);
  if (process.env.DEBUG) console.error(e.stack);
  process.exit(1);
}
