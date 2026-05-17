#!/usr/bin/env node
/**
 * sprint-retro-save-patterns.mjs — Parse retro.md and save patterns to ruflo.
 *
 * AC-3 (sprint-system-hardening, Bug #21): sprint-end mentioned retro patterns
 * but never actually saved them. This script:
 *   1. Reads docs/sprints/<slug>/retro.md
 *   2. Extracts "## Patterns extracted" section
 *   3. Finds each pattern: `**<BRAND_SLUG>-<key>**: <description>`
 *   4. Lists them + their `ruflo memory store` commands
 *   5. With --auto-save: runs the commands and tracks success/fail
 *   6. Without --auto-save: just lists (so user/orchestrator can confirm)
 *
 * Usage:
 *   sprint-retro-save-patterns.mjs <slug>             # list mode (safe)
 *   sprint-retro-save-patterns.mjs <slug> --auto-save # run the stores
 *   sprint-retro-save-patterns.mjs <slug> --json      # JSON output (for Claude)
 *
 * Exit codes:
 *   0 = all patterns parsed (and saved if --auto-save)
 *   1 = parse failed OR at least one save failed (with --auto-save)
 *   2 = config error
 */

import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const args = process.argv.slice(2)
const slug = args.find((a) => !a.startsWith('--'))
const autoSave = args.includes('--auto-save')
const asJson = args.includes('--json')

if (!slug) {
  console.error('Usage: sprint-retro-save-patterns.mjs <slug> [--auto-save] [--json]')
  process.exit(2)
}

const retroPath = join(REPO_ROOT, 'docs', 'sprints', slug, 'retro.md')
if (!existsSync(retroPath)) {
  console.error(`[!] retro.md not found: ${retroPath}`)
  process.exit(2)
}

const retro = readFileSync(retroPath, 'utf8')

// Find the "## Patterns extracted" section
const sectionMatch = retro.match(/^##\s+Patterns extracted[^\n]*\n([\s\S]*?)(?=^##\s|\Z)/m)
if (!sectionMatch) {
  if (asJson) {
    console.log(JSON.stringify({ slug, patterns: [], status: 'no-patterns-section' }))
  } else {
    console.log("[i] No '## Patterns extracted' section in retro.md — nothing to save.")
  }
  process.exit(0)
}

const sectionText = sectionMatch[1]

// Parse patterns: match either bullet form (- **key**: desc) or numbered (1. **key**: desc)
// Description can span multiple lines until next pattern or blank-line gap.
const patternRegex =
  /^(?:[-*]|\d+\.)\s+\*\*([a-z][a-z0-9-]+)\*\*\s*[:—-]\s*([\s\S]*?)(?=^(?:[-*]|\d+\.)\s+\*\*|\n\n##|\Z)/gm
const patterns = []
let m
while ((m = patternRegex.exec(sectionText)) !== null) {
  const key = m[1].trim()
  const description = m[2].trim().replace(/\n+/g, ' ').slice(0, 2000)
  if (key.startsWith('<BRAND_SLUG>-') || key.startsWith('ordex-')) {
    patterns.push({ key, description })
  }
}

if (patterns.length === 0) {
  if (asJson) {
    console.log(JSON.stringify({ slug, patterns: [], status: 'section-empty-or-no-<BRAND_SLUG>-prefix' }))
  } else {
    console.log('[i] Section found but no `<BRAND_SLUG>-*` or `ordex-*` patterns matched.')
    console.log('    Pattern format: `- **<key>**: <description>` or `1. **<key>**: <description>`')
  }
  process.exit(0)
}

if (asJson) {
  console.log(
    JSON.stringify({ slug, patterns, count: patterns.length, auto_save: autoSave }, null, 2),
  )
  if (!autoSave) process.exit(0)
}

if (!asJson) {
  console.log(`Sprint ${slug} — retro patterns to save: ${patterns.length}`)
  console.log('')
  for (let i = 0; i < patterns.length; i++) {
    const p = patterns[i]
    const ns = p.key.startsWith('<BRAND_SLUG>-procedure-')
      ? 'procedures'
      : p.key.startsWith('<BRAND_SLUG>-causal-')
        ? 'causal'
        : p.key.startsWith('<BRAND_SLUG>-pattern-')
          ? 'patterns'
          : p.key.startsWith('ordex-')
            ? 'project'
            : 'patterns'
    console.log(`  ${i + 1}. ${p.key}  (namespace: ${ns})`)
    console.log(`     ${p.description.slice(0, 100)}${p.description.length > 100 ? '...' : ''}`)
  }
  console.log('')
}

if (!autoSave) {
  if (!asJson) {
    console.log('To save: rerun with --auto-save')
    console.log('Or save individually:')
    for (const p of patterns) {
      console.log(
        `  ruflo memory store -k "${p.key}" -n <namespace> --vector --upsert --value "..."`,
      )
    }
  }
  process.exit(0)
}

// Auto-save mode
let saved = 0
let failed = 0
const failures = []

for (const p of patterns) {
  // Infer namespace from key prefix
  let ns = 'patterns'
  if (p.key.startsWith('<BRAND_SLUG>-procedure-')) ns = 'procedures'
  else if (p.key.startsWith('<BRAND_SLUG>-causal-')) ns = 'causal'
  else if (p.key.startsWith('<BRAND_SLUG>-semantic-')) ns = 'semantic'
  else if (p.key.startsWith('<BRAND_SLUG>-episode-')) ns = 'episodes'
  else if (p.key.startsWith('ordex-')) ns = 'project'

  const r = spawnSync(
    'ruflo',
    [
      'memory',
      'store',
      '-k',
      p.key,
      '-n',
      ns,
      '--vector',
      '--upsert',
      '--value',
      p.description,
      '--tags',
      `sprint-${slug},auto-save`,
    ],
    { encoding: 'utf8', env: { ...process.env } },
  )

  if (r.status === 0 && /OK|stored/i.test(r.stdout)) {
    saved++
    console.log(`  ✓ saved: ${p.key} (${ns})`)
  } else {
    failed++
    failures.push({ key: p.key, error: (r.stderr || r.stdout || 'unknown').trim().slice(0, 200) })
    console.log(
      `  ✗ FAILED: ${p.key} — ${(r.stderr || r.stdout || 'unknown').trim().slice(0, 100)}`,
    )
  }
}

console.log('')
console.log(`Summary: saved ${saved}/${patterns.length}, failed ${failed}`)

if (failed > 0) {
  console.log('')
  console.log('Failures:')
  for (const f of failures) {
    console.log(`  - ${f.key}: ${f.error}`)
  }
  process.exit(1)
}

process.exit(0)
