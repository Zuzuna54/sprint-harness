#!/usr/bin/env node
/**
 * sprint-wizard-assemble.mjs — Render the final spec.md from spec.partial.json.
 *
 * After all 10 wizard sections are processed, this script reads the partial
 * state and assembles a complete docs/sprints/<slug>/spec.md from the template
 * at docs/sprints/_template/spec.md.
 *
 * Usage:
 *   sprint-wizard-assemble.mjs <slug>
 *     → write spec.md and report
 *
 *   sprint-wizard-assemble.mjs <slug> --partial
 *     → render partial state (for "show me the spec so far" command)
 *
 *   sprint-wizard-assemble.mjs <slug> --dry-run
 *     → print to stdout without writing
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const [, , slug, ...flagArgs] = process.argv
if (!slug) {
  console.error('Usage: sprint-wizard-assemble.mjs <slug> [--partial] [--dry-run]')
  process.exit(1)
}
const isPartial = flagArgs.includes('--partial')
const isDryRun = flagArgs.includes('--dry-run')
const skipBackfill = flagArgs.includes('--skip-backfill') // escape hatch for re-runs

const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
const partialPath = join(sprintDir, 'spec.partial.json')
const statePath = join(sprintDir, 'state.json')
const specPath = join(sprintDir, 'spec.md')
const templatePath = join(REPO_ROOT, 'docs', 'sprints', '_template', 'spec.md')

if (!existsSync(partialPath)) {
  console.error(`[!] spec.partial.json not found: ${partialPath}`)
  process.exit(1)
}

// Execution-violation fix: recall-backfill MUST run before assemble regardless
// of entry point. Previously only sprint-spec-wizard.mjs's cmdAssemble wrapper
// triggered it — invoking this helper directly bypassed it, leaving
// recalled-patterns.json empty (caught in nutrition-design-parity 2026-05-17).
if (!isPartial && !isDryRun && !skipBackfill) {
  spawnSync('node', [join(__dirname, 'sprint-spec-wizard.mjs'), 'recall-backfill', slug], {
    stdio: 'inherit',
  })
}
if (!existsSync(templatePath)) {
  console.error(`[!] Template not found: ${templatePath}`)
  process.exit(1)
}

const partial = JSON.parse(readFileSync(partialPath, 'utf8'))
const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : {}

// ── Check completeness ───────────────────────────────────────────────────────
if (!isPartial) {
  const incomplete = []
  for (const s of ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J']) {
    const st = partial.sections_status?.[s]
    if (st !== 'complete' && st !== 'skipped') {
      incomplete.push(s)
    }
  }
  if (incomplete.length > 0) {
    console.error(`[!] Wizard not complete. Pending sections: ${incomplete.join(', ')}`)
    console.error(
      `    To render partial state anyway: sprint-wizard-assemble.mjs ${slug} --partial`,
    )
    process.exit(1)
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function safe(value, fallback = '_(not provided)_') {
  if (value === null || value === undefined || value === '') return fallback
  if (typeof value === 'string') return value
  if (Array.isArray(value)) {
    if (value.length === 0) return fallback
    return value
      .map((v) => (typeof v === 'string' ? `- ${v}` : `- ${JSON.stringify(v)}`))
      .join('\n')
  }
  if (typeof value === 'object') return '```json\n' + JSON.stringify(value, null, 2) + '\n```'
  return String(value)
}

function asListItems(arr, fallback = '_(none)_') {
  if (!arr || (Array.isArray(arr) && arr.length === 0)) return fallback
  if (typeof arr === 'string') return `- ${arr}`
  if (!Array.isArray(arr)) return `- ${JSON.stringify(arr)}`
  return arr.map((v) => `- ${typeof v === 'string' ? v : JSON.stringify(v)}`).join('\n')
}

function sectionWasSkipped(s) {
  return partial.sections_status?.[s] === 'skipped'
}

function skipNote(s) {
  return `> ⊘ §${s} was SKIPPED — reason: ${partial.skip_reasons?.[s] || '(no reason recorded)'}`
}

// ── Assemble ─────────────────────────────────────────────────────────────────
const A = partial.sections_answers?.A || {}
const B = partial.sections_answers?.B || {}
const C = partial.sections_answers?.C || {}
const D = partial.sections_answers?.D || {}
const E = partial.sections_answers?.E || {}
const F = partial.sections_answers?.F || {}
const G = partial.sections_answers?.G || {}
const H = partial.sections_answers?.H || {}
const I = partial.sections_answers?.I || {}
const J = partial.sections_answers?.J || {}

const title = A.A1 ? A.A1.split(/[.\n]/)[0].slice(0, 80) : slug
const startedAt = state.started_at || partial.started_at || new Date().toISOString()
const phase = state.phase || 'spec-wizard'
const day = state.day || 0
const gates = (state.gates_passed || []).join(', ') || '(none)'
const drift = state.drift_score_latest != null ? state.drift_score_latest : 'N/A'
const completedSections = Object.entries(partial.sections_status || {})
  .filter(([_, s]) => s === 'complete')
  .map(([k]) => k)
  .join(',')

const recalledPatterns =
  (partial.recalled_patterns || [])
    .map(
      (p) =>
        `- ${p.accepted ? '✓' : '✗'} ${p.key} (§${p.section}, score ${p.score ?? 'n/a'}) ${p.applied_to ? `— applied to ${p.applied_to}` : ''}`,
    )
    .join('\n') || '_(none surfaced)_'

const spec = `# Sprint ${slug}: ${title}

> Assembled from wizard sections by \`sprint-wizard-assemble.mjs\` on ${new Date().toISOString()}.

## Status

- **Phase:** ${phase}
- **Day:** ${day} of 14
- **Started:** ${startedAt}
- **Gates passed:** ${gates}
- **Drift score (latest):** ${drift}
- **Wizard sections captured:** ${completedSections}

---

## §A — Problem & Vision

### Problem statement
${safe(A.A1)}

### Who suffers
${asListItems(A.A2)}

### Why now
${safe(A.A3)}

### Strategic fit
${safe(A.A4)}

### Success vision
${safe(A.A5)}

### Refinement
${safe(A.refinement, '')}

---

## §B — Business Logic & Domain Rules

${
  sectionWasSkipped('B')
    ? skipNote('B')
    : `
### Entities
${asListItems(B.B1)}

### State transitions
${safe(B.B2, '_(no state machines)_')}

### Invariants
${asListItems(B.B3)}

### Calculations / aggregations
${asListItems(B.B4)}

### Edge cases
${asListItems(B.B5)}

### Refinement
${safe(B.refinement, '')}`
}

---

## §C — Data & Schema

${
  sectionWasSkipped('C')
    ? skipNote('C')
    : `
### New tables/columns
${safe(C.C1, '_(no new schema)_')}

### Relationships
${asListItems(C.C2)}

### RLS policies
${safe(C.C3, '_(<BRAND_SLUG_TITLE> standard 4-policy template applied)_')}

### Migration strategy
${safe(C.C4)}

### PII / encryption
${safe(C.C5, '_(no PII touched)_')}

### Refinement
${safe(C.refinement, '')}`
}

---

## §D — API Surface

${
  sectionWasSkipped('D')
    ? skipNote('D')
    : `
### Endpoints
${safe(D.D1)}

### Request/response Zod schemas
${safe(D.D2)}

### Auth requirements
${safe(D.D3, '_(<BRAND_SLUG_TITLE> default: requireUser() on every route)_')}

### Error cases
${asListItems(D.D4)}

### External APIs
${safe(D.D5, '_(none)_')}

### Refinement
${safe(D.refinement, '')}`
}

---

## §E — UI Components & Pages

${
  sectionWasSkipped('E')
    ? skipNote('E')
    : `
### New pages
${safe(E.E1)}

### New components
${safe(E.E2)}

### Server vs client split
${safe(E.E3)}

### State management
${safe(E.E4)}

### Mobile responsiveness
${safe(E.E5)}

### Refinement
${safe(E.refinement, '')}`
}

---

## §F — UX Flow & Interactions

${
  sectionWasSkipped('F')
    ? skipNote('F')
    : `
### Happy path
${safe(F.F1)}

### Error paths
${asListItems(F.F2)}

### Empty states
${asListItems(F.F3)}

### Loading states
${asListItems(F.F4)}

### Transitions / animations
${asListItems(F.F5)}

### Refinement
${safe(F.refinement, '')}`
}

---

## §G — Visual Design & Brand

${
  sectionWasSkipped('G')
    ? skipNote('G')
    : `
### Design system
${safe(G.G1)}

### Typography / spacing / color
${safe(G.G2)}

### Iconography
${asListItems(G.G3)}

### Refinement
${safe(G.refinement, '')}`
}

---

## §H — Integration Points

### <BRAND_SLUG_TITLE> modules touched
${asListItems(H.H1)}

### External APIs
${asListItems(H.H2, '_(none)_')}

### Cross-module events
${asListItems(H.H3, '_(none)_')}

### Background workers / cron
${asListItems(H.H4, '_(none)_')}

### Refinement
${safe(H.refinement, '')}

---

## §I — Acceptance Criteria

### UI/E2E (Gherkin)
${safe(I.I1)}

### Backend (INVEST)
${safe(I.I2)}

### Performance bars
${safe(I.I3, '- P95 lambda response: < 800ms (<BRAND_SLUG_TITLE> default)\n- Payload: < 50KB\n- DB queries per request: ≤ 2')}

### Manual QA checklist
${asListItems(I.I4)}

### Refinement
${safe(I.refinement, '')}

---

## §J — Risks, Security, Rollback

### Security risks
${asListItems(J.J1)}

### Privacy implications
${safe(J.J2)}

### Rollback strategy
${safe(J.J3, '_(<BRAND_SLUG_TITLE> default: Vercel preview → smoke → promote; soft-delete-only)_')}

### Open questions
${asListItems(J.J4, '_(none)_')}

### Refinement
${safe(J.refinement, '')}

---

## Success criteria (overall)

- [ ] All ACs closed
- [ ] P95 < 800ms (<BRAND_SLUG_TITLE> default)
- [ ] 0 RLS leakage in cross-user test
- [ ] Typecheck + lint + tests clean
- [ ] Mobile responsive verified at 375px

---

## Files touched (claims scope)

${asListItems(state.files_touched || H.files_touched || [], '_(populated from wizard answers)_')}

---

## Module DoD (<BRAND_SLUG_TITLE> standard)

- [ ] Lambda routes + Zod schemas
- [ ] RLS policies (4 per new table)
- [ ] Tests (unit + integration + E2E if user-facing)
- [ ] /api-contract-validation passes
- [ ] /debug-rls passes
- [ ] Typecheck + lint clean
- [ ] Soft-delete enforced
- [ ] Auth on every route
- [ ] Mobile responsive (375px)
- [ ] CLAUDE.md updated if convention emerged

---

## SPARC design *(filled day 1-2, after design lock)*

### Specification
_(formalized from §A-§J)_

### Pseudocode
_(algorithms + data flow)_

### Architecture
_(component diagram, sequence diagram)_

---

## Recalled patterns

${recalledPatterns}

---

## Amendments

_(diff-tracked here as the sprint progresses)_
`

// ── Output ───────────────────────────────────────────────────────────────────
if (isDryRun) {
  console.log(spec)
} else {
  writeFileSync(specPath, spec)
  console.log(`[+] Spec assembled: ${specPath}`)
  console.log(`    Sections: ${completedSections || '(none complete yet)'}`)
  console.log(
    `    Skipped:  ${
      Object.entries(partial.skip_reasons || {})
        .map(([k]) => k)
        .join(',') || '(none)'
    }`,
  )
  if (isPartial) {
    console.log(`    Mode:     partial render (wizard still in progress)`)
  } else {
    console.log(`    Mode:     final render (wizard complete)`)
    console.log('')
    console.log('    Next: present spec to user for review → run Phase 1 review chain.')
  }
}
