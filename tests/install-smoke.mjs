#!/usr/bin/env node
// install-smoke.mjs — verify the installer installs cleanly into a scratch dir
// + harness scripts are invocable + uninstall reverts.
import { mkdirSync, existsSync, writeFileSync, rmSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(__dirname, '..');
const BIN = join(PKG_ROOT, 'bin/sprint-harness.mjs');

const TARGET = join(tmpdir(), `sprint-harness-smoke-${Date.now()}`);
console.log(`Target: ${TARGET}`);

let failed = 0;
function check(label, cmd, expectExit = 0) {
  try {
    const out = execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    console.log(`  ✓ ${label}`);
    return out;
  } catch (e) {
    if ((e.status || 1) === expectExit) {
      console.log(`  ✓ ${label} (expected exit ${expectExit})`);
      return e.stdout;
    }
    console.error(`  ✗ ${label}: ${e.message.split('\n')[0]}`);
    failed++;
    return null;
  }
}

try {
  mkdirSync(TARGET, { recursive: true });
  execSync(`cd ${TARGET} && git init -b main && echo '{"name":"sample"}' > package.json && git add . && git commit -m init`, { stdio: 'ignore' });
  writeFileSync(join(TARGET, '.gitignore'), 'node_modules\n.claude-flow\n.swarm\n');

  console.log('── 1. Install ──');
  check('install --non-interactive', `node ${BIN} install --non-interactive --target ${TARGET}`);

  console.log('── 2. Verify ──');
  check('verify', `node ${BIN} verify --target ${TARGET}`);

  console.log('── 3. Sprint commands invocable in target ──');
  check('sprint-status', `cd ${TARGET} && bash scripts/sprint-status.sh`);
  check('sprint-spec-wizard help', `cd ${TARGET} && node scripts/sprint-spec-wizard.mjs`, 0);

  console.log('── 4. Files present ──');
  for (const p of [
    'scripts/sprint-start.sh',
    'scripts/sprint-end.sh',
    'scripts/sprint-inject-violation.sh',
    'scripts/run-workflow.sh',
    'scripts/sprint-harness-readiness.mjs',
    '.claude/skills/sprint-orchestrator/SKILL.md',
    '.claude/skills/sprint-spec-wizard/SKILL.md',
    '.claude/helpers/sprint-hook.cjs',
    '.husky/pre-commit',
    '.husky/post-commit',
    'docs/sprints/_template/spec.md',
    '.sprintrc.json',
  ]) {
    if (existsSync(join(TARGET, p))) console.log(`  ✓ ${p}`);
    else { console.error(`  ✗ MISSING: ${p}`); failed++; }
  }

  console.log('── 5. Uninstall + revert verify ──');
  check('uninstall', `node ${BIN} uninstall --target ${TARGET}`);
  // After uninstall, .sprintrc.json + docs/sprints/ should persist; scripts removed
  if (existsSync(join(TARGET, '.sprintrc.json'))) console.log('  ✓ .sprintrc.json preserved');
  else { console.error('  ✗ .sprintrc.json should have been preserved'); failed++; }
  if (!existsSync(join(TARGET, 'scripts'))) console.log('  ✓ scripts/ removed');
  else { console.error('  ✗ scripts/ should have been removed'); failed++; }

  // Stop ruflo daemon for hygiene
  try { execSync('ruflo daemon stop', { stdio: 'ignore' }); } catch {}

} finally {
  try { rmSync(TARGET, { recursive: true, force: true }); console.log(`Cleaned: ${TARGET}`); } catch {}
}

console.log('');
if (failed === 0) { console.log('═══ ALL CHECKS PASSED ═══'); process.exit(0); }
else { console.error(`═══ ${failed} CHECK(S) FAILED ═══`); process.exit(1); }
