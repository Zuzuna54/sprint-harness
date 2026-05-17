#!/usr/bin/env node
/**
 * sprint-memory-decay.mjs — Age-decay confidence scores in .swarm/memory.db.
 *
 * Uses existing schema columns: `last_accessed_at`, `decay_rate`, `half_life_days`
 * on the patterns table. NO MIGRATION NEEDED.
 *
 * Algorithm (per pattern):
 *   age_ms = now - last_accessed_at
 *   age_half_lives = age_ms / (half_life_days * 86400000)
 *   decay_factor = pow(0.5, age_half_lives)
 *   new_confidence = confidence * decay_factor
 *
 * If new_confidence < FLOOR (default 0.2): mark status='archived'.
 * Archived patterns can be revived if recalled (memory CLI bumps last_accessed_at).
 *
 * Run cadence: daily by daemon's `consolidate` worker (or manually).
 *
 * Usage:
 *   sprint-memory-decay.mjs [--dry-run] [--floor 0.2] [--json]
 *
 * Exit codes:
 *   0 = ran successfully
 *   2 = config error (no DB)
 */

import { existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execSync, spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
// AC-6 (sprint-system-100, Gap J): REPO_ROOT env var override for launchd.
// Launchd runs with cwd=/ and PATH stripped — relative __dirname resolution
// fails. The plist must export REPO_ROOT explicitly.
const REPO_ROOT = process.env.REPO_ROOT || join(__dirname, '..')

const args = process.argv.slice(2)
const dryRun = args.includes('--dry-run')
const floor = parseFloat(args[args.indexOf('--floor') + 1] || '0.2')
const asJson = args.includes('--json')

const memoryDb = join(REPO_ROOT, '.swarm', 'memory.db')

if (!existsSync(memoryDb)) {
  console.error(`[!] Memory DB not found: ${memoryDb}`)
  process.exit(2)
}

function sql(query, mustSucceed = true) {
  const r = spawnSync('sqlite3', [memoryDb, query], { encoding: 'utf8' })
  if (r.status !== 0) {
    if (!mustSucceed) return ''
    throw new Error(
      `sqlite3 error on query: ${query.slice(0, 80)} — ${r.stderr || r.stdout || 'exit ' + r.status}`,
    )
  }
  return r.stdout
}

// Check whether `patterns` table has the columns we need
let hasPatternsTable = false
let hasDecayColumns = false
try {
  const schema = sql('.schema patterns', false)
  if (schema && schema.includes('CREATE TABLE patterns')) {
    hasPatternsTable = true
    hasDecayColumns = schema.includes('decay_rate') && schema.includes('half_life_days')
  }
} catch {}

if (!hasPatternsTable) {
  console.log(
    '[i] No `patterns` table in memory DB. Likely no patterns trained yet — nothing to decay.',
  )
  console.log('    Patterns are populated by `ruflo neural train` after ≥20 trajectories.')
  process.exit(0)
}

if (!hasDecayColumns) {
  console.log('[i] `patterns` table missing decay_rate / half_life_days columns.')
  console.log('    Older schema — decay logic skipped. Upgrade ruflo to populate these fields.')
  process.exit(0)
}

// Fetch all patterns with decay metadata
// Schema: patterns table has last_matched_at + updated_at + created_at
// (no last_accessed_at). Use COALESCE(last_matched_at, updated_at, created_at) as freshness.
const rows = sql(`
SELECT
  id,
  name,
  confidence,
  COALESCE(last_matched_at, updated_at, created_at) AS freshness_ts,
  half_life_days,
  decay_rate,
  status
FROM patterns
ORDER BY confidence DESC;
`)
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((line) => {
    const [id, name, confidence, freshness_ts, half_life_days, decay_rate, status] = line.split('|')
    return {
      id,
      name,
      confidence: parseFloat(confidence) || 0.5,
      last_accessed_at: parseInt(freshness_ts, 10) || Date.now(),
      half_life_days: parseFloat(half_life_days) || 30,
      decay_rate: parseFloat(decay_rate) || 0.01,
      status,
    }
  })

if (rows.length === 0) {
  console.log('[i] No patterns to decay.')
  process.exit(0)
}

const now = Date.now()
const updates = []
const toArchive = []

for (const row of rows) {
  if (row.status === 'archived') continue
  const ageMs = now - row.last_accessed_at
  const halfLifeMs = row.half_life_days * 86400000
  const ageHalfLives = ageMs / halfLifeMs
  const decayFactor = Math.pow(0.5, ageHalfLives)
  const newConfidence = Math.max(0, row.confidence * decayFactor)

  if (newConfidence < row.confidence - 0.001) {
    updates.push({
      id: row.id,
      name: row.name,
      old_confidence: Number(row.confidence.toFixed(3)),
      new_confidence: Number(newConfidence.toFixed(3)),
      age_days: Number((ageMs / 86400000).toFixed(1)),
    })
    if (newConfidence < floor) {
      toArchive.push({ id: row.id, name: row.name, final_confidence: newConfidence })
    }
  }
}

if (asJson) {
  console.log(
    JSON.stringify(
      {
        total_patterns: rows.length,
        updates_count: updates.length,
        to_archive: toArchive,
        floor,
        dry_run: dryRun,
        updates,
      },
      null,
      2,
    ),
  )
} else {
  console.log(`Memory decay: ${dryRun ? '(DRY-RUN) ' : ''}${rows.length} patterns scanned`)
  console.log(`  Confidence updates: ${updates.length}`)
  console.log(`  Below floor (${floor}) → archive: ${toArchive.length}`)
  console.log('')
  if (updates.length > 0) {
    console.log('Top 10 decays:')
    for (const u of updates.slice(0, 10)) {
      console.log(
        `  ${u.name?.slice(0, 50).padEnd(50)} ${u.old_confidence} → ${u.new_confidence}  (${u.age_days}d old)`,
      )
    }
  }
}

if (dryRun) process.exit(0)

// Apply updates
for (const u of updates) {
  sql(`UPDATE patterns SET confidence = ${u.new_confidence} WHERE id = '${u.id}';`)
}
for (const a of toArchive) {
  sql(`UPDATE patterns SET status = 'archived' WHERE id = '${a.id}';`)
}

console.log(`[+] Applied ${updates.length} decay updates, archived ${toArchive.length}.`)
