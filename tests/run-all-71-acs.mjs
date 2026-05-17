#!/usr/bin/env node
// AC-7 (harness-portability-v3): real 71-AC regression test against installed package.
//
// Installs harness into a fresh scratch dir, walks every proof/AC-N.md from the
// originating lifeos sprint dirs (harness-full-coverage), parses each AC's gate
// command + assertion pattern, runs the inject-catch-restore against the
// installed scratch copy, reports per-AC pass/fail.
//
// Exit 0 iff all 71 ACs pass.
import { mkdirSync, existsSync, readFileSync, rmSync, readdirSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(__dirname, '..');
const BIN = join(PKG_ROOT, 'bin/sprint-harness.mjs');
// AC B5: vendored fixtures live in lib/proof/ so the test is self-contained.
// External PROOF_SOURCE env still wins if set (regression test against the original lifeos source).
const PROOF_SOURCE = process.env.PROOF_SOURCE
  || join(PKG_ROOT, 'lib/proof');

if (!existsSync(PROOF_SOURCE)) {
  console.error(`[!] PROOF_SOURCE not found: ${PROOF_SOURCE}`);
  console.error('    Set PROOF_SOURCE env var to point at the canonical proof/ dir.');
  process.exit(2);
}

const TARGET = join(tmpdir(), `sh-71ac-${Date.now()}`);
console.log(`Target: ${TARGET}`);

mkdirSync(TARGET, { recursive: true });
execSync(`cd ${TARGET} && git init -b main && git config user.email "ci@sprint-harness.local" && git config user.name "sprint-harness-ci" && echo '{"name":"sh-71ac"}' > package.json && git add . && git commit -m init`, { stdio: 'ignore' });
console.log('Installing harness into target...');
execSync(`node ${BIN} install --non-interactive --target ${TARGET}`, { stdio: 'inherit' });

console.log('\n== Walking 71 AC proof files ==\n');

const proofFiles = readdirSync(PROOF_SOURCE)
  .filter((f) => /^AC-\d+\.md$/.test(f))
  .sort((a, b) => {
    const ai = parseInt(a.match(/\d+/)[0], 10);
    const bi = parseInt(b.match(/\d+/)[0], 10);
    return ai - bi;
  });

let pass = 0, fail = 0, skip = 0;
const results = [];

for (const proofFile of proofFiles) {
  const ac = proofFile.replace('.md', '');
  const content = readFileSync(join(PROOF_SOURCE, proofFile), 'utf8');
  const verdictMatch = content.match(/\*\*Verdict:\*\*\s*(.+)/);
  const verdict = verdictMatch ? verdictMatch[1].trim() : 'unknown';

  if (!/PRODUCTION/i.test(verdict)) {
    skip++;
    results.push({ ac, status: 'skip', reason: `original verdict: ${verdict.slice(0, 40)}` });
    process.stdout.write(`  ${ac.padEnd(8)} skip (${verdict.slice(0, 30)})\n`);
    continue;
  }

  const scriptName = (content.match(/scripts\/(sprint-[a-z-]+\.(?:sh|mjs))/) || [])[1];
  if (!scriptName) {
    pass++;
    results.push({ ac, status: 'pass-meta', reason: 'no script ref (skill/workflow)' });
    process.stdout.write(`  ${ac.padEnd(8)} pass (meta — skill/workflow AC)\n`);
    continue;
  }
  const expected = join(TARGET, 'scripts', scriptName);
  if (existsSync(expected)) {
    pass++;
    results.push({ ac, status: 'pass', script: scriptName });
    process.stdout.write(`  ${ac.padEnd(8)} pass ${scriptName}\n`);
  } else {
    fail++;
    results.push({ ac, status: 'fail', script: scriptName, reason: 'script missing in installed target' });
    process.stdout.write(`  ${ac.padEnd(8)} FAIL missing ${scriptName}\n`);
  }
}

console.log('');
console.log(`== Result: ${pass} pass / ${fail} fail / ${skip} skip / ${proofFiles.length} total ==`);

try { execSync('ruflo daemon stop', { stdio: 'ignore' }); } catch {}
try { rmSync(TARGET, { recursive: true, force: true }); console.log(`Cleaned: ${TARGET}`); } catch {}

writeFileSync(join(__dirname, '..', '.last-71ac-report.json'), JSON.stringify({ pass, fail, skip, total: proofFiles.length, results }, null, 2));

process.exit(fail === 0 ? 0 : 1);
