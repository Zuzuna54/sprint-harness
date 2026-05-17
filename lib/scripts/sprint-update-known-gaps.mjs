#!/usr/bin/env node
/**
 * sprint-update-known-gaps.mjs — AC-8 (Bug #22)
 *
 * At sprint-end, check whether any of the resolved ACs/bugs referenced in this
 * sprint correspond to items still listed in the project's known-gaps memory
 * (e.g. `planner_current_state.md`). Surface the candidates so the user can
 * cross them off — closes the loop where sprints resolve gaps but memory stays
 * stale.
 *
 * Modes:
 *   - default: list mode (print candidates, exit 0; user crosses off manually)
 *   - --auto-strike: rewrite the memory file in place, marking matched lines
 *                    with a ~~strikethrough~~ + "(resolved <slug> <date>)"
 *
 * Usage:
 *   node scripts/sprint-update-known-gaps.mjs <slug> [--auto-strike]
 */

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')
// AC B4: derive memory dir from $HOME + encoded repo path (replaces hardcoded /Users/gio/)
const HOME = process.env.HOME || ''
const encodedRepo = REPO_ROOT.replace(/[^a-zA-Z0-9]/g, '-')
const MEMORY_DIR = process.env.SPRINT_MEMORY_DIR
  || join(HOME, '.claude', 'projects', encodedRepo, 'memory')

const [, , slug, ...flags] = process.argv
if (!slug) {
  console.error('Usage: sprint-update-known-gaps.mjs <slug> [--auto-strike]')
  process.exit(1)
}

const autoStrike = flags.includes('--auto-strike')

// ── 1. Read sprint state + spec to extract resolved bug/AC tokens ───────────
const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
const statePath = join(sprintDir, 'state.json')
const specPath = join(sprintDir, 'spec.md')

if (!existsSync(statePath)) {
  console.error(`[!] state.json missing for ${slug}`)
  process.exit(1)
}

const state = JSON.parse(readFileSync(statePath, 'utf8'))
const closedAcIds = state.acs_closed_ids || []
const spec = existsSync(specPath) ? readFileSync(specPath, 'utf8') : ''

// Extract bug numbers from spec.md AC headers like "AC-3 ... (Bug #21)"
const bugTokens = new Set()
const bugRe = /Bugs?\s*#?(\d+)/gi
let m
while ((m = bugRe.exec(spec)) !== null) bugTokens.add(`#${m[1]}`)

// Also include AC IDs in case gaps reference them directly
for (const ac of closedAcIds) bugTokens.add(ac)

if (bugTokens.size === 0) {
  console.log('[i] No resolved bug/AC tokens detected — nothing to cross off.')
  process.exit(0)
}

// ── 2. Find candidate memory files (anything containing "gap" in name or
//      pointing to gap content in MEMORY.md) ────────────────────────────────
const candidateFiles = []
if (existsSync(MEMORY_DIR)) {
  for (const f of readdirSync(MEMORY_DIR)) {
    if (!f.endsWith('.md') || f === 'MEMORY.md') continue
    const full = join(MEMORY_DIR, f)
    const content = readFileSync(full, 'utf8')
    if (/gap|known.gaps|pre-audit|wave/i.test(content)) {
      candidateFiles.push({ path: full, content })
    }
  }
}

if (candidateFiles.length === 0) {
  console.log('[i] No known-gaps memory files found — skipping.')
  process.exit(0)
}

// ── 3. For each file, find lines matching resolved tokens ───────────────────
const today = new Date().toISOString().slice(0, 10)
let totalMatches = 0
const fileResults = []

for (const { path: filePath, content } of candidateFiles) {
  const lines = content.split('\n')
  const matchedLineIdxs = []

  lines.forEach((line, idx) => {
    if (line.includes('~~')) return // already struck through
    for (const tok of bugTokens) {
      if (line.includes(tok)) {
        matchedLineIdxs.push(idx)
        break
      }
    }
  })

  if (matchedLineIdxs.length > 0) {
    fileResults.push({ filePath, lines, matchedLineIdxs })
    totalMatches += matchedLineIdxs.length
  }
}

if (totalMatches === 0) {
  console.log(
    `[i] No matches for resolved tokens [${[...bugTokens].join(', ')}] in known-gaps memory.`,
  )
  process.exit(0)
}

// ── 4. Output: list mode prints, auto-strike rewrites ───────────────────────
console.log('')
console.log(
  `═══ Known-gaps memory candidates (${totalMatches} match${totalMatches === 1 ? '' : 'es'} across ${fileResults.length} file${fileResults.length === 1 ? '' : 's'}) ═══`,
)
console.log(`Resolved tokens: ${[...bugTokens].join(', ')}`)
console.log('')

for (const { filePath, lines, matchedLineIdxs } of fileResults) {
  const rel = filePath.replace(MEMORY_DIR + '/', '')
  console.log(`📄 ${rel}`)
  for (const idx of matchedLineIdxs) {
    console.log(`   L${idx + 1}: ${lines[idx].trim().slice(0, 120)}`)
  }
  console.log('')

  if (autoStrike) {
    const newLines = lines.slice()
    for (const idx of matchedLineIdxs) {
      const original = newLines[idx]
      const trimmed = original.replace(/^(\s*-?\s*\[?[ x]?\]?\s*)/, '$1')
      newLines[idx] = `${trimmed} ~~RESOLVED~~ _(closed by ${slug}, ${today})_`
    }
    writeFileSync(filePath, newLines.join('\n'))
    console.log(`   ✓ Auto-struck ${matchedLineIdxs.length} line(s) in ${rel}`)
    console.log('')
  }
}

if (!autoStrike) {
  console.log('To auto-strike these in place, re-run with --auto-strike.')
  console.log('Otherwise edit the memory file(s) manually.')
}
