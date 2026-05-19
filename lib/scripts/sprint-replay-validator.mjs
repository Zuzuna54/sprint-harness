#!/usr/bin/env node
// sprint-replay-validator.mjs — AC-13 (harness-deterministic-phases-v1)
//
// Walks every docs/sprints/<slug>/state.json where state.phase == "done" and
// asserts the gate-history audit trail is monotonic, complete (every
// required_sub_step_gates entry has a matching gates_passed[] OR gate_bypasses[]
// record), and bypasses are well-formed (gate ∈ manifest, why ≥10 chars).
//
// Also checks doc-vs-manifest drift: every gate name in the phase-enforcement
// section of USAGE.md must appear in phase-manifest.json (AC-13 sub-clause d).
//
// Usage:
//   node scripts/sprint-replay-validator.mjs [--ignore-pre <ISO-date>]
//                                            [--only-sprint <slug>]
//                                            [--quiet]
//
// Exit codes:
//   0  — all closed sprints pass
//   1  — at least one sprint fails replay
//   2  — argument error

import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { resolve, join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(__dirname, '..')
const MANIFEST_PATH = join(__dirname, 'lib', 'phase-manifest.json')
const SPRINTS_DIR = join(REPO_ROOT, 'docs', 'sprints')
// Default ignore-pre date: v0.7.0 release date (replay only on sprints closed
// after the deterministic-phase enforcement landed).
const DEFAULT_IGNORE_PRE = '2026-05-19T00:00:00Z'

// ── Args ─────────────────────────────────────────────────────────────────────
const args = process.argv.slice(2)
let ignorePre = DEFAULT_IGNORE_PRE
let onlySlug = null
let quiet = false
let checkDocDrift = true
let reportFile = null // L19 (closure Wave C): markdown report output path
for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--ignore-pre':
      ignorePre = args[++i]
      break
    case '--only-sprint':
      onlySlug = args[++i]
      break
    case '--quiet':
      quiet = true
      break
    case '--no-doc-drift':
      checkDocDrift = false
      break
    case '--report-file':
      reportFile = args[++i]
      break
    case '--help':
    case '-h':
      console.log(
        `Usage: sprint-replay-validator.mjs [--ignore-pre <ISO>] [--only-sprint <slug>] [--quiet] [--no-doc-drift] [--report-file <path>]`,
      )
      process.exit(0)
    default:
      console.error(`unknown arg: ${args[i]}`)
      process.exit(2)
  }
}

// ── Load manifest ────────────────────────────────────────────────────────────
if (!existsSync(MANIFEST_PATH)) {
  console.error(`[FATAL] manifest not found: ${MANIFEST_PATH}`)
  process.exit(1)
}
const manifest = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8'))
const allManifestGates = new Set()
for (const [phaseName, phase] of Object.entries(manifest.phases)) {
  for (const g of [
    ...(phase.required_sub_step_gates || []),
    ...(phase.strict_only_sub_step_gates || []),
  ]) {
    allManifestGates.add(g)
  }
}

// T4: gates in deferred_gates[] are NOT yet instrumented. Missing+no-bypass
// for these doesn't fail replay — they're documented intentional gaps.
const deferredGates = new Set(manifest.deferred_gates || [])

// ── Helpers ──────────────────────────────────────────────────────────────────
function log(msg) {
  if (!quiet) console.error(msg)
}
function gateName(entry) {
  if (typeof entry === 'string') return entry
  return entry?.gate || null
}
function gatesSet(state) {
  // Union of state.gates_passed[] and state.gates[], normalized to gate name strings.
  const s = new Set()
  for (const arr of [state.gates_passed, state.gates]) {
    if (!Array.isArray(arr)) continue
    for (const e of arr) {
      const g = gateName(e)
      if (g) s.add(g)
    }
  }
  return s
}
function bypassedSet(state) {
  const s = new Set()
  if (!Array.isArray(state.gate_bypasses)) return s
  for (const e of state.gate_bypasses) {
    if (e?.gate) s.add(e.gate)
  }
  return s
}

// ── Find candidate sprint dirs ───────────────────────────────────────────────
const sprintDirs = []
if (existsSync(SPRINTS_DIR)) {
  for (const entry of readdirSync(SPRINTS_DIR, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    if (entry.name.startsWith('_') || entry.name.startsWith('.')) continue
    if (onlySlug && entry.name !== onlySlug) continue
    const stateFile = join(SPRINTS_DIR, entry.name, 'state.json')
    if (existsSync(stateFile)) sprintDirs.push({ slug: entry.name, stateFile })
  }
}

// ── Walk each sprint ─────────────────────────────────────────────────────────
const failures = []
let walked = 0
let skipped = 0
let passed = 0

for (const { slug, stateFile } of sprintDirs) {
  let state
  try {
    state = JSON.parse(readFileSync(stateFile, 'utf8'))
  } catch (e) {
    failures.push({ slug, reason: `state.json parse error: ${e.message}` })
    continue
  }
  if (state.phase !== 'done') {
    skipped++
    continue
  }
  // Ignore-pre filter
  const closedAt = state.closed_at || state.started_at
  if (closedAt && closedAt < ignorePre) {
    log(`[skip] ${slug}: closed_at=${closedAt} < ignore-pre=${ignorePre}`)
    skipped++
    continue
  }
  // Skip pre-v0.7 sprints that closed via the OLD inline-jq path:
  // - no gate_history entries with .by="sprint-advance-phase.sh"
  // - no worker_rigor field
  // These are legacy closures, not subject to the new replay contract.
  const hasCanonicalGateHistory =
    Array.isArray(state.gate_history) &&
    state.gate_history.some((h) => h?.by === 'sprint-advance-phase.sh')
  if (!hasCanonicalGateHistory && state.worker_rigor === undefined) {
    log(
      `[skip] ${slug}: pre-v0.7 closure (no sprint-advance-phase.sh in gate_history, no worker_rigor field)`,
    )
    skipped++
    continue
  }
  walked++

  const localFailures = []

  // (a) gate_history monotonic by `at`
  const hist = Array.isArray(state.gate_history) ? state.gate_history : []
  let prevAt = ''
  for (const h of hist) {
    if (!h?.at) continue
    if (h.at < prevAt) {
      localFailures.push(
        `gate_history not monotonic: ${h.at} < ${prevAt} (entry ${JSON.stringify(h).slice(0, 100)})`,
      )
    }
    prevAt = h.at
  }

  // (b) For each phase walked through, every required_sub_step_gates entry
  // must be in gates_passed ∪ gate_bypasses.
  const gates = gatesSet(state)
  const bypassed = bypassedSet(state)
  const phasesWalked = new Set()
  // Initial phase is spec-wizard; collect everything between via .from/.to.
  phasesWalked.add('spec-wizard')
  for (const h of hist) {
    if (h?.from) phasesWalked.add(h.from)
    if (h?.to) phasesWalked.add(h.to)
  }
  const workerRigor = state.worker_rigor || 'lax'
  for (const phaseName of phasesWalked) {
    const phase = manifest.phases[phaseName]
    if (!phase) {
      localFailures.push(`walked phase '${phaseName}' not in manifest`)
      continue
    }
    const required = [...(phase.required_sub_step_gates || [])]
    if (workerRigor === 'strict') {
      required.push(...(phase.strict_only_sub_step_gates || []))
    }
    for (const g of required) {
      if (!gates.has(g) && !bypassed.has(g)) {
        // T4: deferred gates aren't required for replay pass
        if (deferredGates.has(g)) continue
        localFailures.push(
          `phase '${phaseName}' missing sub-step '${g}' (not in gates_passed/gates nor in gate_bypasses)`,
        )
      }
    }
  }

  // (c) All gate_bypasses[] entries well-formed: gate ∈ manifest, why ≥10 chars
  if (Array.isArray(state.gate_bypasses)) {
    for (const b of state.gate_bypasses) {
      if (!b?.gate) {
        localFailures.push(`gate_bypass missing .gate field: ${JSON.stringify(b).slice(0, 100)}`)
        continue
      }
      // Bypass gates can be artifact-paths (e.g., "design.md") too — not all are sub-step names.
      // We only flag if the gate looks like a sub-step name (no slash, no extension) AND isn't in manifest.
      const looksLikeSubStep = !/[/.]/.test(b.gate)
      if (looksLikeSubStep && !allManifestGates.has(b.gate)) {
        localFailures.push(
          `gate_bypass '${b.gate}' looks like a sub-step name but isn't in manifest`,
        )
      }
      if (typeof b.why !== 'string' || b.why.length < 10) {
        localFailures.push(
          `gate_bypass '${b.gate}' has why='${(b.why || '').slice(0, 40)}' (${(b.why || '').length} chars, need ≥10)`,
        )
      }
    }
  }

  if (localFailures.length > 0) {
    failures.push({ slug, reason: localFailures })
  } else {
    passed++
    log(
      `[OK] ${slug}: ${phasesWalked.size} phases walked, ${gates.size} gates recorded, ${bypassed.size} bypassed`,
    )
  }
}

// ── Doc-vs-manifest drift check ─────────────────────────────────────────────
let docDriftFailures = 0
if (checkDocDrift) {
  const usagePath = join(REPO_ROOT, 'docs', 'sprints', 'USAGE.md')
  if (existsSync(usagePath)) {
    const usage = readFileSync(usagePath, 'utf8')
    // Extract gate names from "## Phase enforcement" section (if it exists).
    const phaseEnforceMatch = usage.match(/##\s*Phase enforcement[\s\S]*?(?=^##\s|$)/m)
    if (phaseEnforceMatch) {
      const section = phaseEnforceMatch[0]
      // Gate names follow the kebab-case pattern in backticks: `gate-name`
      const gatePattern = /`([a-zA-Z][a-zA-Z0-9-]+)`/g
      const docGates = new Set()
      let m
      while ((m = gatePattern.exec(section)) !== null) {
        const candidate = m[1]
        // Only check candidates that look like gate names (kebab + ≥2 segments)
        if (/^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)+$/.test(candidate)) {
          docGates.add(candidate)
        }
      }
      for (const g of docGates) {
        if (!allManifestGates.has(g)) {
          // Tolerate non-gate kebab strings (e.g. "spec-locked" phase names)
          if (manifest.phases[g]) continue
          log(
            `[DOC DRIFT] USAGE.md "## Phase enforcement" mentions '${g}' but it's not in manifest`,
          )
          docDriftFailures++
        }
      }
    }
  }
}

// ── Summary ─────────────────────────────────────────────────────────────────
console.error(
  `\n[REPLAY SUMMARY] walked=${walked} passed=${passed} failed=${failures.length} skipped=${skipped} doc_drift=${docDriftFailures}`,
)
for (const f of failures) {
  console.error(`\n[FAIL] sprint=${f.slug}:`)
  if (Array.isArray(f.reason)) {
    for (const r of f.reason) console.error(`  - ${r}`)
  } else {
    console.error(`  - ${f.reason}`)
  }
}

// L19 (closure Wave C): write markdown report if --report-file given.
if (reportFile) {
  const { writeFileSync } = await import('node:fs')
  const lines = []
  lines.push('# Replay Validator Report')
  lines.push('')
  lines.push(`Generated: ${new Date().toISOString()}`)
  lines.push('')
  lines.push('## Summary')
  lines.push('')
  lines.push('| Metric | Count |')
  lines.push('|---|---|')
  lines.push(`| Sprints walked | ${walked} |`)
  lines.push(`| Sprints passed | ${passed} |`)
  lines.push(`| Sprints failed | ${failures.length} |`)
  lines.push(`| Sprints skipped (pre-v0.7 or in-flight) | ${skipped} |`)
  lines.push(`| Doc-drift findings | ${docDriftFailures} |`)
  lines.push('')
  if (failures.length > 0) {
    lines.push('## Failures')
    lines.push('')
    for (const f of failures) {
      lines.push(`### sprint: ${f.slug}`)
      lines.push('')
      if (Array.isArray(f.reason)) {
        for (const r of f.reason) lines.push(`- ${r}`)
      } else {
        lines.push(`- ${f.reason}`)
      }
      lines.push('')
    }
  } else {
    lines.push('## Failures')
    lines.push('')
    lines.push('_(none)_')
    lines.push('')
  }
  writeFileSync(reportFile, lines.join('\n'))
  console.error(`\n[REPORT] wrote ${reportFile}`)
}

if (failures.length > 0 || docDriftFailures > 0) {
  process.exit(1)
}
process.exit(0)
