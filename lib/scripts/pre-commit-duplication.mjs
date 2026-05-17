#!/usr/bin/env node
/**
 * pre-commit-duplication.mjs — Block commits with >50% code duplication on
 * staged files.
 *
 * AC-17 (sprint-system-100). Runs in .husky/pre-commit during active sprint.
 * Uses jscpd (via pnpm dlx, no devDep install) on staged .ts/.tsx files only.
 *
 * Exit codes:
 *   0 = no duplication or below threshold
 *   1 = BLOCK (over 50% similarity detected)
 *   2 = jscpd unavailable / no staged TS files (skip)
 *
 * Override per-commit: SPRINT_DUP_BYPASS=1 (logged to state.gate_bypasses[])
 */

import { execSync, spawnSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const THRESHOLD = parseFloat(process.env.SPRINT_DUP_THRESHOLD || '50')

// Only fire during active sprint
let activeSlug = ''
try {
  activeSlug = execSync('bash scripts/sprint-status.sh --slug-only', {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim()
} catch {}
if (!activeSlug) process.exit(0)

// Bypass
if (process.env.SPRINT_DUP_BYPASS === '1') {
  process.stderr.write('[i] SPRINT_DUP_BYPASS=1 — skipping dup check (logged)\n')
  try {
    const sf = join(REPO_ROOT, 'docs', 'sprints', activeSlug, 'state.json')
    const s = JSON.parse(readFileSync(sf, 'utf8'))
    s.gate_bypasses = (s.gate_bypasses || []).concat([
      { at: new Date().toISOString(), gate: 'dup-check', threshold: THRESHOLD },
    ])
    writeFileSync(sf, JSON.stringify(s, null, 2))
  } catch {}
  process.exit(0)
}

// ── Get staged .ts/.tsx files ───────────────────────────────────────────────
let staged = ''
try {
  staged = execSync('git diff --cached --name-only --diff-filter=AM', {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })
} catch {
  process.exit(2)
}
const stagedTs = staged
  .trim()
  .split('\n')
  .filter((f) => /\.(ts|tsx)$/.test(f))
  .filter((f) => !/__tests__|\.test\.|\.spec\./.test(f))
  .filter((f) => existsSync(join(REPO_ROOT, f)))

if (stagedTs.length === 0) {
  process.exit(0) // no TS to check
}

if (stagedTs.length === 1) {
  // Single-file dup detection requires comparing against repo; that's the
  // longer-running scan. For speed, only run when ≥2 staged files (intra-set)
  // OR when SPRINT_DUP_REPO_SCAN=1 explicitly opts in.
  if (process.env.SPRINT_DUP_REPO_SCAN !== '1') {
    process.exit(0)
  }
}

// ── Run jscpd ──────────────────────────────────────────────────────────────
const work = mkdtempSync(join(tmpdir(), 'sprint-dup-'))
const reportDir = join(work, 'report')

const args = [
  'dlx',
  'jscpd',
  '--silent',
  '--min-tokens',
  '50',
  '--threshold',
  String(THRESHOLD),
  '--reporters',
  'json',
  '--output',
  reportDir,
  ...stagedTs,
]
const r = spawnSync('pnpm', args, { cwd: REPO_ROOT, encoding: 'utf8', timeout: 60_000 })
if (r.error || r.status === null) {
  process.stderr.write('[i] jscpd unavailable; skipping dup check\n')
  try {
    rmSync(work, { recursive: true, force: true })
  } catch {}
  process.exit(2)
}

const reportPath = join(reportDir, 'jscpd-report.json')
let dups = []
if (existsSync(reportPath)) {
  try {
    const report = JSON.parse(readFileSync(reportPath, 'utf8'))
    dups = report.duplicates || []
  } catch {}
}
try {
  rmSync(work, { recursive: true, force: true })
} catch {}

const highDups = dups.filter((d) => (d.fragment?.lines || 0) > 0)

if (highDups.length === 0) {
  process.exit(0)
}

// ── BLOCK ──────────────────────────────────────────────────────────────────
process.stderr.write(`\n╔══════════════════════════════════════════════════════════════════════╗\n`)
process.stderr.write(
  `║  AC-17: code duplication BLOCKED (threshold ${THRESHOLD}%)               ║\n`,
)
process.stderr.write(`╚══════════════════════════════════════════════════════════════════════╝\n`)
process.stderr.write(`  Active sprint: ${activeSlug}\n`)
process.stderr.write(`  Staged TS:     ${stagedTs.length} file(s)\n`)
process.stderr.write(`  Duplications:  ${highDups.length}\n\n`)
for (const d of highDups.slice(0, 5)) {
  process.stderr.write(
    `  ⚠ ${d.firstFile?.name || '?'} ↔ ${d.secondFile?.name || '?'} (${d.fragment?.lines || '?'} lines)\n`,
  )
}
process.stderr.write(`\n  Refactor to DRY before committing.\n`)
process.stderr.write(`  Per-commit bypass (logged): SPRINT_DUP_BYPASS=1 git commit ...\n\n`)
process.exit(1)
