#!/usr/bin/env node
/**
 * sprint-pair-check.mjs — Scan spec §I for ACs that should trigger pair-mode.
 *
 * Reads spec.md, parses AC blocks, applies the complex-AC keyword list
 * (auth/payment/RLS/migration/JWT/secret/delete/password/hash/encrypt),
 * returns the list of ACs that should engage pair-programming DRIVER mode.
 *
 * Usage:
 *   sprint-pair-check.mjs <slug>           # human-readable
 *   sprint-pair-check.mjs <slug> --json    # JSON output
 */

import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const [, , slug, ...flags] = process.argv
if (!slug) {
  console.error('Usage: sprint-pair-check.mjs <slug> [--json]')
  process.exit(1)
}

const asJson = flags.includes('--json')
const specPath = join(REPO_ROOT, 'docs', 'sprints', slug, 'spec.md')
if (!existsSync(specPath)) {
  console.error(`[!] spec.md not found: ${specPath}`)
  process.exit(1)
}

const COMPLEX_KEYWORDS = [
  'auth',
  'authentication',
  'authorization',
  'payment',
  'billing',
  'charge',
  'rls',
  'row-level',
  'policy',
  'migration',
  'schema change',
  'drop table',
  'jwt',
  'token',
  'secret',
  'credential',
  'key',
  'delete',
  'password',
  'hash',
  'encrypt',
  'decrypt',
]

const spec = readFileSync(specPath, 'utf8')

// Find AC blocks.
// harness-full-coverage retro #10 — accept multiple AC formats:
//   - **AC-1** complex: true          (original)
//   - **AC-14a** `complex: false`     (Phase-1 split-AC, letter suffix)
//   - **AC-15** (no complex flag — implicit false)
const acRegex =
  /\*\*AC-(\d+[a-z]?)\*\*(?:\s*`?\s*complex:\s*`?\s*(true|false)\s*`?)?([\s\S]*?)(?=\n\*\*AC-|\n---|\n## |$)/g
const acBlocks = []
let m
while ((m = acRegex.exec(spec)) !== null) {
  acBlocks.push({
    id: `AC-${m[1]}`,
    flagged_complex: m[2] === 'true',
    body: (m[3] ?? '').trim().slice(0, 1000),
  })
}

// Apply keyword detection on each AC body
const results = acBlocks.map((ac) => {
  const lowerBody = ac.body.toLowerCase()
  const matched = COMPLEX_KEYWORDS.filter((kw) => {
    // Word boundary regex
    const re = new RegExp(`\\b${kw.replace(/[-/\\^$*+?.()|[\]{}]/g, '\\$&')}\\b`, 'i')
    return re.test(lowerBody)
  })
  return {
    ...ac,
    auto_detected_complex: matched.length > 0,
    matched_keywords: matched,
    requires_pair_mode: ac.flagged_complex || matched.length > 0,
  }
})

if (asJson) {
  console.log(JSON.stringify({ slug, total_acs: results.length, results }, null, 2))
  process.exit(0)
}

// Human-readable
console.log(`Pair-mode check: ${slug}`)
console.log(`Total ACs: ${results.length}`)
console.log('')

const needPair = results.filter((r) => r.requires_pair_mode)
console.log(`Pair-mode required: ${needPair.length}`)

if (needPair.length === 0) {
  console.log('  (none — all ACs can use standard swarm TDD)')
  process.exit(0)
}

for (const ac of needPair) {
  const reason = ac.flagged_complex
    ? 'user-flagged complex'
    : `auto-detected: ${ac.matched_keywords.join(', ')}`
  console.log(`  ${ac.id} — ${reason}`)
}

console.log('')
console.log('During build phase, these ACs will engage /pair-programming DRIVER mode.')
