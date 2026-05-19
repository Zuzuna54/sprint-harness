#!/usr/bin/env node
// validate-phase-manifest.mjs — minimal structural validator for phase-manifest.json
// Exits 0 if manifest matches phase-manifest.schema.json; exits 1 with [FAIL] lines on stderr.
//
// Used by sprint-advance-phase.sh at startup AND by sprint-system-test.sh --replay-gate-history.
//
// Why not ajv: pulling a JSON-schema runtime is a heavy dep for a 50-line manifest.
// This validator covers exactly the predicate kinds + phase names we ship, no more.

import { readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const manifestPath = process.argv[2] || resolve(__dirname, 'phase-manifest.json')

const VALID_PHASES = new Set([
  'spec-wizard',
  'spec-locked',
  'design-locked',
  'building',
  'day-5-checkin',
  'cleaning',
  'verifying',
  'pre-deploy',
  'deploying',
  'done',
  'paused',
])

const VALID_PREDICATE_KINDS = new Set([
  'file_exists',
  'file_min_bytes',
  'file_contains_heading',
  'json_path_present',
  'json_path_equals',
  'json_path_in',
  'state_field_min_length',
  'state_field_all_values_in',
  'sub_step_recorded',
])

// Allow uppercase letters for wizard sections (wizard-section-A..J etc).
const GATE_NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9-]+$/

const failures = []
function fail(msg) {
  failures.push(msg)
}

let manifest
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
} catch (e) {
  console.error(`[FAIL] manifest parse: ${e.message}`)
  process.exit(1)
}

if (!manifest.version || !/^\d+\.\d+\.\d+$/.test(manifest.version)) {
  fail(`version: expected semver string, got ${JSON.stringify(manifest.version)}`)
}
if (!manifest.phases || typeof manifest.phases !== 'object') {
  fail('phases: missing or not an object')
}

// T4: deferred_gates[] is optional but if present must be array of strings
// matching the gate-name regex. Each entry should also appear in at least one
// phase's required_sub_step_gates[] or strict_only_sub_step_gates[].
const deferredGates = new Set()
if (manifest.deferred_gates !== undefined) {
  if (!Array.isArray(manifest.deferred_gates)) {
    fail('deferred_gates: not an array')
  } else {
    for (const g of manifest.deferred_gates) {
      if (typeof g !== 'string' || !GATE_NAME_RE.test(g)) {
        fail(`deferred_gates: invalid gate name "${g}"`)
      } else {
        deferredGates.add(g)
      }
    }
  }
}

for (const [phaseName, phase] of Object.entries(manifest.phases || {})) {
  if (!VALID_PHASES.has(phaseName)) {
    fail(`phase name "${phaseName}" not in canonical set`)
  }
  for (const field of [
    'advances_to',
    'required_artifacts',
    'required_state_fields',
    'required_sub_step_gates',
  ]) {
    if (!Array.isArray(phase[field])) {
      fail(`${phaseName}.${field}: not an array`)
    }
  }
  for (const target of phase.advances_to || []) {
    if (!VALID_PHASES.has(target)) {
      fail(`${phaseName}.advances_to: invalid target "${target}"`)
    }
  }
  for (const gate of phase.required_sub_step_gates || []) {
    if (typeof gate !== 'string' || !GATE_NAME_RE.test(gate)) {
      fail(`${phaseName}.required_sub_step_gates: invalid gate name "${gate}"`)
    }
  }
  for (const gate of phase.strict_only_sub_step_gates || []) {
    if (typeof gate !== 'string' || !GATE_NAME_RE.test(gate)) {
      fail(`${phaseName}.strict_only_sub_step_gates: invalid gate name "${gate}"`)
    }
  }
  for (const arr of ['required_artifacts', 'required_state_fields']) {
    for (const pred of phase[arr] || []) {
      if (!pred.kind || !VALID_PREDICATE_KINDS.has(pred.kind)) {
        fail(`${phaseName}.${arr}: invalid predicate kind "${pred.kind}"`)
      }
    }
  }
}

// Uniqueness across all phases: a gate name should not appear in two phases' required lists.
const seen = new Map()
for (const [phaseName, phase] of Object.entries(manifest.phases || {})) {
  for (const gate of [
    ...(phase.required_sub_step_gates || []),
    ...(phase.strict_only_sub_step_gates || []),
  ]) {
    if (seen.has(gate) && seen.get(gate) !== phaseName) {
      fail(`gate "${gate}" appears in both phases: ${seen.get(gate)} and ${phaseName}`)
    }
    seen.set(gate, phaseName)
  }
}

// T4: every deferred_gate name must appear in some phase's required gates
for (const g of deferredGates) {
  if (!seen.has(g)) {
    fail(
      `deferred_gates: "${g}" not declared in any phase's required_sub_step_gates[] or strict_only_sub_step_gates[]`,
    )
  }
}

if (failures.length > 0) {
  for (const f of failures) console.error(`[FAIL] ${f}`)
  console.error(`\n${failures.length} validation failure(s) in ${manifestPath}`)
  process.exit(1)
}

const phaseCount = Object.keys(manifest.phases).length
const gateCount = [...seen.keys()].length
const deferredCount = deferredGates.size
const enforcedCount = gateCount - deferredCount
console.error(
  `[OK] manifest valid: ${phaseCount} phases, ${gateCount} unique sub-step gates ` +
    `(${enforcedCount} enforced, ${deferredCount} deferred per T4)`,
)
process.exit(0)
