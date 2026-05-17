#!/usr/bin/env node
/**
 * sprint-gh-mirror.mjs — GitHub Projects v2 MIRROR sync (state.json → GH).
 *
 * AC-32 (sprint-system-100). MIRROR mode: state.json is source of truth;
 * this script pushes one-way to GH. No reads back.
 *
 * Capabilities:
 *   - Create parent Epic issue per sprint
 *   - Create child Task issues per AC
 *   - Link child→parent via `addSubIssue` GraphQL mutation
 *     (header: GraphQL-Features: sub_issues)
 *   - On AC close: close the matching sub-issue
 *   - On sprint close: close the epic
 *
 * Requires: gh auth login with `project` scope. SPRINT_GH_BYPASS=1 skips.
 *
 * Subcommands:
 *   check             — diagnose gh auth + scopes
 *   init <slug>       — create epic + sub-issues from spec.md §I
 *   close-ac <slug> <AC-N> — close the sub-issue for AC-N
 *   close <slug>      — close the epic
 */

import { execSync, spawnSync } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

function fail(msg, code = 1) {
  console.error(`[!] ${msg}`)
  process.exit(code)
}

const bypass = () => process.env.SPRINT_GH_BYPASS === '1'

// AC-9 (harness-portability-v2): log bypasses to state.gate_bypasses[] for retro.
function logBypass(slug, gate, reason) {
  try {
    const sf = join(REPO_ROOT, 'docs', 'sprints', slug || '', 'state.json')
    if (!existsSync(sf)) return
    const s = JSON.parse(readFileSync(sf, 'utf8'))
    s.gate_bypasses = (s.gate_bypasses || []).concat([{ gate, reason, at: new Date().toISOString() }])
    writeFileSync(sf, JSON.stringify(s, null, 2))
  } catch {}
}

function ghAvailable() {
  try {
    execSync('gh auth status', { encoding: 'utf8', stdio: 'pipe' })
    return true
  } catch {
    return false
  }
}

function ghHasScope(scope) {
  try {
    const out = execSync('gh auth status', { encoding: 'utf8', stdio: 'pipe' })
    return new RegExp(`'${scope}'|\\b${scope}\\b`).test(out)
  } catch {
    return false
  }
}

function mirrorPath(slug) {
  return join(REPO_ROOT, 'docs', 'sprints', slug, 'gh-mirror.json')
}

function loadMirror(slug) {
  const p = mirrorPath(slug)
  if (!existsSync(p)) return { slug, epic: null, ac_issues: {} }
  return JSON.parse(readFileSync(p, 'utf8'))
}

function saveMirror(slug, data) {
  writeFileSync(mirrorPath(slug), JSON.stringify(data, null, 2))
}

function cmdCheck() {
  console.log('═══ gh CLI diagnostic ═══')
  if (!ghAvailable()) {
    console.log('  ✗ gh not authenticated (run: gh auth login)')
    return
  }
  console.log('  ✓ gh authenticated')
  console.log(`  ${ghHasScope('project') ? '✓' : '✗'} 'project' scope`)
  if (!ghHasScope('project')) {
    console.log('  Run:  gh auth refresh -s project')
  }
}

function ghCreateIssue(title, body, labels = []) {
  const args = ['issue', 'create', '--title', title, '--body', body]
  for (const l of labels) args.push('--label', l)
  const r = spawnSync('gh', args, { encoding: 'utf8' })
  if (r.status !== 0) {
    console.error('  gh issue create failed:', r.stderr.slice(0, 200))
    return null
  }
  const url = r.stdout.trim()
  const num = (url.match(/\/issues\/(\d+)/) || [])[1]
  return num ? { number: Number(num), url } : null
}

function ghLinkSubIssue(parentNumber, childNumber) {
  const getId = (num) => {
    const r = spawnSync('gh', ['issue', 'view', String(num), '--json', 'id', '--jq', '.id'], {
      encoding: 'utf8',
    })
    return r.status === 0 ? r.stdout.trim() : null
  }
  const parentId = getId(parentNumber)
  const childId = getId(childNumber)
  if (!parentId || !childId) return false

  const mutation =
    'mutation($parent:ID!,$child:ID!){addSubIssue(input:{issueId:$parent,subIssueId:$child}){issue{number}}}'
  const r = spawnSync(
    'gh',
    [
      'api',
      'graphql',
      '-H',
      'GraphQL-Features: sub_issues',
      '-f',
      `query=${mutation}`,
      '-F',
      `parent=${parentId}`,
      '-F',
      `child=${childId}`,
    ],
    { encoding: 'utf8' },
  )
  return r.status === 0
}

function cmdInit(slug) {
  if (bypass()) {
    console.log('[i] SPRINT_GH_BYPASS=1 — skipping (logging to state.gate_bypasses[])')
    logBypass(slug, 'gh-mirror', 'SPRINT_GH_BYPASS=1')
    return
  }
  if (!ghAvailable()) fail('gh not authenticated')
  if (!ghHasScope('project')) fail('missing project scope (gh auth refresh -s project)')

  const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
  const specPath = join(sprintDir, 'spec.md')
  if (!existsSync(specPath)) fail(`spec.md not found: ${specPath}`)

  const spec = readFileSync(specPath, 'utf8')
  const acRe = /\*\*(AC-\d+)\*\*[^\n]*\n([^\n]+)/g
  const acs = []
  let m
  while ((m = acRe.exec(spec)) !== null) {
    acs.push({ id: m[1], summary: m[2].slice(0, 120).trim() })
  }
  if (acs.length === 0) fail('no ACs found in spec.md')

  const mirror = loadMirror(slug)

  if (!mirror.epic) {
    const title = `[Sprint ${slug}] Epic — ${acs.length} ACs`
    const body = `Auto-created by sprint-gh-mirror.mjs.\n\nSee \`docs/sprints/${slug}/spec.md\`.\n`
    const epic = ghCreateIssue(title, body, ['sprint', 'epic'])
    if (!epic) fail('failed to create epic')
    mirror.epic = epic
    console.log(`[+] Epic: #${epic.number} ${epic.url}`)
  } else {
    console.log(`[i] Epic exists: #${mirror.epic.number}`)
  }

  for (const ac of acs) {
    if (mirror.ac_issues[ac.id]) continue
    const title = `[${slug}] ${ac.id}: ${ac.summary}`
    const body = `Sub-issue of #${mirror.epic.number}.\nSee \`docs/sprints/${slug}/spec.md\`.\n`
    const issue = ghCreateIssue(title, body, ['sprint', 'task'])
    if (!issue) continue
    console.log(`[+] ${ac.id}: #${issue.number}`)
    mirror.ac_issues[ac.id] = issue
    if (ghLinkSubIssue(mirror.epic.number, issue.number)) {
      console.log(`    linked → epic #${mirror.epic.number}`)
    }
  }

  saveMirror(slug, mirror)
}

function cmdCloseAc(slug, acId) {
  if (bypass()) return
  if (!ghAvailable()) return
  const mirror = loadMirror(slug)
  const issue = mirror.ac_issues[acId]
  if (!issue) {
    console.log(`[i] no GH issue for ${acId}`)
    return
  }
  const r = spawnSync('gh', ['issue', 'close', String(issue.number), '--reason', 'completed'], {
    encoding: 'utf8',
  })
  if (r.status === 0) console.log(`[+] Closed #${issue.number} (${acId})`)
}

function cmdClose(slug) {
  if (bypass()) return
  if (!ghAvailable()) return
  const mirror = loadMirror(slug)
  if (!mirror.epic) return
  const r = spawnSync(
    'gh',
    ['issue', 'close', String(mirror.epic.number), '--reason', 'completed'],
    {
      encoding: 'utf8',
    },
  )
  if (r.status === 0) console.log(`[+] Closed epic #${mirror.epic.number}`)
}

const [, , cmd, ...args] = process.argv
switch (cmd) {
  case 'check':
    cmdCheck()
    break
  case 'init':
    cmdInit(args[0] || fail('slug required'))
    break
  case 'close-ac':
    cmdCloseAc(args[0] || fail('slug required'), args[1] || fail('AC-N required'))
    break
  case 'close':
    cmdClose(args[0] || fail('slug required'))
    break
  default:
    console.log('Usage: sprint-gh-mirror.mjs <check|init|close-ac|close> [args]')
    process.exit(0)
}
