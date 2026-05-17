#!/usr/bin/env node
/**
 * sprint-research-cache.mjs — Manage docs/research/<topic>.md cache.
 *
 * AC-10/29 (sprint-system-100). Caches WebSearch / WebFetch results by topic
 * so future sprints recall from disk instead of re-searching.
 *
 * Commands:
 *
 *   sprint-research-cache.mjs list
 *     List all cached topics.
 *
 *   sprint-research-cache.mjs save <topic-slug> <query> <sources-json> [<summary>]
 *     Save a research artifact. <sources-json> is a JSON array of
 *     {url, title, snippet?} objects.
 *
 *   sprint-research-cache.mjs get <topic-slug>
 *     Print cached artifact (used by wizard context bundler).
 *
 *   sprint-research-cache.mjs slugify "<query>"
 *     Return canonical topic-slug for a query (used by wizard to check cache).
 *
 * File format: docs/research/<topic-slug>.md
 *
 *   ---
 *   topic_slug: <slug>
 *   query: <original query>
 *   retrieved_at: <ISO>
 *   sources:
 *     - url: ...
 *       title: ...
 *   ---
 *
 *   ## Summary
 *   <one-paragraph synthesis>
 *
 *   ## Sources
 *   <bullet list>
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')
const RESEARCH_DIR = join(REPO_ROOT, 'docs', 'research')

mkdirSync(RESEARCH_DIR, { recursive: true })

const [, , cmd, ...args] = process.argv

function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80)
}

function cachePath(slug) {
  return join(RESEARCH_DIR, `${slug}.md`)
}

if (!cmd || cmd === '--help' || cmd === '-h') {
  console.log('Usage: sprint-research-cache.mjs <list|save|get|slugify> [args]')
  process.exit(0)
}

if (cmd === 'slugify') {
  process.stdout.write(slugify(args.join(' ')))
  process.exit(0)
}

if (cmd === 'list') {
  if (!existsSync(RESEARCH_DIR)) {
    console.log('[]')
    process.exit(0)
  }
  const files = readdirSync(RESEARCH_DIR).filter((f) => f.endsWith('.md'))
  const summaries = files.map((f) => {
    const content = readFileSync(join(RESEARCH_DIR, f), 'utf8')
    const m = content.match(/^---\n([\s\S]+?)\n---/)
    if (!m) return { file: f }
    const fm = m[1]
    const get = (k) => (fm.match(new RegExp(`^${k}: (.+)$`, 'm')) || [])[1] || null
    return {
      file: f,
      topic_slug: get('topic_slug') || f.replace('.md', ''),
      query: get('query'),
      retrieved_at: get('retrieved_at'),
    }
  })
  console.log(JSON.stringify(summaries, null, 2))
  process.exit(0)
}

if (cmd === 'get') {
  const slug = args[0]
  if (!slug) {
    console.error('[!] get requires <topic-slug>')
    process.exit(1)
  }
  const p = cachePath(slug)
  if (!existsSync(p)) {
    console.error(`[!] not found: ${p}`)
    process.exit(1)
  }
  process.stdout.write(readFileSync(p, 'utf8'))
  process.exit(0)
}

if (cmd === 'save') {
  const [slugRaw, query, sourcesJson, ...summaryParts] = args
  if (!slugRaw || !query || !sourcesJson) {
    console.error('[!] save requires <topic-slug> <query> <sources-json> [<summary>]')
    process.exit(1)
  }
  const slug = slugify(slugRaw)
  let sources
  try {
    sources = JSON.parse(sourcesJson)
  } catch (e) {
    console.error(`[!] sources-json parse error: ${e.message}`)
    process.exit(1)
  }
  if (!Array.isArray(sources)) {
    console.error('[!] sources must be a JSON array')
    process.exit(1)
  }
  const summary = summaryParts.join(' ').trim() || '(no summary provided)'
  const now = new Date().toISOString()

  const lines = []
  lines.push('---')
  lines.push(`topic_slug: ${slug}`)
  lines.push(`query: ${JSON.stringify(query)}`)
  lines.push(`retrieved_at: ${now}`)
  lines.push('sources:')
  for (const s of sources) {
    lines.push(`  - url: ${JSON.stringify(s.url || '')}`)
    lines.push(`    title: ${JSON.stringify(s.title || '')}`)
    if (s.snippet) lines.push(`    snippet: ${JSON.stringify(s.snippet.slice(0, 240))}`)
  }
  lines.push('---')
  lines.push('')
  lines.push('## Summary')
  lines.push('')
  lines.push(summary)
  lines.push('')
  lines.push('## Sources')
  lines.push('')
  for (const s of sources) {
    const url = s.url || ''
    const title = s.title || url
    lines.push(`- [${title}](${url})`)
  }
  lines.push('')

  const p = cachePath(slug)
  writeFileSync(p, lines.join('\n'))
  console.log(`[+] Cached: ${p}`)
  console.log(`    Sources: ${sources.length}`)
  process.exit(0)
}

console.error(`[!] Unknown command: ${cmd}`)
process.exit(1)
