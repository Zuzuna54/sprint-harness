#!/usr/bin/env node
/**
 * sprint-coverage-delta.mjs — Compare coverage between sprint branch and main.
 *
 * Reads lcov.info files produced by `scripts/coverage-c8-from-playbook.sh` +
 * per-package vitest c8 output. Compares against a baseline (either passed
 * explicitly or computed from `main` if available).
 *
 * Fails if:
 *   - Any file's line coverage drops by > THRESHOLD_DROP_PCT (default 5)
 *   - New code added in sprint has < THRESHOLD_NEW_COVERAGE (default 60)
 *
 * Usage:
 *   sprint-coverage-delta.mjs <slug> [--baseline <path>] [--threshold-drop N] [--threshold-new N]
 *
 * Exit codes:
 *   0 = no significant coverage regression
 *   1 = regression detected
 *   2 = config error (no lcov, no baseline)
 */

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const args = process.argv.slice(2)
const slug = args.find((a) => !a.startsWith('--'))
// harness-full-coverage retro #5 — `args[args.indexOf("--x") + 1]` returns
// `args[0]` (slug) when the flag is absent because indexOf returns -1 and
// `-1 + 1 = 0`. Guard with argAfter() (`lifeos-args-indexof-trap` pattern).
function argAfter(flag, fallback = null) {
  const i = args.indexOf(flag)
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback
}
const baselineArg = argAfter('--baseline')
const thresholdDrop = parseInt(argAfter('--threshold-drop', '5'), 10)
const thresholdNew = parseInt(argAfter('--threshold-new', '60'), 10)
const asJson = args.includes('--json')

if (!slug) {
  console.error(
    'Usage: sprint-coverage-delta.mjs <slug> [--baseline <path>] [--threshold-drop N] [--threshold-new N]',
  )
  process.exit(2)
}

// ── Collect all lcov.info files ──────────────────────────────────────────────

function findLcovFiles(dir, found = []) {
  if (!existsSync(dir)) return found
  let entries
  try {
    entries = readdirSync(dir)
  } catch {
    return found
  }
  for (const e of entries) {
    if (e === 'node_modules' || e === '.turbo' || e === '.next' || e === '.git') continue
    const p = join(dir, e)
    let st
    try {
      st = statSync(p)
    } catch {
      continue
    }
    if (st.isDirectory()) {
      findLcovFiles(p, found)
    } else if (e === 'lcov.info') {
      found.push(p)
    }
  }
  return found
}

// ── Parse lcov format ────────────────────────────────────────────────────────

function parseLcov(content) {
  const files = {}
  let currentFile = null
  let lineFound = 0,
    lineHit = 0,
    branchFound = 0,
    branchHit = 0

  for (const line of content.split('\n')) {
    if (line.startsWith('SF:')) {
      currentFile = line.slice(3).trim()
      lineFound = 0
      lineHit = 0
      branchFound = 0
      branchHit = 0
    } else if (line.startsWith('LF:')) lineFound = +line.slice(3)
    else if (line.startsWith('LH:')) lineHit = +line.slice(3)
    else if (line.startsWith('BRF:')) branchFound = +line.slice(4)
    else if (line.startsWith('BRH:')) branchHit = +line.slice(4)
    else if (line === 'end_of_record' && currentFile) {
      const linePct = lineFound > 0 ? (lineHit / lineFound) * 100 : 0
      const branchPct = branchFound > 0 ? (branchHit / branchFound) * 100 : 0
      files[currentFile] = {
        line_pct: Number(linePct.toFixed(1)),
        branch_pct: Number(branchPct.toFixed(1)),
        line_found: lineFound,
        line_hit: lineHit,
      }
      currentFile = null
    }
  }
  return files
}

function collectCoverage(rootDir) {
  const lcovFiles = findLcovFiles(rootDir)
  const all = {}
  for (const f of lcovFiles) {
    try {
      const parsed = parseLcov(readFileSync(f, 'utf8'))
      for (const [k, v] of Object.entries(parsed)) {
        // Normalize path
        const rel = k.startsWith('/') ? relative(rootDir, k) : k
        all[rel] = v
      }
    } catch {}
  }
  return all
}

// ── Get list of files changed in sprint branch ───────────────────────────────

function getChangedFiles() {
  // AC-25 (sprint-system-100): use git merge-base, not direct main. Sprint
  // branches lag main; comparing against main's HEAD includes unrelated
  // commits and inflates the file list.
  const base = process.env.SPRINT_BASE_BRANCH || 'main'
  let mergeBase = base
  try {
    mergeBase =
      execSync(`git merge-base HEAD ${base}`, {
        cwd: REPO_ROOT,
        encoding: 'utf8',
      }).trim() || base
  } catch {}
  try {
    const out = execSync(`git diff --name-only --diff-filter=AM ${mergeBase}...HEAD`, {
      cwd: REPO_ROOT,
      encoding: 'utf8',
    })
    return out.trim().split('\n').filter(Boolean)
  } catch {
    return []
  }
}

// ── Main ─────────────────────────────────────────────────────────────────────

const currentCoverage = collectCoverage(REPO_ROOT)

if (Object.keys(currentCoverage).length === 0) {
  console.error('[!] No lcov.info files found. Run pnpm test:playbook:cov first.')
  process.exit(2)
}

// Baseline: from --baseline path, OR docs/sprints/<slug>/coverage-baseline.json, OR none (advisory)
let baseline = null
const sprintBaselinePath = join(REPO_ROOT, 'docs', 'sprints', slug, 'coverage-baseline.json')

if (baselineArg && existsSync(baselineArg)) {
  baseline = JSON.parse(readFileSync(baselineArg, 'utf8'))
} else if (existsSync(sprintBaselinePath)) {
  baseline = JSON.parse(readFileSync(sprintBaselinePath, 'utf8'))
}

const changedFiles = getChangedFiles()
const regressions = []
const newCodeLowCoverage = []

if (baseline) {
  for (const [file, cur] of Object.entries(currentCoverage)) {
    const base = baseline[file]
    if (!base) continue
    const drop = base.line_pct - cur.line_pct
    if (drop > thresholdDrop) {
      regressions.push({
        file,
        baseline_pct: base.line_pct,
        current_pct: cur.line_pct,
        drop,
      })
    }
  }
}

for (const f of changedFiles) {
  const cov =
    currentCoverage[f] || currentCoverage['./' + f] || currentCoverage[f.replace(/^\.\//, '')]
  if (cov && cov.line_pct < thresholdNew) {
    newCodeLowCoverage.push({
      file: f,
      line_pct: cov.line_pct,
    })
  }
}

const result = {
  slug,
  changed_files_count: changedFiles.length,
  files_with_coverage: Object.keys(currentCoverage).length,
  threshold_drop_pct: thresholdDrop,
  threshold_new_pct: thresholdNew,
  has_baseline: !!baseline,
  regressions,
  new_code_low_coverage: newCodeLowCoverage,
  pass: regressions.length === 0 && newCodeLowCoverage.length === 0,
}

// Save baseline as current (for next run)
import { writeFileSync, mkdirSync } from 'node:fs'
mkdirSync(join(REPO_ROOT, 'docs', 'sprints', slug), { recursive: true })
writeFileSync(
  join(REPO_ROOT, 'docs', 'sprints', slug, 'coverage-current.json'),
  JSON.stringify(currentCoverage, null, 2),
)

if (asJson) {
  console.log(JSON.stringify(result, null, 2))
} else {
  console.log(`Coverage delta: ${slug}`)
  console.log(`  Files w/ coverage: ${result.files_with_coverage}`)
  console.log(`  Files changed in sprint: ${result.changed_files_count}`)
  console.log(`  Thresholds: drop ≤ ${thresholdDrop}%, new files ≥ ${thresholdNew}%`)
  console.log(`  Baseline: ${baseline ? 'yes' : '(none — advisory mode)'}`)
  console.log('')
  if (regressions.length > 0) {
    console.log(`Regressions (${regressions.length}):`)
    for (const r of regressions.slice(0, 10)) {
      console.log(
        `  ✗ ${r.file}: ${r.baseline_pct}% → ${r.current_pct}% (drop: ${r.drop.toFixed(1)}pp)`,
      )
    }
    if (regressions.length > 10) console.log(`  ... (+${regressions.length - 10} more)`)
  }
  if (newCodeLowCoverage.length > 0) {
    console.log(`New code under-covered (${newCodeLowCoverage.length}):`)
    for (const n of newCodeLowCoverage.slice(0, 10)) {
      console.log(`  ✗ ${n.file}: ${n.line_pct}% (threshold: ${thresholdNew}%)`)
    }
  }
  console.log('')
  console.log(result.pass ? '✓ Coverage OK' : '✗ Coverage regression detected')
}

process.exit(result.pass ? 0 : 1)
