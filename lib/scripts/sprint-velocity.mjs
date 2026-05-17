#!/usr/bin/env node
/**
 * sprint-velocity.mjs — Compute velocity + drift + AC closure metrics.
 *
 * Reads state.json + retro.md, computes:
 *   - time_to_spec_lock_hours
 *   - time_to_design_lock_hours
 *   - elapsed_total_days
 *   - acs_total / acs_closed / ac_closure_rate
 *   - drift_events_count
 *   - drift_pauses_count (events that triggered actual pauses)
 *   - scope_amendments_count
 *   - pair_mode_acs_count
 *   - success_criteria_met (bool — all ACs + appetite + low drift)
 *
 * Writes docs/sprints/<slug>/metrics.json.
 *
 * Usage:
 *   sprint-velocity.mjs <slug>          # write metrics.json + print summary
 *   sprint-velocity.mjs <slug> --json   # JSON output only
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')

const [, , slug, ...flags] = process.argv
if (!slug) {
  console.error('Usage: sprint-velocity.mjs <slug> [--json]')
  process.exit(1)
}

const asJson = flags.includes('--json')
const sprintDir = join(REPO_ROOT, 'docs', 'sprints', slug)
const statePath = join(sprintDir, 'state.json')
const metricsPath = join(sprintDir, 'metrics.json')

if (!existsSync(statePath)) {
  console.error(`[!] state.json missing: ${statePath}`)
  process.exit(1)
}

const state = JSON.parse(readFileSync(statePath, 'utf8'))

// Gate timestamps — search pause_events and gates_passed array
function findGateTime(state, gateName) {
  // gates_passed is just an array; we need timestamps from elsewhere
  // Try the gates_history if it exists, else fall back to derived times
  if (state.gates_history && Array.isArray(state.gates_history)) {
    const found = state.gates_history.find((g) => g.gate === gateName)
    if (found) return new Date(found.at).getTime()
  }
  return null
}

const startedMs = state.started_at_epoch
  ? state.started_at_epoch * 1000
  : state.started_at
    ? new Date(state.started_at).getTime()
    : null
const closedMs = state.closed_at ? new Date(state.closed_at).getTime() : Date.now()

const elapsedMs = closedMs - (startedMs || closedMs)
const elapsedDays = elapsedMs / 86400000

const specLockMs = findGateTime(state, 'spec-lock')
const designLockMs = findGateTime(state, 'design-lock')

const timeToSpecLockHours = specLockMs && startedMs ? (specLockMs - startedMs) / 3600000 : null
const timeToDesignLockHours =
  designLockMs && startedMs ? (designLockMs - startedMs) / 3600000 : null

// BUG 3 fix: state.acs_total isn't reliably populated by the wizard yet,
// so fall back to parsing spec.md directly. Match `**AC-<n>**` regardless of
// the rest of the line (works for both Gherkin headers and INVEST lines).
const _specPath = join(sprintDir, 'spec.md')
let acsTotal = state.acs_total || 0
let acsClosed = state.acs_closed || 0
let pairModeAcs = 0

if (acsTotal === 0 && existsSync(_specPath)) {
  const spec = readFileSync(_specPath, 'utf8')
  const acMatches = [...spec.matchAll(/\*\*AC-(\d+)\*\*/g)]
  acsTotal = acMatches.length
  if (Array.isArray(state.acs_closed_ids)) {
    acsClosed = state.acs_closed_ids.length
  } else {
    acsClosed = (spec.match(/^- \[x\]/gm) || []).length
  }
  pairModeAcs = (spec.match(/`complex:\s*true`/g) || []).length
}
const acClosureRate = acsTotal > 0 ? acsClosed / acsTotal : 0

const driftEvents = state.drift_events || []
const driftBelowThreshold = driftEvents.filter((e) => e.score < 0.75).length
const driftAboveThreshold = driftEvents.filter((e) => e.score >= 0.75).length

const pauseEvents = state.pause_events || []
const scopeAmendments = (state.scope_amendments || []).length

// Pair-mode count was computed above as part of BUG 3 fix. Re-check here
// in case the upstream branch didn't populate it (acsTotal came from state).
if (pairModeAcs === 0 && existsSync(_specPath)) {
  const spec = readFileSync(_specPath, 'utf8')
  pairModeAcs = (spec.match(/`complex:\s*true`/g) || []).length
}

// AC-6 (Bugs #17, #23): success criteria evaluation with intentional-skip support
// Previously: `time_to_design_lock_under_2d: null || under` treated null as truthy
// → tooling sprints (which skip design-lock) silently "passed" this criterion.
// Now: require either passed (under 2d) OR explicitly skipped via gates_skipped[].

const gatesSkipped = state.gates_skipped || []
const designLockIntentionallySkipped = gatesSkipped.includes('design-lock')
const designLockPassedInTime = timeToDesignLockHours != null && timeToDesignLockHours <= 48

const successCriteriaMet = {
  all_acs_closed: acsTotal > 0 && acsClosed === acsTotal,
  within_appetite_14d: elapsedDays <= 14,
  low_drift_events: driftBelowThreshold <= 3,
  // PASSES if: design-lock landed under 2d, OR was explicitly skipped (tooling sprint)
  // FAILS if: design-lock attempted but slow, OR skipped without recording in gates_skipped
  time_to_design_lock_ok: designLockPassedInTime || designLockIntentionallySkipped,
}

// Backward-compat field name for existing tooling that reads the old key
successCriteriaMet.time_to_design_lock_under_2d = successCriteriaMet.time_to_design_lock_ok

const successCriteriaAllMet = Object.values(successCriteriaMet).every(Boolean)

const metrics = {
  slug,
  computed_at: new Date().toISOString(),
  timing: {
    started_at: state.started_at || null,
    closed_at: state.closed_at || null,
    elapsed_days: Number(elapsedDays.toFixed(2)),
    appetite_days: state.appetite_days || 14,
    appetite_used_pct: Number(((elapsedDays / (state.appetite_days || 14)) * 100).toFixed(1)),
    time_to_spec_lock_hours:
      timeToSpecLockHours != null ? Number(timeToSpecLockHours.toFixed(1)) : null,
    time_to_design_lock_hours:
      timeToDesignLockHours != null ? Number(timeToDesignLockHours.toFixed(1)) : null,
  },
  acs: {
    total: acsTotal,
    closed: acsClosed,
    closure_rate: Number(acClosureRate.toFixed(2)),
    complex_count: pairModeAcs,
  },
  gates: {
    passed: state.gates_passed || [],
    skipped: gatesSkipped,
    history: state.gate_history || [],
  },
  drift: {
    events_total: driftEvents.length,
    above_threshold: driftAboveThreshold,
    below_threshold_paused: driftBelowThreshold,
    pause_events: pauseEvents.length,
  },
  scope: {
    amendments: scopeAmendments,
    files_touched_count: (state.files_touched || []).length,
  },
  success_criteria: successCriteriaMet,
  success_criteria_all_met: successCriteriaAllMet,
}

writeFileSync(metricsPath, JSON.stringify(metrics, null, 2))

if (asJson) {
  console.log(JSON.stringify(metrics, null, 2))
} else {
  console.log(`Sprint velocity: ${slug}`)
  console.log('')
  console.log('Timing:')
  console.log(
    `  Elapsed:                   ${metrics.timing.elapsed_days}d (${metrics.timing.appetite_used_pct}% of appetite)`,
  )
  console.log(`  Time to spec-lock:         ${metrics.timing.time_to_spec_lock_hours ?? '—'}h`)
  console.log(`  Time to design-lock:       ${metrics.timing.time_to_design_lock_hours ?? '—'}h`)
  console.log('')
  console.log('ACs:')
  console.log(`  Total:                     ${metrics.acs.total}`)
  console.log(
    `  Closed:                    ${metrics.acs.closed} (${(metrics.acs.closure_rate * 100).toFixed(0)}%)`,
  )
  console.log(`  Complex (pair-mode):       ${metrics.acs.complex_count}`)
  console.log('')
  console.log('Drift:')
  console.log(`  Total events:              ${metrics.drift.events_total}`)
  console.log(`  Below 0.75 (paused):       ${metrics.drift.below_threshold_paused}`)
  console.log(`  Pause events:              ${metrics.drift.pause_events}`)
  console.log('')
  console.log('Scope:')
  console.log(`  Amendments:                ${metrics.scope.amendments}`)
  console.log(`  Files touched:             ${metrics.scope.files_touched_count}`)
  console.log('')
  console.log(`Success criteria (4 of 4):`)
  for (const [k, v] of Object.entries(metrics.success_criteria)) {
    console.log(`  ${v ? '✓' : '✗'} ${k}`)
  }
  console.log('')
  console.log(`Overall: ${metrics.success_criteria_all_met ? '✓ SUCCESS' : '⚠ partial'}`)
  console.log('')
  console.log(`Written to: ${metricsPath}`)
}
