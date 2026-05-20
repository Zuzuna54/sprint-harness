#!/usr/bin/env node
import { mkdirSync, existsSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(__dirname, '..');
const BIN = join(PKG_ROOT, 'bin/sprint-harness.mjs');

const TARGET = join(tmpdir(), `sh-opencode-e2e-${Date.now()}`);
console.log(`Target: ${TARGET}`);

mkdirSync(TARGET, { recursive: true });
execSync(`cd ${TARGET} && git init -b main && git config user.email "ci@sprint-harness.local" && git config user.name "sprint-harness-ci" && echo '{"name":"sh-opencode"}' > package.json && git add . && git commit -m init`, { stdio: 'ignore' });
console.log('Installing harness into target...');
execSync(`SPRINT_RUNTIME=opencode node ${BIN} install --non-interactive --target ${TARGET}`, { stdio: 'inherit' });

const slug = 'opencode-test';

function run(cmd, env = {}) {
  console.log(`> ${cmd}`);
  execSync(cmd, { cwd: TARGET, stdio: 'inherit', env: { ...process.env, ...env, SPRINT_RUNTIME: 'opencode' } });
}

try {
  run(`bash scripts/sprint-start.sh ${slug}`, { SPRINT_PRECHECK_BYPASS: '1' });

  run(`node scripts/sprint-spec-wizard.mjs set-mode ${slug} autopilot`);
  const answerCmd = `node scripts/sprint-spec-wizard.mjs complete-section ${slug}`;
  for (const s of ['A','B','C','D','E','F','G','H','I','J']) {
    run(`${answerCmd} ${s}`);
  }
  run(`node scripts/sprint-wizard-coherence.mjs ${slug} C --record true "mock"`);
  run(`node scripts/sprint-wizard-coherence.mjs ${slug} F --record true "mock"`);
  run(`node scripts/sprint-wizard-coherence.mjs ${slug} I --record true "mock"`);
  
  const statePathPartial = join(TARGET, `docs/sprints/${slug}/spec.partial.json`);
  const st = JSON.parse(readFileSync(statePathPartial, 'utf8'));
  st.sections_answers = { A: { A1: "mock" } };
  writeFileSync(statePathPartial, JSON.stringify(st));
  
  run(`node scripts/sprint-wizard-assemble.mjs ${slug}`);

  writeFileSync(join(TARGET, `docs/sprints/${slug}/solution-sketches.md`), 'dummy content'.repeat(50));
  writeFileSync(join(TARGET, `docs/sprints/${slug}/architect-review.md`), 'dummy content'.repeat(50));
  writeFileSync(join(TARGET, `docs/sprints/${slug}/security-review.md`), 'dummy content'.repeat(50));
  writeFileSync(join(TARGET, `docs/sprints/${slug}/consensus-spec.json`), '{"verdict":"pass"}');
  
  run(`SPRINT_BYPASS_GATE='wizard-coherence-after-C,wizard-coherence-after-F,wizard-coherence-after-I,wizard-assemble' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh spec-locked`);
  
  const statePath = join(TARGET, `docs/sprints/${slug}/state.json`);
  const state = JSON.parse(readFileSync(statePath, 'utf8'));
  state.worker_rigor = "lax";
  state.files_touched = ["package.json"];
  state.acs_total = 1;
  writeFileSync(statePath, JSON.stringify(state));
  writeFileSync(join(TARGET, `docs/sprints/${slug}/.baseline-embedding.json`), '{"mock":true}');

  writeFileSync(join(TARGET, `docs/sprints/${slug}/design.md`), 'dummy content'.repeat(50));
  run(`SPRINT_BYPASS_GATE='spec-lock-solution-sketches,spec-lock-architect-review,spec-lock-security-review,spec-lock-hive-mind-consensus,spec-lock-baseline-written' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh design-locked`);

  run(`SPRINT_BYPASS_GATE='design-sparc-spec-pseudocode,design-sparc-architect,design-locked' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh building`);

  const thirty = 'dummy dummy dummy dummy dummy dummy dummy dummy dummy dummy dummy dummy dummy dummy';
  writeFileSync(join(TARGET, `docs/sprints/${slug}/check-in-day5.md`), `### Cut\n${thirty}\n### Push\n${thirty}\n### Pivot\n${thirty}\n`);
  writeFileSync(join(TARGET, `docs/sprints/${slug}/hill-chart.md`), 'dummy');
  run(`SPRINT_BYPASS_GATE='build-launched' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh day-5-checkin`);
  run(`SPRINT_BYPASS_GATE='day-5-question-cut,day-5-question-push,day-5-question-pivot,day-5-hill-chart-refreshed' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh building`);

  writeFileSync(join(TARGET, `docs/sprints/${slug}/deadcode-deletions.json`), '[]');
  writeFileSync(join(TARGET, `docs/sprints/${slug}/test-hardening.csv`), 'mock');
  writeFileSync(join(TARGET, `docs/sprints/${slug}/test-hardening.json`), '{}');
  writeFileSync(join(TARGET, `docs/sprints/${slug}/claude-md-proposed-diff.patch`), 'mock');
  run(`bash scripts/sprint-advance-phase.sh cleaning`);

  const wo = join(TARGET, `docs/sprints/${slug}/worker-output`);
  mkdirSync(wo, { recursive: true });
  writeFileSync(join(wo, 'audit.json'), JSON.stringify({ findings: [] }));
  writeFileSync(join(wo, 'testgaps.json'), JSON.stringify({ gaps: [] }));
  writeFileSync(join(wo, 'optimize.json'), JSON.stringify({ recommendations: [] }));
  
  const verifyRunsDir = join(TARGET, `docs/sprints/${slug}/verify-runs`);
  mkdirSync(verifyRunsDir, { recursive: true });
  writeFileSync(join(verifyRunsDir, '2026-05-19T000000Z.log'), 'dummy');
  const state3 = JSON.parse(readFileSync(statePath, 'utf8'));
  state3.verify_runs = ["2026-05-19T000000Z.log"];
  writeFileSync(statePath, JSON.stringify(state3));

  run(`SPRINT_BYPASS_GATE='cleanup-deadcode-delete,cleanup-lint-fix,cleanup-claude-md-clean' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh verifying`);

  run(`SPRINT_BYPASS_GATE='verify-typecheck,verify-lint,verify-tests,verify-api-contract,verify-debug-rls,verify-module-status,verify-perf-profile,verify-aidefence-scan,verify-sonar,verify-knip,verify-cycle-check,verify-audit-deps,verify-bundle-budget,verify-coverage-delta,verify-migration-check,verify-worker-audit,verify-worker-testgaps,verify-worker-optimize' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh review-resolution`);
  
  const state2 = JSON.parse(readFileSync(statePath, 'utf8'));
  state2.review_findings_resolved_count = 0;
  state2.review_findings_total = 0;
  state2.review_findings_deferred = [];
  state2.review_findings_accepted = [];
  writeFileSync(statePath, JSON.stringify(state2));
  writeFileSync(join(TARGET, `docs/sprints/${slug}/review-resolutions.md`), 'mock '.repeat(300));

  writeFileSync(join(TARGET, `docs/sprints/${slug}/pre-deploy-review.md`), 'dummy'.repeat(50));
  run(`SPRINT_BYPASS_GATE='review-resolution-fired,review-findings-exit-predicate' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh pre-deploy`);

  const deploy = join(TARGET, `docs/sprints/${slug}/deploy`);
  mkdirSync(deploy, { recursive: true });
  writeFileSync(join(deploy, 'pulumi-preview.txt'), 'mock');
  writeFileSync(join(deploy, 'pulumi-up.txt'), 'mock');
  writeFileSync(join(deploy, 'smoke.json'), 'mock');
  writeFileSync(join(deploy, 'vercel.txt'), 'mock');
  run(`SPRINT_BYPASS_GATE='pre-deploy-reviewer-agent,pre-deploy-security-architect' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh deploying`);

  writeFileSync(join(TARGET, `docs/sprints/${slug}/retro.md`), '## Worked\n## Didnt\n## Surprised\n## Followups\n## Patterns\n## Claude\n### Pattern 1: a\n### Pattern 2: b\n### Pattern 3: c\n');
  writeFileSync(join(TARGET, `docs/sprints/${slug}/metrics.json`), '{}');
  writeFileSync(join(TARGET, `docs/sprints/${slug}/dashboard.html`), 'mock');
  writeFileSync(join(TARGET, `docs/sprints/${slug}/daa-feedback.json`), 'mock');
  run(`SPRINT_BYPASS_GATE='deploy-pulumi-preview-captured,deploy-human-gate-approved,deploy-pulumi-up,deploy-smoke,deploy-vercel' SPRINT_BYPASS_WHY='Simulated e2e runner' bash scripts/sprint-advance-phase.sh done`);

  console.log('\n✅ OpenCode E2E walker finished successfully!');

} catch (e) {
  console.error('❌ E2E failed:', e.message);
  process.exit(1);
} finally {
  rmSync(TARGET, { recursive: true, force: true });
}
