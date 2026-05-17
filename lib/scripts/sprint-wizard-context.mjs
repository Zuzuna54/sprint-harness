#!/usr/bin/env node
/**
 * sprint-wizard-context.mjs — Generate context bundle for the next wizard question.
 *
 * Called by Claude during the spec wizard to gather:
 *   - relevant <BRAND_SLUG_TITLE> patterns from .swarm/memory.db (semantic search)
 *   - relevant existing files (grep heuristics)
 *   - prior section answers
 *
 * Output: JSON to stdout that Claude consumes to formulate the next question.
 *
 * Usage:
 *   sprint-wizard-context.mjs <slug> <section> [search-query]
 *
 * If search-query is omitted, it's auto-generated from the emerging spec
 * (concatenation of prior section answers + current section name).
 *
 * Note: the actual memory_search and Grep calls are issued by Claude via MCP/Bash
 * during the wizard run. This script just emits the *prompts* Claude should issue
 * and the accumulated state Claude needs to formulate the search query.
 */

import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const [, , slug, section, ...queryParts] = process.argv

if (!slug || !section) {
  console.error('Usage: sprint-wizard-context.mjs <slug> <section> [search-query]')
  process.exit(1)
}

const partialPath = join(REPO_ROOT, 'docs', 'sprints', slug, 'spec.partial.json')
if (!existsSync(partialPath)) {
  console.error(`[!] spec.partial.json not found: ${partialPath}`)
  process.exit(1)
}

const partial = JSON.parse(readFileSync(partialPath, 'utf8'))

// ── Auto-generate search query if not provided ───────────────────────────────
const sectionNames = {
  A: 'problem vision user value',
  B: 'entities business logic domain rules invariants',
  C: 'database schema tables RLS migration',
  D: 'API endpoints Zod auth errors',
  E: 'UI components pages server client state',
  F: 'UX flow happy path error empty loading',
  G: 'design system typography color iconography',
  H: 'integration modules external APIs events cron',
  I: 'acceptance criteria Gherkin INVEST performance',
  J: 'security risks privacy rollback open questions',
}

let searchQuery = queryParts.join(' ').trim()
if (!searchQuery) {
  const priorAnswers = Object.entries(partial.sections_answers || {})
    .map(([s, ans]) =>
      Object.values(ans)
        .filter((v) => typeof v === 'string')
        .join(' '),
    )
    .join(' ')
  searchQuery = `<BRAND_SLUG_TITLE> ${sectionNames[section] || section} ${priorAnswers}`.slice(0, 500).trim()
}

// ── Suggest grep heuristics per section ──────────────────────────────────────
const grepSuggestions = {
  A: [
    {
      pattern: '(MealPrepSession|TimeBlock|WorkoutSet|HealthLog|SupplementLog)',
      path: 'packages/db/src/schema',
      reason: 'existing entities to ground problem statement',
    },
  ],
  B: [
    {
      pattern: 'export (const|function|class|type)',
      path: 'packages/utils',
      reason: 'existing domain logic helpers',
    },
  ],
  C: [
    {
      pattern: 'pgTable',
      path: 'packages/db/src/schema',
      reason: 'existing schema patterns',
    },
    {
      pattern: 'CREATE POLICY',
      path: 'packages/db/src/migrations',
      reason: 'existing RLS policy patterns',
    },
  ],
  D: [
    {
      pattern: 'export const manifest',
      path: 'apps/lambdas',
      reason: 'existing route manifests',
    },
    {
      pattern: 'z\\.object\\(',
      path: 'apps/lambdas',
      reason: 'existing Zod schemas',
    },
  ],
  E: [
    {
      pattern: '(use client|export default function)',
      path: 'apps/web/components',
      reason: 'existing components and client/server split',
    },
  ],
  F: [
    {
      pattern: '(toast|Sonner|useMutation)',
      path: 'apps/web',
      reason: 'existing toast/error/optimistic patterns',
    },
  ],
  G: [
    {
      pattern: '(Lucide|from "lucide-react")',
      path: 'apps/web',
      reason: 'existing Lucide icon usage',
    },
  ],
  H: [
    {
      pattern: '(Gemini|GoogleGenerativeAI|generativelanguage)',
      path: 'apps/lambdas/ai-scheduler-lambda',
      reason: 'existing Gemini integration',
    },
  ],
  I: [
    {
      pattern: '(describe|it\\(|GIVEN|WHEN|THEN)',
      path: 'apps',
      reason: 'existing test patterns',
    },
  ],
  J: [
    {
      pattern: '(requireUser|auth\\.uid|RLS)',
      path: 'apps/lambdas',
      reason: 'existing auth/RLS surfaces',
    },
  ],
}

// ── Memory recall targets per section ────────────────────────────────────────
const memoryTargets = {
  A: ['<BRAND_SLUG>-build-context', '<BRAND_SLUG>-mvp-build-complete', '<BRAND_SLUG>-known-gaps'],
  B: ['<BRAND_SLUG>-soft-delete-pattern', '<BRAND_SLUG>-rls-4-policy-template'],
  C: [
    '<BRAND_SLUG>-rls-4-policy-template',
    '<BRAND_SLUG>-soft-delete-pattern',
    '<BRAND_SLUG>-supabase-url-distinction',
    '<BRAND_SLUG>-encryption-at-rest-setup',
  ],
  D: [
    '<BRAND_SLUG>-lambda-handler-5-step',
    '<BRAND_SLUG>-causal-rls-skip-leak',
    'ai-integration',
    'database-pattern',
  ],
  E: ['frontend-hook-pattern', 'onboarding-pattern'],
  F: ['frontend-hook-pattern'],
  G: ['<BRAND_NAME> Planner design-parity'],
  H: ['ai-integration', '<BRAND_SLUG>-supabase-url-distinction'],
  I: ['<BRAND_SLUG>-module-done-checklist', '<BRAND_SLUG>-tdd-workflow'],
  J: ['<BRAND_SLUG>-causal-rls-skip-leak', '<BRAND_SLUG>-causal-s3-bucket-acl-deprecated', 'security-pattern'],
}

// ── P5c: Actually run greps via sprint-wizard-grep-runner.mjs (gap #14) ─────
import { spawnSync as _spawn } from 'node:child_process'
function runGrepHeuristics() {
  if (!grepSuggestions[section] || grepSuggestions[section].length === 0) return []
  const r = _spawn(
    'node',
    [join(__dirname, 'sprint-wizard-grep-runner.mjs'), slug, section, '--limit', '5'],
    { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 },
  )
  if (r.status !== 0) return []
  try {
    const parsed = JSON.parse(r.stdout)
    return parsed.greps_run || []
  } catch {
    return []
  }
}

// ── P5c: Load graphify-out summary (gap #15) ────────────────────────────────
function loadGraphifySummary() {
  const reportPath = join(REPO_ROOT, 'graphify-out', 'GRAPH_REPORT.md')
  if (!existsSync(reportPath)) return null
  const report = readFileSync(reportPath, 'utf8')

  // Extract god-nodes section + top communities (first 30 lines of each)
  const godNodesSec = report.match(/##[^\n]*God[^\n]*\n[\s\S]*?(?=\n##|$)/i)
  const communitiesSec = report.match(/##[^\n]*Communit[^\n]*\n[\s\S]*?(?=\n##|$)/i)
  const corpusSec = report.match(/##[^\n]*[Cc]orpus[^\n]*\n[\s\S]*?(?=\n##|$)/)

  return {
    available: true,
    report_path: 'graphify-out/GRAPH_REPORT.md',
    corpus: corpusSec ? corpusSec[0].slice(0, 600) : null,
    god_nodes: godNodesSec ? godNodesSec[0].slice(0, 800) : null,
    communities: communitiesSec ? communitiesSec[0].slice(0, 800) : null,
    full_report_chars: report.length,
  }
}

// ── P5c: Serena MCP suggestion for §E (gap #16) ─────────────────────────────
function serenaSuggestion() {
  if (section !== 'E') return null
  const A = partial.sections_answers?.A || {}
  const componentHints = []
  for (const [k, v] of Object.entries(A)) {
    if (typeof v !== 'string') continue
    // Extract probable component names (CamelCase tokens)
    const camels = v.match(/\b[A-Z][a-zA-Z]{4,}\b/g)
    if (camels) componentHints.push(...camels)
  }
  return {
    note: 'For §E reuse audit, invoke Serena `find_symbol` on these candidates extracted from §A:',
    candidates: [...new Set(componentHints)].slice(0, 10),
    invoke: 'mcp__serena__find_symbol with name_path = each candidate above',
  }
}

// AC-21 (sprint-system-100): wizard-time reuse warning. Surface existing
// routes/components/integrations that might duplicate what the user is about
// to propose. Per §D/§E/§H, list candidates from the codebase so the wizard
// can ask "extend existing X or build fresh Y?" instead of letting the user
// re-invent.
function potentialDuplicates() {
  const dupes = []
  if (section === 'D') {
    // List existing lambda routes (one per manifest entry)
    const lambdas = [
      'auth',
      'workouts',
      'nutrition',
      'supplements',
      'planner',
      'grocery',
      'health',
      'finances',
      'ai-scheduler',
    ]
    for (const l of lambdas) {
      const manifest = `apps/lambdas/${l}-lambda/src/manifest.ts`
      if (existsSync(join(REPO_ROOT, manifest))) {
        try {
          const text = readFileSync(join(REPO_ROOT, manifest), 'utf8')
          const routes = [...text.matchAll(/path:\s*['"]([^'"]+)['"]/g)]
            .map((m) => m[1])
            .slice(0, 12)
          if (routes.length) dupes.push({ lambda: l, manifest, existing_routes: routes })
        } catch {}
      }
    }
  } else if (section === 'E') {
    // List existing reusable web components
    try {
      const r = _spawn('find', ['apps/web/components', '-name', '*.tsx', '-type', 'f'], {
        encoding: 'utf8',
        cwd: REPO_ROOT,
      })
      const components = (r.stdout || '')
        .split('\n')
        .filter(Boolean)
        .map((p) => p.replace(/^apps\/web\/components\//, '').replace(/\.tsx$/, ''))
        .filter((p) => !p.includes('__tests__'))
        .slice(0, 30)
      if (components.length) dupes.push({ scope: 'apps/web/components', available: components })
    } catch {}
  } else if (section === 'H') {
    // List existing external integrations
    try {
      const r = _spawn('find', ['apps/lambdas', '-path', '*/integrations/*', '-name', '*.ts'], {
        encoding: 'utf8',
        cwd: REPO_ROOT,
      })
      const integrations = (r.stdout || '')
        .split('\n')
        .filter(Boolean)
        .map((p) => p.replace(/^apps\/lambdas\//, ''))
        .slice(0, 20)
      if (integrations.length)
        dupes.push({ scope: 'apps/lambdas/*/integrations', available: integrations })
    } catch {}
  }
  return dupes.length ? dupes : null
}

// AC-10/29 (sprint-system-100): research bundle — list cached research that
// matches this section's keywords, plus suggested WebSearch queries Claude
// should run + cache via sprint-research-cache.mjs.
function researchBundle() {
  // Only §A, §D, §I, §J are research-relevant per spec
  if (!['A', 'D', 'I', 'J'].includes(section)) {
    return { available: true, applies_to_section: false, cached: [], suggested_queries: [] }
  }

  // List existing cache
  let cached = []
  try {
    const r = _spawn('node', [join(__dirname, 'sprint-research-cache.mjs'), 'list'], {
      encoding: 'utf8',
    })
    if (r.status === 0) cached = JSON.parse(r.stdout)
  } catch {}

  // Suggested WebSearch queries per section
  const aAnswers = partial.sections_answers?.A || {}
  const problem = Object.values(aAnswers)
    .filter((v) => typeof v === 'string')
    .join(' ')
    .slice(0, 200)
  const suggested = []
  if (section === 'A') {
    suggested.push(`${problem} best practices 2026`)
    suggested.push(`${problem} common pitfalls implementation`)
  } else if (section === 'D') {
    suggested.push(`REST API design patterns 2026 ${problem.slice(0, 80)}`)
    suggested.push(`Zod schema validation patterns Node.js 2026`)
  } else if (section === 'I') {
    suggested.push(`Gherkin acceptance criteria E2E testing patterns 2026`)
    suggested.push(`Lambda integration test patterns 2026`)
  } else if (section === 'J') {
    suggested.push(`${problem.slice(0, 80)} security risks OWASP 2026`)
    suggested.push(`feature flag rollback strategy 2026`)
  }

  return {
    available: true,
    applies_to_section: true,
    cached: cached.slice(0, 10),
    suggested_queries: suggested,
    instructions: [
      `1. Check 'cached' above — if a matching topic exists, read it via:`,
      `     node scripts/sprint-research-cache.mjs get <topic_slug>`,
      `2. If no cache hit, run WebSearch on suggested_queries[0]`,
      `3. After WebSearch, cache results via:`,
      `     node scripts/sprint-research-cache.mjs save <topic-slug> "<query>" '<sources-json>' "<summary>"`,
      `4. Future sprints recall the same topic from docs/research/`,
    ],
  }
}

const grep_results = runGrepHeuristics()
const graph_summary = loadGraphifySummary()
const serena_hint = serenaSuggestion()
const potential_duplicates = potentialDuplicates()
const research_bundle = researchBundle()

// ── Emit bundle ──────────────────────────────────────────────────────────────
const bundle = {
  slug,
  section,
  prior_answers: partial.sections_answers || {},
  flags: partial.sections_answers?.A?.flags || {},
  search_query: searchQuery,
  memory_search_command: `ruflo memory search --query "${searchQuery.replace(/"/g, '\\"')}" --limit 5`,
  memory_recall_targets: memoryTargets[section] || [],
  grep_suggestions: grepSuggestions[section] || [],
  // P5c additions:
  grep_results, // actually-run grep with top matches (gap #14)
  graph_summary, // graphify summary (gap #15)
  serena_hint, // Serena symbol search candidates for §E (gap #16)
  // AC-21 (sprint-system-100): pre-computed duplicate candidates per section
  potential_duplicates,
  // AC-10/29 (sprint-system-100): research cache + suggested WebSearch queries
  research_bundle,
  next_steps_for_claude: [
    `1. Run the memory_search command above; surface top 3 hits ≥0.5 score to user`,
    `2. Review pre-computed grep_results above (top matches per heuristic) — use as defaults`,
    `3. If section is §E and serena_hint is non-null, invoke serena find_symbol per candidate`,
    `4. Reference graph_summary.god_nodes for architecture-level reuse opportunities`,
    `5. AC-21: if potential_duplicates is non-null, present them to user as REUSE WARNING before asking new-surface questions`,
    `6. Ask user: "want me to apply these as defaults during §${section}?"`,
    `7. Begin §${section} questions per .claude/skills/sprint-spec-wizard/sections/`,
  ],
}

console.log(JSON.stringify(bundle, null, 2))
