#!/usr/bin/env node
/**
 * sprint-test-hardening.mjs — Emit missing-tests report for routes touched
 * this sprint.
 *
 * AC-19 (sprint-system-100). Day 9 of each sprint, this scans
 * state.json.files_touched for Lambda route files and checks whether each has
 * a corresponding test file. Writes:
 *
 *   docs/sprints/<slug>/test-hardening.csv
 *   docs/sprints/<slug>/test-hardening.json
 *
 * Status values:
 *   OK            — route has a *.test.ts in same package, plus coverage data
 *                    if available
 *   MISSING_TEST  — no matching test file found
 *   LOW_COVERAGE  — test exists but coverage < 60%
 *
 * Usage:
 *   node scripts/sprint-test-hardening.mjs <slug> [--json]
 */

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, basename, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const slug = process.argv[2]
if (!slug) {
  console.error('Usage: sprint-test-hardening.mjs <slug> [--json]')
  process.exit(1)
}

const asJson = process.argv.includes('--json')
const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
const statePath = join(sprintDir, 'state.json')

if (!existsSync(statePath)) {
  console.error(`[!] state.json missing for ${slug}`)
  process.exit(1)
}

const state = JSON.parse(readFileSync(statePath, 'utf8'))
const filesTouched = state.files_touched || []

// Filter to Lambda route files
const ROUTE_RE = /^apps\/lambdas\/[^/]+\/src\/routes\/[^/]+\.ts$/
const routeFiles = filesTouched.filter((f) => ROUTE_RE.test(f))

// Also discover routes added in sprint via git diff (catch newly-added files)
import { execSync } from 'node:child_process'
let gitNew = []
try {
  const base =
    execSync('git merge-base HEAD main', { cwd: REPO_ROOT, encoding: 'utf8' }).trim() || 'main'
  const out = execSync(`git diff --name-only --diff-filter=A ${base}...HEAD`, {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })
  gitNew = out
    .trim()
    .split('\n')
    .filter((f) => ROUTE_RE.test(f))
} catch {}

const allRoutes = [...new Set([...routeFiles, ...gitNew])]

if (allRoutes.length === 0) {
  console.log('[i] No Lambda route files in this sprint — nothing to harden.')
  process.exit(0)
}

// For each route, find matching test file
function findTestFor(routePath) {
  const routeName = basename(routePath, '.ts')
  const lambdaDir = routePath.split('/').slice(0, 4).join('/') // apps/lambdas/<lambda>/src
  // Try common test locations
  const candidates = [
    join(REPO_ROOT, lambdaDir, '__tests__', `${routeName}.test.ts`),
    join(REPO_ROOT, lambdaDir, 'routes', `__tests__`, `${routeName}.test.ts`),
    join(REPO_ROOT, lambdaDir, '..', '__tests__', `routes`, `${routeName}.test.ts`),
    join(REPO_ROOT, lambdaDir, '..', 'test', `${routeName}.test.ts`),
  ]
  for (const c of candidates) {
    if (existsSync(c)) return relative(REPO_ROOT, c)
  }
  // Fallback: deep scan the lambda for any test file referencing this route
  try {
    const r = execSync(
      `grep -rl --include='*.test.ts' "${routeName}" "${join(REPO_ROOT, 'apps', 'lambdas')}" 2>/dev/null || true`,
      { encoding: 'utf8' },
    )
    const first = r.trim().split('\n').filter(Boolean)[0]
    if (first) return relative(REPO_ROOT, first)
  } catch {}
  return null
}

// Coverage data (if lcov is present from a recent test run)
let coverage = {}
try {
  // Reuse the c8 output that sprint-coverage-delta.mjs reads
  const covPath = join(sprintDir, 'coverage-current.json')
  if (existsSync(covPath)) coverage = JSON.parse(readFileSync(covPath, 'utf8'))
} catch {}

const rows = []
for (const route of allRoutes) {
  const testFile = findTestFor(route)
  const covRecord = coverage[route] || coverage['./' + route]
  let status = 'OK'
  let reason = ''

  if (!testFile) {
    status = 'MISSING_TEST'
    reason = 'no matching .test.ts found in sibling __tests__/ or via grep'
  } else if (covRecord && covRecord.line_pct < 60) {
    status = 'LOW_COVERAGE'
    reason = `${covRecord.line_pct}% line coverage (< 60% threshold)`
  } else if (!covRecord) {
    status = 'OK'
    reason = 'test exists; no coverage data (run pnpm test:playbook:cov for accuracy)'
  }

  rows.push({
    route,
    test_file: testFile || '',
    coverage_pct: covRecord ? covRecord.line_pct : null,
    status,
    reason,
  })
}

// Sort: MISSING_TEST first, then LOW_COVERAGE, then OK
rows.sort((a, b) => {
  const order = { MISSING_TEST: 0, LOW_COVERAGE: 1, OK: 2 }
  return order[a.status] - order[b.status] || a.route.localeCompare(b.route)
})

const csv = ['route,test_file,coverage_pct,status,reason']
for (const r of rows) {
  csv.push(
    `"${r.route}","${r.test_file}",${r.coverage_pct ?? ''},${r.status},"${r.reason.replace(/"/g, "'")}"`,
  )
}
writeFileSync(join(sprintDir, 'test-hardening.csv'), csv.join('\n'))
writeFileSync(
  join(sprintDir, 'test-hardening.json'),
  JSON.stringify({ slug, generated_at: new Date().toISOString(), rows }, null, 2),
)

if (asJson) {
  console.log(JSON.stringify({ slug, rows }, null, 2))
} else {
  const missing = rows.filter((r) => r.status === 'MISSING_TEST').length
  const lowCov = rows.filter((r) => r.status === 'LOW_COVERAGE').length
  const ok = rows.filter((r) => r.status === 'OK').length
  console.log(`Test hardening: ${slug}`)
  console.log(`  Routes scanned:  ${rows.length}`)
  console.log(`  ✓ OK:            ${ok}`)
  console.log(`  ⚠ MISSING_TEST:  ${missing}`)
  console.log(`  ⚠ LOW_COVERAGE:  ${lowCov}`)
  console.log('')
  if (missing > 0 || lowCov > 0) {
    console.log('Routes needing attention:')
    for (const r of rows.slice(0, 15)) {
      if (r.status === 'OK') continue
      console.log(`  ${r.status === 'MISSING_TEST' ? '✗' : '⚠'} ${r.route} — ${r.reason}`)
    }
  }
  console.log('')
  console.log(`Report: ${join(sprintDir, 'test-hardening.csv')}`)
}
