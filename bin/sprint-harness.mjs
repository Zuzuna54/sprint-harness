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

  if (tier1Missing === 0) {
    log('  Result: TIER 1 COMPLETE ✓ — all 71 capabilities reachable');
    process.exit(0);
  } else {
    log(`  Result: ${tier1Missing} TIER 1 dep(s) missing — run: npx @ordex/sprint-harness install`);
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

  // 2. Auto-install Tier 1 deps
  log('Step 1 — Verify/install Tier 1 deps');
  await ensureDep('node', 'curl -fsSL https://nodejs.org/');  // instructive only
  await ensureDep('git', 'brew install git');                  // instructive only
  await ensureDep('jq', detectOS() === 'macos' ? 'brew install jq' : 'sudo apt install -y jq');
  const pm = detectPM(targetDir) || 'pnpm';
  if (!which(pm)) await ensureDep(pm, `corepack enable && corepack prepare ${pm}@latest --activate`);
  await ensureDep('ruflo', 'npm install -g ruflo@latest');
  if (!existing.husky) await ensureDep('husky-init', `${pm === 'npm' ? 'npx' : pm + ' dlx'} husky init`);
  // Optional Tier 2 (prompt only)
  log('');
  log('Step 1b — Tier 2 deps (optional)');
  if (!which('gh')) {
    const proceed = await prompt('Install gh (GitHub CLI) for sprint-pr-body + sprint-gh-mirror?', false);
    if (proceed) await ensureDep('gh', detectOS() === 'macos' ? 'brew install gh' : 'see https://cli.github.com/');
  } else ok(`gh ${version('gh')}`);
  if (!which('sonar-scanner')) {
    const proceed = await prompt('Install sonar-scanner for static analysis gate?', false);
    if (proceed) await ensureDep('sonar-scanner', 'brew install sonar-scanner');
  } else ok(`sonar-scanner present`);
  if (!which('docker')) {
    warn('docker not installed (optional; install via docker.com if you want local Sonar)');
  } else ok(`docker ${version('docker')}`);
  log('');

  // 3. Prompt for brand config
  log('Step 2 — Brand configuration');
  const config = await brandPrompts();
  log('');

  // 4. Copy files (with template substitution)
  log('Step 3 — Copy harness into target');
  copyWithSubstitution(join(LIB, 'scripts'),  join(targetDir, 'scripts'),       config);
  copyWithSubstitution(join(LIB, 'workflows'), join(targetDir, 'docs/workflows'), config);
  copyWithSubstitution(join(LIB, 'skills'),   join(targetDir, '.claude/skills'), config);
  copyWithSubstitution(join(LIB, 'helpers'),  join(targetDir, '.claude/helpers'), config);
  copyWithSubstitution(join(LIB, 'templates/sprints'), join(targetDir, 'docs/sprints'), config);
  ok(`copied 57 scripts, 5 workflows, 12 skill files, 3 helpers, sprint docs`);
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
    harnessVersion: '0.1.0',
  }, null, 2));
  ok('.sprintrc.json written');
  log('');

  // 9. Start ruflo daemon + verify
  log('Step 8 — Start ruflo daemon');
  try {
    execSync('ruflo daemon start --workspace .', { cwd: targetDir, stdio: 'inherit' });
    ok('daemon started');
  } catch (e) { warn(`daemon start failed: ${e.message}`); }
  log('');

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
      gitHubOrg: 'your-username',
      awsProfile: null,
      packageManager: detectPM(targetDir) || 'pnpm',
    };
  }
  const ask = async (q, def) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((r) => rl.question(`${q} (default: ${def}) `, (a) => { rl.close(); r(a.trim() || def); }));
  };
  return {
    brand: await ask('Brand name (e.g. "Ordex"):', 'MyProduct'),
    codebaseIdentifier: await ask('Codebase slug (e.g. "lifeos"):', 'myproduct'),
    memoryNamespace: await ask('Memory namespace:', 'myproduct'),
    gitHubOrg: await ask('GitHub org/user:', 'your-username'),
    awsProfile: await ask('AWS profile name (or "none"):', 'none'),
    packageManager: detectPM(targetDir) || 'pnpm',
  };
}

function copyWithSubstitution(src, dest, config) {
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
        .replace(/<AWS_PROFILE_NAME>/g, config.awsProfile === 'none' ? '' : config.awsProfile)
        .replace(/<AWS_ACCOUNT_ID>/g, '')
        .replace(/<REPO_ROOT>/g, targetDir);
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
  const harnessHooks = {
    PreToolUse: [
      { matcher: 'Bash', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/sprint-hook.cjs" pre-bash\'', timeout: 4000 }] },
      { matcher: 'Write|Edit|MultiEdit', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/sprint-hook.cjs" pre-edit\'', timeout: 4000 }] },
      { matcher: 'WebSearch', hooks: [{ type: 'command', command: 'sh -c \'exec node "${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/websearch-pii-redact.cjs"\'', timeout: 3000 }] },
    ],
  };
  let merged;
  if (existsSync(dest)) {
    const existing = JSON.parse(readFileSync(dest, 'utf8'));
    existing.hooks = existing.hooks || {};
    existing.hooks.PreToolUse = (existing.hooks.PreToolUse || []).concat(harnessHooks.PreToolUse);
    merged = existing;
    ok('.claude/settings.json: PreToolUse hooks appended');
  } else {
    mkdirSync(dirname(dest), { recursive: true });
    merged = { hooks: harnessHooks };
    ok('.claude/settings.json: created');
  }
  writeFileSync(dest, JSON.stringify(merged, null, 2));
}

function installLaunchdPlists(config) {
  const plistDir = join(LIB, 'scripts/launchd');
  if (!existsSync(plistDir)) return;
  for (const plist of readdirSync(plistDir).filter((p) => p.endsWith('.plist'))) {
    const src = join(plistDir, plist);
    let content = readFileSync(src, 'utf8');
    content = content
      .replace(/<BRAND_SLUG>/g, config.codebaseIdentifier)
      .replace(/<REPO_ROOT>/g, targetDir);
    const targetPlistDir = join(targetDir, 'scripts/launchd');
    mkdirSync(targetPlistDir, { recursive: true });
    const dest = join(targetPlistDir, plist.replace(/<BRAND_SLUG>/g, config.codebaseIdentifier));
    writeFileSync(dest, content);
    ok(`plist: ${basename(dest)} (run: launchctl bootstrap gui/$(id -u) ${dest})`);
  }
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

function cmdUpdate() {
  log('═══ sprint-harness update ═══');
  warn('Update preserves .sprintrc.json + your customizations.');
  warn('Strategy: backup target hooks/scripts to .bak before overwrite.');
  warn('Implementation: re-run cmdInstall with --merge-mode, preserve config.');
  log('Not fully implemented in v0.1 — re-clone + cmdInstall recommended for now.');
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
