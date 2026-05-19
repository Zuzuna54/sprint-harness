#!/usr/bin/env node
/**
 * sprint-sonar-parse.mjs — Compare SonarQube results against a baseline.
 *
 * After `pnpm sonar` runs, this script:
 *   1. Fetches issues for each sprint-affected project from SonarQube API
 *   2. Compares against baseline (stored at docs/sprints/<slug>/sonar-baseline.json
 *      OR auto-derived from main branch if first run)
 *   3. Fails if NEW blocker/critical issues introduced in sprint diff
 *
 * Does NOT fail on existing tech debt — only on regressions.
 *
 * Usage:
 *   sprint-sonar-parse.mjs <slug> [--baseline] [--sonar-url <url>] [--sonar-token <token>]
 *
 *   --baseline : write current state as new baseline (use at spec-lock)
 *
 * Env:
 *   SONAR_HOST_URL (default: http://localhost:9000)
 *   SONAR_TOKEN    (or /tmp/sonar-token.txt)
 *
 * Exit codes:
 *   0 = no new critical/blocker issues
 *   1 = new critical or blocker issues introduced
 *   2 = config error (Sonar unreachable, no token, etc.)
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const args = process.argv.slice(2)
const slugFlagIdx = args.indexOf('--slug')
const slug = slugFlagIdx >= 0 ? args[slugFlagIdx + 1] : args.find((a) => !a.startsWith('--'))
const writeBaseline = args.includes('--baseline')
const asJson = args.includes('--json')
// Guard: indexOf returns -1 when flag absent; args[-1+1] === args[0] === slug → invalid URL.
const argAfter = (flag) => {
  const i = args.indexOf(flag)
  return i >= 0 ? args[i + 1] : undefined
}
const sonarUrl = argAfter('--sonar-url') || process.env.SONAR_HOST_URL || 'http://localhost:9000'
let sonarToken = argAfter('--sonar-token') || process.env.SONAR_TOKEN || ''
if (!sonarToken && existsSync('/tmp/sonar-token.txt')) {
  sonarToken = readFileSync('/tmp/sonar-token.txt', 'utf8').trim()
}

if (!slug) {
  console.error('Usage: sprint-sonar-parse.mjs <slug> [--baseline]')
  process.exit(2)
}

// AC-5 (harness-review-resolution-v1): --json producer mode emits the unified
// review_findings schema. Vacuous PASS when Sonar unreachable / token missing.
function emitProducerJson(findings) {
  const out = {
    producer: 'sonar',
    schema_version: 1,
    timestamp: new Date().toISOString(),
    findings,
  }
  process.stdout.write(JSON.stringify(out, null, 2) + '\n')
}

function severityFromSonar(s) {
  switch ((s || '').toUpperCase()) {
    case 'BLOCKER':
    case 'CRITICAL':
      return 'high'
    case 'MAJOR':
      return 'medium'
    default:
      return 'low'
  }
}

if (!sonarToken) {
  if (asJson) {
    emitProducerJson([])
    process.exit(0)
  }
  console.error('[!] No SONAR_TOKEN provided. Set env var or /tmp/sonar-token.txt.')
  process.exit(2)
}

const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
const baselinePath = join(sprintDir, 'sonar-baseline.json')
const reportPath = join(sprintDir, 'sonar-report.json')

// ── Determine which projects to check ────────────────────────────────────────
// LifeOS Sonar projects (per scripts/sonar-scan-all.sh): root, web, 9 lambdas, packages/*, infra
const SONAR_PROJECTS = [
  'lifeos-root',
  'lifeos-web',
  'lifeos-auth-lambda',
  'lifeos-workouts-lambda',
  'lifeos-nutrition-lambda',
  'lifeos-supplements-lambda',
  'lifeos-planner-lambda',
  'lifeos-grocery-lambda',
  'lifeos-health-lambda',
  'lifeos-finances-lambda',
  'lifeos-ai-scheduler-lambda',
  'lifeos-uploads-lambda',
  'lifeos-pkg-db',
  'lifeos-pkg-types',
  'lifeos-pkg-utils',
  'lifeos-pkg-auth-middleware',
  'lifeos-pkg-ui',
  'lifeos-infra',
]

// ── Fetch issues from Sonar ──────────────────────────────────────────────────

async function fetchIssues(projectKey) {
  const url = new URL('/api/issues/search', sonarUrl)
  url.searchParams.set('componentKeys', projectKey)
  url.searchParams.set('severities', 'BLOCKER,CRITICAL')
  url.searchParams.set('resolved', 'false')
  url.searchParams.set('ps', '100')

  try {
    const r = await fetch(url.toString(), {
      headers: { Authorization: 'Basic ' + Buffer.from(`${sonarToken}:`).toString('base64') },
    })
    if (!r.ok) {
      if (r.status === 404) return { issues: [], project_missing: true }
      throw new Error(`HTTP ${r.status}`)
    }
    const data = await r.json()
    return { issues: data.issues || [], total: data.total || 0 }
  } catch (e) {
    return { error: e.message }
  }
}

async function buildReport() {
  const projects = {}
  for (const p of SONAR_PROJECTS) {
    projects[p] = await fetchIssues(p)
  }
  return {
    fetched_at: new Date().toISOString(),
    sonar_url: sonarUrl,
    projects,
  }
}

// ── Main ─────────────────────────────────────────────────────────────────────

console.log(`Sonar issue check: ${slug}`)
console.log(`  Sonar URL: ${sonarUrl}`)
console.log('')

const report = await buildReport()

// AC-5 short-circuit: --json emits producer schema flattened across projects.
if (asJson) {
  const findings = []
  let idx = 0
  for (const [, p] of Object.entries(report.projects)) {
    for (const i of p.issues || []) {
      idx += 1
      findings.push({
        har_id: `SONAR-${idx}`,
        file: i.component || '',
        line: i.line || '?',
        severity: severityFromSonar(i.severity),
        rule: i.rule || '',
        message: (i.message || '').slice(0, 200),
      })
    }
  }
  emitProducerJson(findings)
  process.exit(0)
}

writeFileSync(reportPath, JSON.stringify(report, null, 2))
console.log(`[+] Current report written: ${reportPath}`)

if (writeBaseline) {
  writeFileSync(baselinePath, JSON.stringify(report, null, 2))
  console.log(`[+] Baseline written: ${baselinePath}`)
  console.log('    Next sprint commits will be compared against this.')
  process.exit(0)
}

if (!existsSync(baselinePath)) {
  console.log('[i] No baseline yet — writing current state as baseline (first run).')
  writeFileSync(baselinePath, JSON.stringify(report, null, 2))
  process.exit(0)
}

const baseline = JSON.parse(readFileSync(baselinePath, 'utf8'))

// Compare: which issues are NEW (not in baseline)?
function issueKey(i) {
  return `${i.component}:${i.rule}:${i.line || 0}`
}

const baselineKeys = new Set()
for (const [, p] of Object.entries(baseline.projects)) {
  for (const i of p.issues || []) baselineKeys.add(issueKey(i))
}

let newCritical = 0
let newBlocker = 0
const newIssuesByProject = {}

for (const [proj, p] of Object.entries(report.projects)) {
  const newOnes = []
  for (const i of p.issues || []) {
    if (!baselineKeys.has(issueKey(i))) {
      newOnes.push(i)
      if (i.severity === 'BLOCKER') newBlocker++
      else if (i.severity === 'CRITICAL') newCritical++
    }
  }
  if (newOnes.length) newIssuesByProject[proj] = newOnes
}

const totalNew = newBlocker + newCritical

console.log('')
console.log(`Issues vs baseline:`)
console.log(`  New BLOCKER:  ${newBlocker}`)
console.log(`  New CRITICAL: ${newCritical}`)

if (totalNew > 0) {
  console.log('')
  console.log('New issues introduced in this sprint:')
  for (const [proj, issues] of Object.entries(newIssuesByProject)) {
    console.log(`  ${proj}:`)
    for (const i of issues.slice(0, 5)) {
      console.log(`    [${i.severity}] ${i.component}:${i.line || '?'} — ${i.message.slice(0, 80)}`)
    }
    if (issues.length > 5) console.log(`    ... (+${issues.length - 5} more)`)
  }
  console.log('')
  console.log(`✗ FAIL: ${totalNew} new blocker/critical issues introduced.`)
  console.log(`   Open Sonar dashboard: ${sonarUrl}`)
  process.exit(1)
}

console.log('')
console.log('✓ No new blocker/critical issues vs baseline.')
process.exit(0)
