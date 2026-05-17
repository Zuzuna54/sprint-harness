#!/usr/bin/env node
/**
 * sprint-changelog.mjs — Generate per-sprint CHANGELOG.md + cross-sprint
 * capabilities index.
 *
 * AC-30 (sprint-system-100). At sprint-end:
 *   1. Parse spec.md §I for ACs + their summaries
 *   2. Parse state.json for acs_closed_ids + files_touched + scope_amendments
 *   3. git log between started_at and now → per-commit diff stats
 *   4. Parse retro.md for "Patterns extracted" entries
 *   5. Write docs/sprints/<slug>/CHANGELOG.md
 *   6. Update docs/sprints/_index/capabilities.md (aggregated)
 *
 * Future wizards grep capabilities.md in §H to surface "what already exists"
 * before users propose a duplicate surface.
 *
 * Usage:
 *   node scripts/sprint-changelog.mjs <slug>
 */

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const slug = process.argv[2]
if (!slug) {
  console.error('Usage: sprint-changelog.mjs <slug>')
  process.exit(1)
}

const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
const specPath = join(sprintDir, 'spec.md')
const statePath = join(sprintDir, 'state.json')
const retroPath = join(sprintDir, 'retro.md')
const changelogPath = join(sprintDir, 'CHANGELOG.md')
const indexPath = join(REPO_ROOT, 'docs', 'sprints', '_index', 'capabilities.md')

if (!existsSync(specPath) || !existsSync(statePath)) {
  console.error(`[!] spec.md or state.json missing for ${slug}`)
  process.exit(1)
}

const spec = readFileSync(specPath, 'utf8')
const state = JSON.parse(readFileSync(statePath, 'utf8'))
const retro = existsSync(retroPath) ? readFileSync(retroPath, 'utf8') : ''

// ── Parse ACs from spec.md §I ──────────────────────────────────────────────
const acRe = /\*\*(AC-\d+)\*\*[^\n]*\n([^\n]+(?:\n\s*-[^\n]+)*)/g
const acs = []
let m
while ((m = acRe.exec(spec)) !== null) {
  acs.push({
    id: m[1],
    summary: m[2]
      .split('\n')[0]
      .replace(/^[—-]\s*/, '')
      .slice(0, 200)
      .trim(),
  })
}

const closedSet = new Set(state.acs_closed_ids || [])

// ── Parse patterns from retro.md ───────────────────────────────────────────
const patterns = []
if (retro) {
  const patSection = retro.match(/##\s+Patterns extracted[^\n]*\n([\s\S]*?)(?=\n##\s|\n---|$)/i)
  if (patSection) {
    const patRe =
      /\*\*((?:<BRAND_SLUG>|ordex)-[a-z0-9-]+)\*\*\s*[—:-]+\s*(.+?)(?=\n(?:\*\*|-|\d+\.|##|$))/gs
    let mm
    while ((mm = patRe.exec(patSection[1])) !== null) {
      patterns.push({ key: mm[1].trim(), desc: mm[2].trim().replace(/\n+/g, ' ').slice(0, 250) })
    }
  }
}

// ── Per-commit stats since started_at ──────────────────────────────────────
const startedAt = state.started_at || null
let commits = []
if (startedAt) {
  try {
    const out = execSync(`git log --since="${startedAt}" --pretty=format:"%H|%s" --no-merges`, {
      cwd: REPO_ROOT,
      encoding: 'utf8',
    })
    commits = out
      .trim()
      .split('\n')
      .filter(Boolean)
      .map((line) => {
        const [sha, ...subjParts] = line.split('|')
        return { sha: sha.slice(0, 7), subject: subjParts.join('|') }
      })
      .filter((c) => /\bAC-\d+\b/.test(c.subject) || /sprint-system/.test(c.subject))
  } catch {}
}

// ── Build CHANGELOG.md ─────────────────────────────────────────────────────
const today = new Date().toISOString().slice(0, 10)
const lines = []
lines.push(`# Changelog: ${slug}`)
lines.push('')
lines.push(`Closed: ${today}`)
lines.push('')
lines.push(`## Capabilities added (${closedSet.size} of ${acs.length} ACs)`)
lines.push('')
for (const ac of acs) {
  const status = closedSet.has(ac.id) ? '✓' : '○'
  lines.push(`- ${status} **${ac.id}** — ${ac.summary}`)
}
lines.push('')

const filesTouched = state.files_touched || []
if (filesTouched.length > 0) {
  lines.push(`## Files touched (${filesTouched.length})`)
  lines.push('')
  // Group by top-level dir
  const groups = {}
  for (const f of filesTouched) {
    const top = f.split('/')[0] || 'root'
    ;(groups[top] = groups[top] || []).push(f)
  }
  for (const [g, fs] of Object.entries(groups)) {
    lines.push(`### ${g}/`)
    for (const f of fs.slice(0, 20)) lines.push(`- \`${f}\``)
    if (fs.length > 20) lines.push(`- ... and ${fs.length - 20} more`)
    lines.push('')
  }
}

if (patterns.length > 0) {
  lines.push(`## Patterns added to memory (${patterns.length})`)
  lines.push('')
  for (const p of patterns) {
    lines.push(`- **${p.key}** — ${p.desc}`)
  }
  lines.push('')
}

if (commits.length > 0) {
  lines.push(`## Commits (${commits.length})`)
  lines.push('')
  for (const c of commits.slice(0, 50)) {
    lines.push(`- \`${c.sha}\` ${c.subject}`)
  }
  if (commits.length > 50) lines.push(`- ... and ${commits.length - 50} more`)
  lines.push('')
}

const scopeAmends = state.scope_amendments || []
if (scopeAmends.length > 0) {
  lines.push(`## Scope amendments (${scopeAmends.length})`)
  lines.push('')
  for (const a of scopeAmends) {
    lines.push(`- ${a.at} — ${a.action} ${a.path || a.cut_acs || ''}`)
    if (a.why) lines.push(`  - **Why:** ${a.why}`)
    if (a.intent) lines.push(`  - **Intent:** ${a.intent}`)
  }
  lines.push('')
}

writeFileSync(changelogPath, lines.join('\n'))
console.log(`[+] Wrote ${changelogPath}`)

// ── Aggregate into capabilities index ──────────────────────────────────────
// Scan all sprint dirs for CHANGELOG.md "Capabilities added" sections.
const sprintsRoot = join(REPO_ROOT, 'docs', 'sprints')
const entries = readdirSync(sprintsRoot).filter((d) => {
  const p = join(sprintsRoot, d)
  if (d === '_template' || d === '_index') return false
  if (d === 'README.md' || d === 'USAGE.md' || d === 'DEVELOPER.md' || d === 'QUICKSTART.md')
    return false
  return existsSync(join(p, 'CHANGELOG.md'))
})

const indexLines = []
indexLines.push('# <BRAND_SLUG_TITLE> sprint capabilities index')
indexLines.push('')
indexLines.push(`Auto-aggregated from each sprint's CHANGELOG.md. Last updated: ${today}.`)
indexLines.push('')
indexLines.push('Wizards: grep this file during §H integration to find existing capabilities')
indexLines.push('before proposing a duplicate surface.')
indexLines.push('')

for (const s of entries.sort()) {
  const cl = readFileSync(join(sprintsRoot, s, 'CHANGELOG.md'), 'utf8')
  const capSec = cl.match(/##\s+Capabilities added[^\n]*\n([\s\S]*?)(?=\n##\s|$)/)
  if (!capSec) continue
  indexLines.push(`## ${s}`)
  indexLines.push('')
  indexLines.push(capSec[1].trim())
  indexLines.push('')
}

writeFileSync(indexPath, indexLines.join('\n'))
console.log(`[+] Wrote ${indexPath}`)
console.log(`    Sprints aggregated: ${entries.length}`)
