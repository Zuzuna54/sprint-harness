#!/usr/bin/env node
/**
 * sprint-claude-md-upgrade.mjs — Propose CLAUDE.md additions from sprint retro.
 *
 * AC-8 (sprint-system-100, Gap N).
 *
 * Inputs:
 *   - docs/sprints/<slug>/retro.md (Patterns extracted section)
 *   - docs/sprints/<slug>/spec.md (Files touched section)
 *   - docs/sprints/<slug>/state.json (acs_closed_ids, scope_amendments)
 *
 * Output:
 *   docs/sprints/<slug>/claude-md-proposed-diff.patch — unified diff that adds
 *   a new "### Pattern: <key>" block per extracted pattern, plus an entry in
 *   the "## Working knowledge index" section if it exists.
 *
 * Usage:
 *   node scripts/sprint-claude-md-upgrade.mjs <slug>
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const slug = process.argv[2]
if (!slug) {
  console.error('Usage: sprint-claude-md-upgrade.mjs <slug>')
  process.exit(1)
}

const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
const retroPath = join(sprintDir, 'retro.md')
const specPath = join(sprintDir, 'spec.md')
const statePath = join(sprintDir, 'state.json')
const claudeMdPath = join(REPO_ROOT, 'CLAUDE.md')
const patchPath = join(sprintDir, 'claude-md-proposed-diff.patch')

if (!existsSync(claudeMdPath)) {
  console.error(`[!] CLAUDE.md not found at ${claudeMdPath}`)
  process.exit(1)
}

// ── Parse retro.md for extracted patterns ──────────────────────────────────
const patterns = []
if (existsSync(retroPath)) {
  const retroText = readFileSync(retroPath, 'utf8')
  const section = retroText.match(/##\s+Patterns extracted[^\n]*\n([\s\S]*?)(?=\n##\s|\n---|$)/i)
  if (section) {
    // Match "**lifeos-key**: description" or "- **lifeos-key**: description" or
    // "1. **lifeos-key**: description"
    const re = /\*\*((?:lifeos|ordex)-[a-z0-9-]+)\*\*\s*:?\s*(.+?)(?=\n(?:\*\*|-|\d+\.|##|$))/gs
    let m
    while ((m = re.exec(section[1])) !== null) {
      const key = m[1].trim()
      const desc = m[2].trim().replace(/\n+/g, ' ').slice(0, 300)
      if (desc && !patterns.find((p) => p.key === key)) {
        patterns.push({ key, desc })
      }
    }
  }
}

// ── Parse spec.md for files touched ────────────────────────────────────────
let filesTouched = []
if (existsSync(specPath)) {
  const specText = readFileSync(specPath, 'utf8')
  const section = specText.match(/##\s+Files touched[^\n]*\n([\s\S]*?)(?=\n##\s|\n---|$)/)
  if (section) {
    const pathRe = /`([a-zA-Z0-9_./~*-]+\.(?:ts|tsx|js|jsx|mjs|cjs|sh|md|yaml|yml|json|plist))`/g
    const seen = new Set()
    let m
    while ((m = pathRe.exec(section[1])) !== null) {
      if (!seen.has(m[1])) {
        seen.add(m[1])
        filesTouched.push(m[1])
      }
    }
  }
}

// ── Parse state.json for closed ACs ────────────────────────────────────────
let closedACs = []
if (existsSync(statePath)) {
  try {
    const state = JSON.parse(readFileSync(statePath, 'utf8'))
    closedACs = state.acs_closed_ids || []
  } catch {}
}

if (patterns.length === 0 && filesTouched.length === 0 && closedACs.length === 0) {
  console.log('[i] Nothing to propose: no patterns/files/ACs found in sprint artifacts.')
  console.log('    Make sure retro.md has a "## Patterns extracted" section.')
  process.exit(0)
}

// ── Build proposed additions ───────────────────────────────────────────────
const today = new Date().toISOString().slice(0, 10)
const additionLines = []
additionLines.push('')
additionLines.push(`### Sprint ${slug} — additions (${today})`)
additionLines.push('')
additionLines.push(`Closed ACs: ${closedACs.length > 0 ? closedACs.join(', ') : '(none)'}`)
additionLines.push('')

if (patterns.length > 0) {
  additionLines.push('#### Patterns added to memory')
  for (const p of patterns) {
    additionLines.push(`- **${p.key}** — ${p.desc}`)
  }
  additionLines.push('')
}

if (filesTouched.length > 0) {
  additionLines.push('#### Files modified or added')
  for (const f of filesTouched.slice(0, 30)) {
    additionLines.push(`- \`${f}\``)
  }
  if (filesTouched.length > 30) {
    additionLines.push(`- ... and ${filesTouched.length - 30} more (see spec.md)`)
  }
  additionLines.push('')
}

additionLines.push(`See docs/sprints/${slug}/spec.md §I for full AC list and rationale.`)
additionLines.push('')

// ── Build unified diff manually (append at end of CLAUDE.md) ───────────────
const claudeMdContent = readFileSync(claudeMdPath, 'utf8')
const claudeMdLines = claudeMdContent.split('\n')
const totalLines = claudeMdLines.length

let diff = ''
diff += `--- a/CLAUDE.md\n`
diff += `+++ b/CLAUDE.md\n`
// Hunk header: append `additionLines.length` lines after the current end
diff += `@@ -${totalLines},0 +${totalLines + 1},${additionLines.length} @@\n`
for (const line of additionLines) {
  diff += `+${line}\n`
}

writeFileSync(patchPath, diff)

console.log(`[+] Generated ${patchPath}`)
console.log(`    Patterns: ${patterns.length}`)
console.log(`    Files:    ${filesTouched.length}`)
console.log(`    ACs:      ${closedACs.length}`)
console.log('')
console.log('Review with:  cat ' + patchPath)
console.log('Apply with:   git apply ' + patchPath + '  (run from repo root)')
console.log('Reject by:    rm ' + patchPath)
