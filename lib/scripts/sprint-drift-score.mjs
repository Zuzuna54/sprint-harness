#!/usr/bin/env node
/**
 * sprint-drift-score.mjs — Compute cosine similarity between a baseline
 * embedding (from spec-lock) and a commit-signal text (message + diff).
 *
 * Usage:
 *   sprint-drift-score.mjs <baseline-embedding.json> <commit-signal-file>
 *
 * Output: a single float in [0,1] on stdout (e.g. "0.812").
 *
 * Baseline file shape:
 *   { "model": "Xenova/all-MiniLM-L6-v2", "dim": 384, "embedding": [<384 floats>] }
 *
 * Strategy for v1:
 *   - If `ruflo embeddings` CLI is installed AND supports encode, shell out to it.
 *   - Otherwise fall back to a lightweight bag-of-words cosine on tokens (NOT
 *     semantic, but better than nothing; mostly catches clear topic shifts).
 *
 * Future: replace fallback with Xenova/transformers.js bundled inline.
 */

import { readFileSync, existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'

const [, , baselinePath, signalFile] = process.argv

if (!baselinePath || !signalFile) {
  console.error('Usage: sprint-drift-score.mjs <baseline-embedding.json> <commit-signal-file>')
  process.exit(2)
}

if (!existsSync(baselinePath)) {
  console.error(`[!] baseline missing: ${baselinePath}`)
  process.exit(2)
}
if (!existsSync(signalFile)) {
  console.error(`[!] signal file missing: ${signalFile}`)
  process.exit(2)
}

const baseline = JSON.parse(readFileSync(baselinePath, 'utf8'))
const signalText = readFileSync(signalFile, 'utf8')

// ── Try ruflo embeddings CLI first ────────────────────────────────────────────
// AUDIT 2026-05-19: `ruflo embeddings encode` doesn't exist. The actual
// subcommand is `embeddings generate`. Pass -o json to get parseable output
// instead of the default preview format.
function tryRufloEmbedding(text) {
  const r = spawnSync('ruflo', ['embeddings', 'generate', '-t', text, '-o', 'json'], {
    encoding: 'utf8',
    maxBuffer: 20 * 1024 * 1024,
  })
  if (r.status !== 0) return null
  try {
    const parsed = JSON.parse(r.stdout)
    if (Array.isArray(parsed.embedding)) return parsed.embedding
    if (Array.isArray(parsed)) return parsed
  } catch {}
  return null
}

// ── Fallback: BoW cosine on lowercased tokens ────────────────────────────────
function tokenize(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s_-]/g, ' ')
    .split(/\s+/)
    .filter((t) => t.length >= 3 && t.length <= 30)
}

function bowVector(text) {
  const tokens = tokenize(text)
  const m = new Map()
  for (const t of tokens) m.set(t, (m.get(t) || 0) + 1)
  return m
}

function bowCosine(a, b) {
  // Use union of keys
  let dot = 0,
    normA = 0,
    normB = 0
  for (const [k, v] of a) {
    normA += v * v
    if (b.has(k)) dot += v * b.get(k)
  }
  for (const [, v] of b) normB += v * v
  if (normA === 0 || normB === 0) return 0
  return dot / (Math.sqrt(normA) * Math.sqrt(normB))
}

function vecCosine(a, b) {
  if (a.length !== b.length) return 0
  let dot = 0,
    normA = 0,
    normB = 0
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i]
    normA += a[i] * a[i]
    normB += b[i] * b[i]
  }
  if (normA === 0 || normB === 0) return 0
  return dot / (Math.sqrt(normA) * Math.sqrt(normB))
}

// ── Compute ──────────────────────────────────────────────────────────────────

// Path A: try semantic embedding via ruflo
const commitEmbedding = tryRufloEmbedding(signalText)

let score
if (commitEmbedding && baseline.embedding && Array.isArray(baseline.embedding)) {
  score = vecCosine(baseline.embedding, commitEmbedding)
} else {
  // Path B: fallback BoW
  // For BoW, baseline.embedding may be empty — need baseline.text instead
  const baselineText = baseline.text || (baseline.embedding || []).join(' ')
  if (!baselineText.trim()) {
    // Degraded fallback: return 1.0 (no signal to compare)
    console.error('[sprint-drift-score] no embedding nor baseline.text — returning 1.0')
    console.log('1.000')
    process.exit(0)
  }
  const a = bowVector(baselineText)
  const b = bowVector(signalText)
  score = bowCosine(a, b)
}

// Normalize to [0,1] (cosine for non-negative vectors is already in [0,1])
score = Math.max(0, Math.min(1, score))
console.log(score.toFixed(3))
