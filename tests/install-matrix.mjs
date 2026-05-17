#!/usr/bin/env node
// AC-8 (harness-portability-v3): install matrix — 3 sample-project shapes.
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(__dirname, '..');
const BIN = join(PKG_ROOT, 'bin/sprint-harness.mjs');

const SHAPES = [
  { id: 'pnpm-blank', setup: (dir) => {
    execSync(`cd ${dir} && git init -b main && git config user.email "ci@sprint-harness.local" && git config user.name "sprint-harness-ci" && echo '{"name":"pnpm-blank","packageManager":"pnpm@9.0.0"}' > package.json && touch pnpm-lock.yaml && git add . && git commit -m init`, { stdio: 'ignore' });
  }},
  { id: 'npm-blank', setup: (dir) => {
    execSync(`cd ${dir} && git init -b main && git config user.email "ci@sprint-harness.local" && git config user.name "sprint-harness-ci" && echo '{"name":"npm-blank"}' > package.json && touch package-lock.json && git add . && git commit -m init`, { stdio: 'ignore' });
  }},
  { id: 'monorepo-with-husky', setup: (dir) => {
    execSync(`cd ${dir} && git init -b main && git config user.email "ci@sprint-harness.local" && git config user.name "sprint-harness-ci"`, { stdio: 'ignore' });
    writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'mono', private: true, workspaces: ['packages/*'] }, null, 2));
    writeFileSync(join(dir, 'pnpm-workspace.yaml'), 'packages:\n  - packages/*\n');
    mkdirSync(join(dir, '.husky'), { recursive: true });
    writeFileSync(join(dir, '.husky/pre-commit'), '#!/usr/bin/env sh\necho "user-existing pre-commit"\n');
    execSync(`cd ${dir} && chmod +x .husky/pre-commit && git add . && git commit -m init`, { stdio: 'ignore' });
  }},
];

let failed = 0;
for (const shape of SHAPES) {
  const TARGET = join(tmpdir(), `sh-matrix-${shape.id}-${Date.now()}`);
  console.log(`\n== Shape: ${shape.id} ==`);
  try {
    mkdirSync(TARGET, { recursive: true });
    shape.setup(TARGET);
    execSync(`node ${BIN} install --non-interactive --target ${TARGET}`, { stdio: 'inherit' });
    execSync(`node ${BIN} verify --target ${TARGET}`, { stdio: 'inherit' });
    if (shape.id === 'monorepo-with-husky') {
      const h = execSync(`cat ${TARGET}/.husky/pre-commit`, { encoding: 'utf8' });
      if (h.includes('user-existing pre-commit')) console.log(`  pre-existing husky preserved`);
      else { console.error(`  pre-existing husky LOST`); failed++; }
    }
    execSync(`node ${BIN} uninstall --target ${TARGET}`, { stdio: 'inherit' });
    console.log(`  ${shape.id} green`);
  } catch (e) {
    console.error(`  ${shape.id} FAILED: ${e.message.split('\n')[0]}`);
    failed++;
  } finally {
    try { execSync('ruflo daemon stop', { stdio: 'ignore' }); } catch {}
    try { rmSync(TARGET, { recursive: true, force: true }); } catch {}
  }
}

console.log('');
if (failed === 0) { console.log(`== MATRIX PASSED (${SHAPES.length}/${SHAPES.length}) ==`); process.exit(0); }
else { console.error(`== MATRIX FAILED (${failed}/${SHAPES.length}) ==`); process.exit(1); }
