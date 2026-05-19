#!/usr/bin/env node
/**
 * sprint-spec-wizard.mjs — State manager for the adaptive sprint spec wizard.
 *
 * The wizard's "intelligence" (question generation, coherence checks, recall
 * augmentation) lives in .claude/skills/sprint-spec-wizard/SKILL.md and is
 * executed by Claude during the session. This script's job is ONLY to:
 *
 *   - maintain spec.partial.json state
 *   - advance between sections deterministically (with skip rules)
 *   - record answers
 *   - persist transcript
 *   - delegate final assembly to sprint-wizard-assemble.mjs
 *
 * Commands:
 *
 *   sprint-spec-wizard.mjs status <slug>
 *     → print current section, status, completion %
 *
 *   sprint-spec-wizard.mjs section <slug> <A|B|C|D|E|F|G|H|I|J>
 *     → emit section context: section-file contents + accumulated state +
 *       skip-decision flags. Claude uses this to formulate the next question.
 *
 *   sprint-spec-wizard.mjs answer <slug> <section> <qid> <answer-as-json>
 *     → record an answer to spec.partial.json + append to transcript
 *
 *   sprint-spec-wizard.mjs skip <slug> <section> <reason>
 *     → mark section as skipped with reason
 *
 *   sprint-spec-wizard.mjs complete-section <slug> <section>
 *     → mark section complete, advance current_section to next applicable
 *
 *   sprint-spec-wizard.mjs assemble <slug>
 *     → delegate to sprint-wizard-assemble.mjs
 *
 * State files (in docs/sprints/<slug>/):
 *   - state.json            (sprint-level state, owned by sprint-start.sh)
 *   - spec.partial.json     (wizard answers, owned by THIS script)
 *   - wizard-transcript.md  (Q&A log, append-only)
 *   - recalled-patterns.json (memory recall surfaced by Claude)
 *
 * See:
 *   .claude/skills/sprint-spec-wizard/SKILL.md
 *   .claude/skills/sprint-spec-wizard/sections/<A-J>.md
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const SECTIONS = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J']

// ── Helpers ──────────────────────────────────────────────────────────────────

const sprintDir = (slug) => join(REPO_ROOT, 'docs', 'sprints', slug)
const partialPath = (slug) => join(sprintDir(slug), 'spec.partial.json')
const transcriptPath = (slug) => join(sprintDir(slug), 'wizard-transcript.md')
const statePath = (slug) => join(sprintDir(slug), 'state.json')
const sectionFilePath = (section) =>
  join(
    REPO_ROOT,
    '.claude',
    'skills',
    'sprint-spec-wizard',
    'sections',
    `${section}-${sectionNameFor(section)}.md`,
  )

function sectionNameFor(letter) {
  return {
    A: 'vision',
    B: 'business-logic',
    C: 'data-schema',
    D: 'api',
    E: 'ui',
    F: 'ux-flow',
    G: 'design',
    H: 'integration',
    I: 'acceptance',
    J: 'risks',
  }[letter]
}

function loadPartial(slug) {
  const p = partialPath(slug)
  if (!existsSync(p)) {
    fail(`spec.partial.json not found: ${p}\nRun sprint-start.sh first.`)
  }
  return JSON.parse(readFileSync(p, 'utf8'))
}

function savePartial(slug, partial) {
  writeFileSync(partialPath(slug), JSON.stringify(partial, null, 2))
}

function loadState(slug) {
  const p = statePath(slug)
  if (!existsSync(p)) return null
  return JSON.parse(readFileSync(p, 'utf8'))
}

function saveState(slug, state) {
  writeFileSync(statePath(slug), JSON.stringify(state, null, 2))
}

function appendTranscript(slug, lines) {
  appendFileSync(transcriptPath(slug), lines + '\n')
}

function fail(msg) {
  console.error(`[!] ${msg}`)
  process.exit(1)
}

function ok(msg) {
  console.log(msg)
}

// ── Skip rules ───────────────────────────────────────────────────────────────

function decideSkip(partial, section) {
  const aAnswers = partial.sections_answers?.A || {}
  const flags = aAnswers.flags || {}

  switch (section) {
    case 'A':
      return { skip: false }
    case 'B':
      return flags.pure_refactor
        ? { skip: true, reason: 'Pure refactor flagged in §A (A.flags.pure_refactor=true)' }
        : { skip: false }
    case 'C':
      if (flags.no_schema_change) return { skip: true, reason: 'A.flags.no_schema_change=true' }
      if (partial.sections_answers?.B?.pure_logic_layer)
        return { skip: true, reason: 'B.pure_logic_layer=true' }
      return { skip: false }
    case 'D':
      return flags.frontend_only
        ? { skip: true, reason: 'A.flags.frontend_only=true' }
        : { skip: false }
    case 'E':
    case 'F':
      return flags.backend_only || flags.no_ui
        ? { skip: true, reason: 'A.flags.backend_only or no_ui=true' }
        : { skip: false }
    case 'G':
      return flags.no_ui ? { skip: true, reason: 'A.flags.no_ui=true' } : { skip: false }
    case 'H':
    case 'I':
    case 'J':
      return { skip: false }
    default:
      return { skip: false }
  }
}

function nextSection(partial, currentSection) {
  // BUG 1 fix: mutates `partial` to mark intermediate sections as skipped
  // when they meet skip conditions, instead of just leaping over them.
  // Caller is responsible for saving the mutated partial.
  const idx = SECTIONS.indexOf(currentSection)
  if (idx === -1 || idx === SECTIONS.length - 1) return null
  partial.sections_status ||= {}
  partial.skip_reasons ||= {}
  for (let i = idx + 1; i < SECTIONS.length; i++) {
    const s = SECTIONS[i]
    const { skip, reason } = decideSkip(partial, s)
    if (skip) {
      // Auto-mark as skipped
      if (partial.sections_status[s] !== 'complete') {
        partial.sections_status[s] = 'skipped'
        partial.skip_reasons[s] = reason || 'skip condition met'
      }
      continue
    }
    return s
  }
  return null
}

// ── Commands ─────────────────────────────────────────────────────────────────

function cmdStatus(slug) {
  const partial = loadPartial(slug)
  const completed = Object.entries(partial.sections_status || {}).filter(
    ([_, st]) => st === 'complete' || st === 'skipped',
  ).length
  ok(`Sprint: ${slug}`)
  ok(`Current section: §${partial.current_section}`)
  ok(`Progress: ${completed}/10 sections processed`)
  ok('')
  ok('Section status:')
  for (const s of SECTIONS) {
    const st = partial.sections_status?.[s] || 'pending'
    const reason = partial.skip_reasons?.[s] ? ` (${partial.skip_reasons[s]})` : ''
    ok(`  §${s} ${sectionNameFor(s).padEnd(15)} ${st}${reason}`)
  }
}

function cmdSection(slug, section) {
  const partial = loadPartial(slug)

  // Skip decision
  const { skip, reason } = decideSkip(partial, section)
  if (skip) {
    ok(`SKIP §${section}: ${reason}`)
    ok('')
    ok('Run: sprint-spec-wizard.mjs skip ' + slug + ' ' + section + ' "' + reason + '"')
    return
  }

  // Emit section file contents
  const sectionFile = sectionFilePath(section)
  if (!existsSync(sectionFile)) {
    fail(`Section file missing: ${sectionFile}`)
  }
  const sectionContent = readFileSync(sectionFile, 'utf8')

  ok('='.repeat(72))
  ok(`§${section} — ${sectionNameFor(section)}`)
  ok('='.repeat(72))
  ok('')
  ok(sectionContent)
  ok('')
  ok('─'.repeat(72))
  ok('Accumulated state (prior sections):')
  ok('─'.repeat(72))
  ok('')
  for (const s of SECTIONS) {
    if (s === section) break
    const answers = partial.sections_answers?.[s]
    if (answers && Object.keys(answers).length > 0) {
      ok(`### §${s} answers:`)
      ok(JSON.stringify(answers, null, 2))
      ok('')
    }
  }
}

// AC-1 (Bug #18): wizard interactive-mode enforcement.
// In `interactive` mode (default), each `answer` call MUST include
// --user-confirmed or it exits 1 — prevents Claude from solo-authoring answers.
// `autopilot` mode is opt-in and proceeds with a logged warning. `--force-advance`
// is an emergency escape hatch for stuck wizards (logged in transcript).
function getWizardMode(partial) {
  return partial.wizard_mode || process.env.SPRINT_WIZARD_MODE || 'interactive'
}

function cmdAnswer(slug, section, qid, answerJson, opts = {}) {
  const partial = loadPartial(slug)
  partial.sections_answers ||= {}
  partial.sections_answers[section] ||= {}

  const mode = getWizardMode(partial)
  const userConfirmed = opts.userConfirmed === true
  const forceAdvance = opts.forceAdvance === true

  if (mode === 'interactive' && !userConfirmed && !forceAdvance) {
    process.stderr.write(
      `[!] AC-1 enforcement: wizard is in interactive mode but answer for §${section}.${qid} was submitted WITHOUT --user-confirmed.\n` +
        `    Pass --user-confirmed to confirm a user-provided answer, OR\n` +
        `    Pass --force-advance to bypass (logged in transcript as override), OR\n` +
        `    Switch sprint to autopilot via: sprint-spec-wizard.mjs set-mode ${slug} autopilot\n`,
    )
    process.exit(1)
  }

  let answer
  try {
    answer = JSON.parse(answerJson)
  } catch {
    answer = answerJson // accept raw string
  }

  partial.sections_answers[section][qid] = answer
  partial.sections_status[section] = 'in-progress'
  savePartial(slug, partial)

  // T2.2 (deterministic-phases-v1): when §J5 worker_rigor is answered, write it
  // to state.worker_rigor immediately. Don't rely on amend-spec --lock as only
  // path — if operator skips that, state.worker_rigor stays null and the
  // spec-locked manifest predicate fails. This makes the answer-time write
  // authoritative.
  if (section === 'J' && qid === 'worker_rigor') {
    const v = typeof answer === 'string' ? answer.toLowerCase() : ''
    if (v === 'lax' || v === 'strict') {
      try {
        const state = loadState(slug)
        state.worker_rigor = v
        saveState(slug, state)
        process.stderr.write(`[wizard] state.worker_rigor = ${v}\n`)
      } catch (e) {
        process.stderr.write(`[wizard] failed to write state.worker_rigor: ${e.message}\n`)
      }
    } else {
      process.stderr.write(
        `[wizard] §J5 worker_rigor must be 'lax' or 'strict' (got '${v}'). state.worker_rigor unset.\n`,
      )
    }
  }

  const ts = new Date().toISOString()
  const answerStr = typeof answer === 'string' ? answer : JSON.stringify(answer)
  let modeNote = ''
  if (forceAdvance) modeNote = ' [FORCE-ADVANCE override]'
  else if (mode === 'autopilot') modeNote = ' [autopilot]'
  appendTranscript(slug, `\n### §${section} · ${qid} · ${ts}${modeNote}\n\n${answerStr}\n`)

  if (mode === 'autopilot' && !userConfirmed) {
    process.stderr.write(
      `[!] AC-1: autopilot mode — recorded §${section}.${qid} without user confirmation (logged).\n`,
    )
  }

  ok(`Recorded §${section}.${qid}${modeNote}`)
}

function cmdSetMode(slug, mode) {
  if (mode !== 'interactive' && mode !== 'autopilot') {
    fail(`Invalid mode: ${mode} (expected interactive|autopilot)`)
  }
  const partial = loadPartial(slug)
  partial.wizard_mode = mode
  savePartial(slug, partial)
  appendTranscript(slug, `\n### Wizard mode set to: ${mode} · ${new Date().toISOString()}\n`)
  ok(`Wizard mode set to: ${mode}`)
}

function cmdSkip(slug, section, reason) {
  const partial = loadPartial(slug)
  partial.sections_status[section] = 'skipped'
  partial.skip_reasons[section] = reason
  savePartial(slug, partial)

  appendTranscript(slug, `\n### §${section} SKIPPED · ${reason}\n`)
  ok(`§${section} marked skipped: ${reason}`)

  // Advance to next
  const next = nextSection(partial, section)
  if (next) {
    partial.current_section = next
    savePartial(slug, partial)
    ok(`Advanced to §${next}`)
  } else {
    partial.current_section = 'complete'
    savePartial(slug, partial)
    ok('All sections processed. Ready to assemble.')
  }
}

function cmdCompleteSection(slug, section) {
  const partial = loadPartial(slug)

  // AC-9 (sprint-system-100, Gap M): coherence enforcement. If the most recent
  // coherence check for this section recorded passed=false, refuse to advance
  // until the user reconciles. Prior behavior just logged + moved on, leaving
  // contradictions in the spec.
  const lastCoherence = (partial.coherence_checks || [])
    .filter((c) => c.after_section === section)
    .pop()
  if (lastCoherence && lastCoherence.passed === false) {
    fail(
      `§${section} coherence check failed at ${lastCoherence.at}: ${lastCoherence.notes || '(no notes)'}\n` +
        `    Reconcile contradictions before advancing. Either:\n` +
        `      1. Run a fresh coherence check after editing answers: ` +
        `sprint-wizard-coherence.mjs ${slug} ${section} --record true "<notes>"\n` +
        `      2. Re-do the conflicting prior section (\`redo §<X>\`).\n`,
    )
  }

  partial.sections_status[section] = 'complete'
  savePartial(slug, partial)
  appendTranscript(slug, `\n### §${section} COMPLETE · ${new Date().toISOString()}\n`)
  ok(`§${section} marked complete`)

  const next = nextSection(partial, section)
  if (next) {
    partial.current_section = next
    savePartial(slug, partial)
    ok(`Advanced to §${next}`)
  } else {
    partial.current_section = 'complete'
    savePartial(slug, partial)
    ok('Wizard complete. Run: sprint-spec-wizard.mjs assemble ' + slug)
  }
}

function cmdAssemble(slug) {
  // AC-27 (sprint-system-100): backfill recalled_patterns before assemble.
  // SKILL.md says recall is "MANDATORY" but no CLI enforces it — every prior
  // sprint shipped with empty recalled-patterns.json despite memory.db
  // containing many lifeos-* patterns. Backfill closes that gap automatically.
  try {
    cmdRecallBackfill(slug)
  } catch (e) {
    process.stderr.write(`[!] recall backfill failed (non-fatal): ${e.message}\n`)
  }

  // Delegate to assemble helper
  const result = spawnSync('node', [join(__dirname, 'sprint-wizard-assemble.mjs'), slug], {
    stdio: 'inherit',
  })
  process.exit(result.status ?? 0)
}

function cmdRecallBackfill(slug) {
  // Build a search query from accumulated section answers, run ruflo memory
  // search, append results to partial.recalled_patterns. Skip if already
  // populated (so re-running assemble is idempotent).
  const partial = loadPartial(slug)
  if ((partial.recalled_patterns || []).length > 0) {
    ok(`[recall] skip — recalled_patterns already has ${partial.recalled_patterns.length} entries`)
    return
  }

  // Construct query: concatenate all narrative-flavored answers across sections.
  const queryParts = []
  for (const sec of SECTIONS) {
    const answers = partial.sections_answers?.[sec] || {}
    for (const [qid, ans] of Object.entries(answers)) {
      if (qid === 'flags') continue
      const s = typeof ans === 'string' ? ans : JSON.stringify(ans)
      if (s.length > 20 && s.length < 600) queryParts.push(s)
    }
  }
  if (queryParts.length === 0) {
    ok('[recall] no narrative answers to query; recall backfill skipped')
    return
  }
  const fullQuery = queryParts.join(' ').slice(0, 1500)

  const r = spawnSync('ruflo', ['memory', 'search', '-q', fullQuery, '--limit', '10'], {
    encoding: 'utf8',
  })
  if (r.status !== 0) {
    process.stderr.write('[!] ruflo memory search failed; recall backfill skipped\n')
    return
  }

  // Parse ASCII-table output. ruflo indents tables with leading whitespace,
  // so anchor on `\s*\|` not just `^\|`.
  const lines = r.stdout
    .split('\n')
    .filter((l) => /^\s*\|/.test(l))
    .filter((l) => !/Key\s+\|\s+Score/.test(l)) // header row
    .filter((l) => !/^\s*\|[-+ ]+\|/.test(l)) // separator row

  // Resolve truncated keys from the ASCII table (display caps at ~17 chars
  // with trailing "..."). Hit memory.db directly to recover full keys.
  const allKeys = (() => {
    try {
      const dbPath = join(REPO_ROOT, '.swarm', 'memory.db')
      const out = spawnSync('sqlite3', [dbPath, 'SELECT key FROM memory_entries'], {
        encoding: 'utf8',
      })
      if (out.status !== 0) return []
      return out.stdout
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean)
    } catch {
      return []
    }
  })()

  function resolveKey(preview) {
    const stripped = preview.replace(/\.\.\.$/, '').trim()
    if (!stripped.endsWith('-') && allKeys.includes(stripped)) return stripped
    // Find unique prefix match in memory.db
    const matches = allKeys.filter((k) => k.startsWith(stripped))
    if (matches.length === 1) return matches[0]
    // Multiple matches → return the shortest (most likely the intended prefix)
    if (matches.length > 1) return matches.sort((a, b) => a.length - b.length)[0]
    // No match → return stripped as-is (will fail later but recoverable)
    return stripped
  }

  const recalled = []
  for (const line of lines) {
    const cells = line
      .split('|')
      .map((c) => c.trim())
      .filter(Boolean)
    if (cells.length < 3) continue
    const [keyPreview, scoreStr, ns] = cells
    const score = parseFloat(scoreStr) || 0
    if (score < 0.5) continue
    const key = resolveKey(keyPreview)
    recalled.push({
      key,
      score,
      namespace: ns,
      accepted: true,
      applied_to: 'auto-backfill at assemble',
      section: 'auto',
      recorded_at: new Date().toISOString(),
    })
  }

  // Dual-write: both spec.partial.json AND the canonical recalled-patterns.json
  partial.recalled_patterns = recalled
  savePartial(slug, partial)

  const recalledFile = join(REPO_ROOT, 'docs', 'sprints', slug, 'recalled-patterns.json')
  writeFileSync(recalledFile, JSON.stringify(recalled, null, 2))

  ok(
    `[recall] backfilled ${recalled.length} patterns from memory.db (query: "${fullQuery.slice(0, 80)}...")`,
  )
  ok(`         wrote to spec.partial.json + ${recalledFile}`)
}

function cmdRecall(slug, section, pattern) {
  // Record a memory pattern as recalled (Claude calls this after memory_search)
  const partial = loadPartial(slug)
  partial.recalled_patterns ||= []
  let entry
  try {
    entry = JSON.parse(pattern)
  } catch {
    fail('Invalid JSON for pattern entry. Expected: { key, score, accepted, applied_to }')
  }
  entry.section = section
  entry.recorded_at = new Date().toISOString()
  partial.recalled_patterns.push(entry)
  savePartial(slug, partial)
  ok(`Recorded recalled pattern: ${entry.key} (accepted=${entry.accepted})`)
}

function cmdCoherence(slug, afterSection, passed, notes) {
  const partial = loadPartial(slug)
  partial.coherence_checks ||= []
  partial.coherence_checks.push({
    after_section: afterSection,
    passed: passed === 'true',
    notes: notes || '',
    at: new Date().toISOString(),
  })
  savePartial(slug, partial)
  appendTranscript(
    slug,
    `\n### Coherence check after §${afterSection} · passed=${passed}\n${notes || '(no notes)'}\n`,
  )
  ok(`Coherence check recorded after §${afterSection}: ${passed === 'true' ? 'PASS' : 'FAIL'}`)
}

// ── Entry point ──────────────────────────────────────────────────────────────

const [, , cmd, ...args] = process.argv

if (!cmd) {
  ok('Usage:')
  ok('  sprint-spec-wizard.mjs status <slug>')
  ok('  sprint-spec-wizard.mjs section <slug> <A-J>')
  ok(
    '  sprint-spec-wizard.mjs answer <slug> <section> <qid> <answer-as-json> [--user-confirmed|--force-advance]',
  )
  ok('  sprint-spec-wizard.mjs set-mode <slug> <interactive|autopilot>')
  ok('  sprint-spec-wizard.mjs skip <slug> <section> <reason>')
  ok('  sprint-spec-wizard.mjs complete-section <slug> <section>')
  ok('  sprint-spec-wizard.mjs recall <slug> <section> <pattern-as-json>')
  ok('  sprint-spec-wizard.mjs coherence <slug> <after-section> <true|false> [notes]')
  ok(
    '  sprint-spec-wizard.mjs recall-backfill <slug>      (AC-27: auto-recall patterns from memory.db)',
  )
  ok('  sprint-spec-wizard.mjs assemble <slug>')
  process.exit(0)
}

switch (cmd) {
  case 'status':
    cmdStatus(args[0] || fail('slug required'))
    break
  case 'section':
    cmdSection(args[0] || fail('slug required'), args[1] || fail('section required'))
    break
  case 'answer': {
    // AC-1: parse flags. Positional args remain: slug section qid answer.
    const positional = args.filter((a) => !a.startsWith('--'))
    const flagSet = new Set(args.filter((a) => a.startsWith('--')))
    cmdAnswer(
      positional[0] || fail('slug required'),
      positional[1] || fail('section required'),
      positional[2] || fail('qid required'),
      positional[3] || fail('answer required'),
      {
        userConfirmed: flagSet.has('--user-confirmed'),
        forceAdvance: flagSet.has('--force-advance'),
      },
    )
    break
  }
  case 'recall-backfill':
    cmdRecallBackfill(args[0] || fail('slug required'))
    break
  case 'set-mode':
    cmdSetMode(
      args[0] || fail('slug required'),
      args[1] || fail('mode required (interactive|autopilot)'),
    )
    break
  case 'skip':
    cmdSkip(
      args[0] || fail('slug required'),
      args[1] || fail('section required'),
      args[2] || fail('reason required'),
    )
    break
  case 'complete-section':
    cmdCompleteSection(args[0] || fail('slug required'), args[1] || fail('section required'))
    break
  case 'recall':
    cmdRecall(
      args[0] || fail('slug required'),
      args[1] || fail('section required'),
      args[2] || fail('pattern JSON required'),
    )
    break
  case 'coherence':
    cmdCoherence(
      args[0] || fail('slug required'),
      args[1] || fail('after-section required'),
      args[2] || fail('passed (true|false) required'),
      args[3] || '',
    )
    break
  case 'assemble':
    cmdAssemble(args[0] || fail('slug required'))
    break
  default:
    fail(`Unknown command: ${cmd}`)
}
