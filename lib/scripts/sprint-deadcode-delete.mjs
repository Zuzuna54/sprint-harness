#!/usr/bin/env node
/**
 * sprint-deadcode-delete.mjs — Cleanup-phase dead-code remover.
 *
 * AC-18 (sprint-system-100, complex:true). Runs day 11-12 of a sprint:
 *   1. knip --reporter json → list of "unused" files
 *   2. For each: check imports + dynamic loaders to reduce false positives
 *   3. If still confirmed dead → git rm + commit
 *   4. Run tests; on failure → git revert
 *   5. Append result to docs/sprints/<slug>/deadcode-deletions.json
 *
 * Default: --dry-run (report only). Use --commit to actually delete.
 * Use --review-via-agent to spawn code-analyzer per file (NOT auto — emits
 * the spawn command for Claude to run in MCP session).
 *
 * Safety: refuses to delete if file is in state.files_touched[] for the
 * CURRENT sprint (that means the sprint added it; shouldn't be dead).
 *
 * Usage:
 *   sprint-deadcode-delete.mjs <slug> [--commit] [--review-via-agent] [--json]
 */

import { execSync, spawnSync } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const args = process.argv.slice(2)
const slug = args.find((a) => !a.startsWith('--'))
const commit = args.includes('--commit')
const reviewViaAgent = args.includes('--review-via-agent')
const asJson = args.includes('--json')

if (!slug) {
  console.error('Usage: sprint-deadcode-delete.mjs <slug> [--commit] [--review-via-agent] [--json]')
  process.exit(1)
}

const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
const statePath = join(sprintDir, 'state.json')
if (!existsSync(statePath)) {
  console.error(`[!] state.json missing for ${slug}`)
  process.exit(1)
}
const state = JSON.parse(readFileSync(statePath, 'utf8'))
const sprintFiles = new Set(state.files_touched || [])

// ── 1. Run knip ────────────────────────────────────────────────────────────
console.log('[1/4] Running knip...')
const knipR = spawnSync('pnpm', ['dlx', 'knip', '--reporter', 'json', '--no-progress'], {
  cwd: REPO_ROOT,
  encoding: 'utf8',
  maxBuffer: 20 * 1024 * 1024,
  timeout: 240_000,
})

if (knipR.error || knipR.status === null) {
  console.error('[!] knip failed to run:', knipR.error?.message || 'no output')
  process.exit(2)
}

let knipReport
try {
  knipReport = JSON.parse(knipR.stdout)
} catch (e) {
  console.error('[!] could not parse knip JSON:', e.message)
  console.error(knipR.stdout.slice(0, 500))
  process.exit(2)
}

// knip reports unused files under `.files` array (newer) or per-workspace
const unusedFiles = new Set()
function collectUnused(obj) {
  if (!obj || typeof obj !== 'object') return
  if (Array.isArray(obj.files)) obj.files.forEach((f) => unusedFiles.add(f))
  for (const v of Object.values(obj)) if (typeof v === 'object') collectUnused(v)
}
collectUnused(knipReport)

console.log(`     knip reported ${unusedFiles.size} unused files`)

// ── 2. Filter: skip files in current sprint scope ──────────────────────────
const candidates = [...unusedFiles].filter((f) => !sprintFiles.has(f))
console.log(
  `[2/4] Filtered to ${candidates.length} (excluded ${unusedFiles.size - candidates.length} in current sprint scope)`,
)

// ── 3. Heuristic: check for dynamic loader patterns ────────────────────────
const FALSE_POSITIVE_REGEX = /(require\(.*\)|import\(.*\)|module\.exports|export \* from)/
function hasDynamicLoader(file) {
  try {
    const content = readFileSync(join(REPO_ROOT, file), 'utf8')
    return FALSE_POSITIVE_REGEX.test(content)
  } catch {
    return false
  }
}

const safeCandidates = []
const flaggedFalsePositive = []
for (const f of candidates) {
  if (hasDynamicLoader(f)) {
    flaggedFalsePositive.push(f)
  } else {
    safeCandidates.push(f)
  }
}
console.log(`[3/4] Filtered ${candidates.length - safeCandidates.length} dynamic-loader candidates`)
console.log(`     ${safeCandidates.length} files safe to delete`)

// ── 4. Decide action ───────────────────────────────────────────────────────
const result = {
  slug,
  ran_at: new Date().toISOString(),
  knip_reported: unusedFiles.size,
  excluded_in_sprint_scope: unusedFiles.size - candidates.length,
  flagged_false_positive: flaggedFalsePositive.length,
  safe_candidates: safeCandidates.length,
  files: safeCandidates,
  false_positives: flaggedFalsePositive,
  mode: commit ? 'commit' : 'dry-run',
  deleted: [],
  reverted: [],
}

if (reviewViaAgent && safeCandidates.length > 0) {
  console.log('')
  console.log('[4/4] Review-via-agent mode — emit code-analyzer spawn commands:')
  console.log('')
  for (const f of safeCandidates.slice(0, 5)) {
    console.log(
      `  Task tool: agent=code-analyzer, prompt="Read ${f} and all its callers. Confirm it is genuinely unused (no dynamic loading via require/import/glob). Report yes/no with reason."`,
    )
  }
  if (safeCandidates.length > 5) console.log(`  ... and ${safeCandidates.length - 5} more`)
  writeFileSync(join(sprintDir, 'deadcode-deletions.json'), JSON.stringify(result, null, 2))
  process.exit(0)
}

if (commit && safeCandidates.length > 0) {
  console.log('[4/4] --commit mode: deleting + git rm + commit per file...')
  for (const f of safeCandidates) {
    try {
      execSync(`git rm "${f}"`, { cwd: REPO_ROOT, stdio: 'pipe' })
      result.deleted.push(f)
    } catch (e) {
      console.error(`  ✗ git rm failed for ${f}:`, e.message.slice(0, 80))
    }
  }

  if (result.deleted.length > 0) {
    const msg = `chore(deadcode-cleanup): remove ${result.deleted.length} unused file(s) (sprint ${slug})\n\nFiles:\n${result.deleted.map((f) => '- ' + f).join('\n')}`
    try {
      // Skip drift hook for this cleanup commit — already validated by knip+heuristics
      execSync(`SPRINT_DRIFT_BYPASS=1 git commit -m "${msg.replace(/"/g, '\\"')}"`, {
        cwd: REPO_ROOT,
        stdio: 'pipe',
      })
      console.log(`  ✓ Committed ${result.deleted.length} deletions`)
    } catch (e) {
      console.error('  ✗ commit failed:', e.message.slice(0, 80))
    }

    // Run tests to verify nothing broke
    console.log('     Running pnpm test (timeout 5min)...')
    const testR = spawnSync('pnpm', ['test'], {
      cwd: REPO_ROOT,
      timeout: 5 * 60_000,
      stdio: 'pipe',
    })
    if (testR.status !== 0) {
      console.log('  ✗ tests failed — reverting last commit')
      execSync(`SPRINT_DRIFT_BYPASS=1 git revert --no-edit HEAD`, {
        cwd: REPO_ROOT,
        stdio: 'inherit',
      })
      result.reverted = result.deleted.slice()
      result.deleted = []
    } else {
      console.log('  ✓ tests passed — deletions stick')
    }
  }
} else if (safeCandidates.length > 0) {
  console.log('[4/4] DRY-RUN — would delete:')
  for (const f of safeCandidates.slice(0, 10)) console.log(`  - ${f}`)
  if (safeCandidates.length > 10) console.log(`  ... and ${safeCandidates.length - 10} more`)
  console.log('')
  console.log('Re-run with --commit to actually delete (logged + tests gate).')
  console.log('Or --review-via-agent to get per-file code-analyzer spawn commands.')
}

writeFileSync(join(sprintDir, 'deadcode-deletions.json'), JSON.stringify(result, null, 2))

if (asJson) {
  console.log(JSON.stringify(result, null, 2))
}
