#!/usr/bin/env node
// sprint-harness-readiness.mjs — aggregate proof/AC-N.md files into a single readiness report
// Usage: node scripts/sprint-harness-readiness.mjs <slug>

import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const slug = process.argv[2]
if (!slug) {
  console.error('usage: sprint-harness-readiness.mjs <slug>')
  process.exit(2)
}

const proofDir = join(REPO_ROOT, 'docs', 'sprints', slug, 'proof')
const files = readdirSync(proofDir)
  .filter((f) => /^AC-\d+\.md$/.test(f))
  .sort((a, b) => {
    const ai = parseInt(a.match(/\d+/)[0], 10)
    const bi = parseInt(b.match(/\d+/)[0], 10)
    return ai - bi
  })

const VERDICT_RE = /\*\*Verdict:\*\*\s*(.+?)$/m
const TITLE_RE = /^#\s+(AC-\d+)\s+—\s+(.+?)$/m

const rows = []
for (const f of files) {
  const path = join(proofDir, f)
  const body = readFileSync(path, 'utf8')
  const vMatch = body.match(VERDICT_RE)
  const tMatch = body.match(TITLE_RE)
  rows.push({
    file: f,
    ac: tMatch?.[1] ?? f.replace('.md', ''),
    title: tMatch?.[2] ?? '?',
    verdict: vMatch?.[1].trim() ?? 'unknown',
  })
}

function category(verdict) {
  if (verdict.includes('✓ PRODUCTION')) return 'PRODUCTION'
  if (verdict.includes('⚠')) return 'SCAFFOLDED'
  if (verdict.includes('✗')) return 'BROKEN'
  return 'UNKNOWN'
}

const counts = { PRODUCTION: 0, SCAFFOLDED: 0, BROKEN: 0, UNKNOWN: 0 }
for (const r of rows) {
  r.category = category(r.verdict)
  counts[r.category]++
}

const total = rows.length
const pct = (n) => ((n / total) * 100).toFixed(0)

const lines = []
lines.push(`# Harness Readiness — ${slug}`)
lines.push('')
lines.push(`Generated: ${new Date().toISOString()}`)
lines.push(`Total ACs: ${total}`)
lines.push('')
lines.push('## Summary')
lines.push('')
lines.push('| Category    | Count | % |')
lines.push('|-------------|-------|---|')
lines.push(`| ✓ Production  | ${counts.PRODUCTION} | ${pct(counts.PRODUCTION)}% |`)
lines.push(`| ⚠ Scaffolded  | ${counts.SCAFFOLDED} | ${pct(counts.SCAFFOLDED)}% |`)
lines.push(`| ✗ Broken      | ${counts.BROKEN} | ${pct(counts.BROKEN)}% |`)
if (counts.UNKNOWN) lines.push(`| ? Unknown     | ${counts.UNKNOWN} | ${pct(counts.UNKNOWN)}% |`)
lines.push('')
lines.push('## Per-AC verdict')
lines.push('')
lines.push('| AC | Capability | Verdict |')
lines.push('|----|------------|---------|')
for (const r of rows) {
  lines.push(`| [${r.ac}](proof/${r.file}) | ${r.title} | ${r.verdict} |`)
}

lines.push('')
lines.push('## What "Production" means here')
lines.push('')
lines.push('A capability is marked **✓ Production** only when:')
lines.push('1. It runs against real code (not synthetic)')
lines.push('2. When given a known injected violation, it CATCHES the violation')
lines.push('3. When the violation is removed, it goes back to green')
lines.push('4. There is a markdown proof file documenting all three')
lines.push('')
lines.push(
  '**⚠ Scaffolded** = script/infrastructure present, but inject-violation-catch-restore not exercised this cycle.',
)
lines.push('')
lines.push(
  '**✗ Broken / Not-Registered / Not-Wired** = real defect surfaced; filed as next-sprint follow-up.',
)
lines.push('')

const out = join(REPO_ROOT, 'docs', 'sprints', slug, 'harness-readiness.md')
writeFileSync(out, lines.join('\n'))
console.log(`wrote ${out}`)
console.log(`  Production: ${counts.PRODUCTION}/${total} (${pct(counts.PRODUCTION)}%)`)
console.log(`  Scaffolded: ${counts.SCAFFOLDED}/${total} (${pct(counts.SCAFFOLDED)}%)`)
console.log(`  Broken:     ${counts.BROKEN}/${total} (${pct(counts.BROKEN)}%)`)
