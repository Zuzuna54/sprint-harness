#!/usr/bin/env node
/**
 * sprint-token-tracker.mjs — Token burn observability for the sprint harness.
 *
 * Tracks where tokens go across jscpd scans, hook handlers, daemon workers,
 * and sprint-hook resolution. Real-time dashboard so operators can catch
 * a runaway burn source before it kills a session.
 *
 * Usage:
 *   node scripts/sprint-token-tracker.mjs status       # live dashboard (default)
 *   node scripts/sprint-token-tracker.mjs burn-report # detailed 7-day burn report
 *   node scripts/sprint-token-tracker.mjs estimate    # token cost estimates by source
 */

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execSync } from 'node:child_process'
import { createRequire } from 'node:module'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(__dirname, '..')
const STATS_FILE = join(process.env.HOME || '/tmp', '.claude', 'sprint-token-stats.json')
const DAEMON_LOG = join(process.env.HOME || '/tmp', '.claude', 'ruflo-daemon.log')

const require = createRequire(import.meta.url)

const [, , cmd = 'status', ...args] = process.argv

// ── Token burn source definitions ───────────────────────────────────────────

const TOKEN_ESTIMATES = {
  jscpd: { low: 50_000, high: 200_000, label: 'jscpd duplication scan' },
  hook_handler: { low: 500, high: 2000, label: 'hook-handler.cjs invocation' },
  sprint_hook: { low: 200, high: 500, label: 'sprint-hook.cjs resolution' },
  daemon_audit: { low: 10_000, high: 50_000, label: 'daemon audit worker' },
  daemon_optimize: { low: 10_000, high: 50_000, label: 'daemon optimize worker' },
  daemon_consolidate: { low: 10_000, high: 50_000, label: 'daemon consolidate worker' },
  daemon_document: { low: 10_000, high: 50_000, label: 'daemon document worker' },
}

const HOOK_BUDGET_MS = parseInt(process.env.HOOK_BUDGET_MS || '3000', 10)
const HOOK_BUDGET_DEFAULT = 3000

// ── Data collection helpers ─────────────────────────────────────────────────

function getSessionStats() {
  try {
    const statsPath = join(process.env.HOME || '/tmp', '.claude', 'sprint-token-stats.json')
    if (existsSync(statsPath)) {
      const raw = readFileSync(statsPath, 'utf8')
      const parsed = JSON.parse(raw)
      if (parsed && typeof parsed === 'object' && Array.isArray(parsed.sessions)) {
        return parsed
      }
      if (Array.isArray(parsed)) {
        return { sessions: parsed }
      }
    }
  } catch {}
  return { sessions: [], lastUpdated: null }
}

function saveSessionStats(stats) {
  try {
    const dir = join(process.env.HOME || '/tmp', '.claude')
    if (!existsSync(dir)) return
    writeFileSync(STATS_FILE, JSON.stringify(stats, null, 2))
  } catch {}
}

function getActiveSprint() {
  try {
    const result = execSync('bash scripts/sprint-status.sh --slug-only 2>/dev/null', {
      encoding: 'utf8',
      timeout: 5000,
      cwd: REPO_ROOT,
    })
    return result.trim() || null
  } catch {
    return null
  }
}

function getSettingsJson() {
  try {
    const path = join(REPO_ROOT, '.claude', 'settings.json')
    if (existsSync(path)) {
      return JSON.parse(readFileSync(path, 'utf8'))
    }
  } catch {}
  return null
}

function getDaemonWorkerStatus() {
  const settings = getSettingsJson()
  if (!settings) return []
  const daemonConfig = settings?.claudeFlow?.daemon
  if (!daemonConfig) return []

  const workers = daemonConfig.workers || []
  const schedules = daemonConfig.schedules || {}

  return workers.map((name) => {
    const sched = schedules[name] || {}
    return {
      name,
      interval: sched.interval || 'unknown',
      priority: sched.priority || 'low',
      nextRun: null,
      lastRun: null,
      lastDuration: null,
      tokens: null,
    }
  })
}

function getJscpdRunsFromGitLog(slug) {
  try {
    const since = '7 days ago'
    const result = execSync(
      `git log --since="${since}" --oneline --name-only --format="%H %ai" -- "docs/sprints/${slug}/reuse-audit.json" 2>/dev/null`,
      {
        encoding: 'utf8',
        timeout: 10000,
        cwd: REPO_ROOT,
      },
    )

    const runs = []
    const entries = result.trim().split('\n\n')
    for (const entry of entries) {
      const lines = entry.split('\n')
      if (lines.length < 2) continue
      const header = lines[0].split(' ')
      const sha = header[0]
      const dateStr = header.slice(1, 4).join(' ')
      if (lines[1]?.includes('reuse-audit.json')) {
        runs.push({ sha, date: dateStr, tokens: TOKEN_ESTIMATES.jscpd.high })
      }
    }
    return runs
  } catch {
    return []
  }
}

function getLastJscpdResult(slug) {
  try {
    const logDir = join(REPO_ROOT, '.husky', 'logs')
    if (!existsSync(logDir)) return null
    const logs = readdirSync(logDir).filter((f) => f.includes('reuse-audit'))
    if (logs.length === 0) return null
    const latest = logs.sort((a, b) => {
      return statSync(join(logDir, b)).mtimeMs - statSync(join(logDir, a)).mtimeMs
    })[0]
    const content = readFileSync(join(logDir, latest), 'utf8')
    const mtime = statSync(join(logDir, latest)).mtime
    const dupMatch = content.match(/Duplication results:\s*(\d+)/)
    const dupCount = dupMatch ? parseInt(dupMatch[1]) : 0
    return {
      logFile: latest,
      mtime: mtime.toISOString(),
      dupCount,
      tokens: TOKEN_ESTIMATES.jscpd.high,
    }
  } catch {
    return null
  }
}

function checkDaemonLog() {
  try {
    if (existsSync(DAEMON_LOG)) {
      const content = readFileSync(DAEMON_LOG, 'utf8')
      const lines = content.split('\n').filter(Boolean)
      return {
        exists: true,
        lines: lines.slice(-50),
        lastEntry: lines[lines.length - 1] || '',
        mtime: statSync(DAEMON_LOG).mtime.toISOString(),
      }
    }
  } catch {}
  return { exists: false, lines: [], lastEntry: '', mtime: null }
}

function parseDaemonLog(lines) {
  const events = []
  for (const line of lines) {
    const workerMatch = line.match(/worker=(\w+)/i)
    const durationMatch = line.match(/duration[=:](\d+)/i)
    const tokensMatch = line.match(/tokens[=:](\d+)/i)
    const timeMatch = line.match(/(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})/)
    if (workerMatch) {
      events.push({
        worker: workerMatch[1],
        duration: durationMatch ? parseInt(durationMatch[1]) : null,
        tokens: tokensMatch ? parseInt(tokensMatch[1]) : null,
        time: timeMatch ? timeMatch[1] : null,
      })
    }
  }
  return events
}

function estimateHookInvocations() {
  const stats = getSessionStats()
  const currentSession = process.env.CLAUDE_SESSION_ID || 'unknown'
  const today = new Date().toISOString().split('T')[0]

  let currentSessionEntry = stats.sessions?.find(
    (s) => s.sessionId === currentSession || s.date === today,
  )

  if (!currentSessionEntry) {
    currentSessionEntry = {
      date: today,
      sessionId: currentSession,
      sources: {
        jscpd: { runs: 0, tokens: 0 },
        hooks: { invocations: 0, tokens: 0 },
        daemon: { runs: 0, tokens: 0 },
        sprint_hook: { resolutions: 0, tokens: 0 },
      },
    }
  }

  const hookInvocations = currentSessionEntry.sources?.hooks?.invocations || 0
  const hookTokens = currentSessionEntry.sources?.hooks?.tokens || 0

  return {
    invocations: hookInvocations,
    tokens: hookTokens,
    avgPerInvocation: hookInvocations > 0 ? Math.round(hookTokens / hookInvocations) : 850,
  }
}

function getSprintHookStats() {
  const stats = getSessionStats()
  const today = new Date().toISOString().split('T')[0]
  const entry = stats.sessions?.find((s) => s.date === today)
  return {
    resolutions: entry?.sources?.sprint_hook?.resolutions || 0,
    tokens: entry?.sources?.sprint_hook?.tokens || 0,
  }
}

function getHookBudgetStats() {
  const stats = getSessionStats()
  const today = new Date().toISOString().split('T')[0]
  const entry = stats.sessions?.find((s) => s.date === today)

  const budgetHits = entry?.hookBudgetHits || 0
  const totalChecks = entry?.hookBudgetChecks || 1
  const budgetHitRate = totalChecks > 0 ? (budgetHits / totalChecks) * 100 : 0
  const timeSavedMs = budgetHits * (HOOK_BUDGET_MS - 500)

  return {
    budgetHits,
    totalChecks,
    budgetHitRate: Math.round(budgetHitRate * 10) / 10,
    timeSavedMs,
  }
}

function aggregate30DayBurn(stats) {
  if (!stats || !stats.sessions) {
    return {}
  }
  const now = Date.now()
  const cutoff = now - 30 * 24 * 60 * 60 * 1000
  const days = {}

  for (const entry of stats.sessions) {
    if (entry.date) {
      const d = new Date(entry.date).getTime()
      if (d >= cutoff) {
        const dayKey = entry.date.split('T')[0]
        days[dayKey] = days[dayKey] || { jscpd: 0, hooks: 0, daemon: 0, sprint_hook: 0 }
        const src = entry.sources || {}
        days[dayKey].jscpd += src.jscpd?.tokens || 0
        days[dayKey].hooks += src.hooks?.tokens || 0
        days[dayKey].daemon += src.daemon?.tokens || 0
        days[dayKey].sprint_hook += src.sprint_hook?.tokens || 0
      }
    }
  }

  return days
}

// ── Output formatters ────────────────────────────────────────────────────────

function fmt(n) {
  return n.toLocaleString('en-US')
}

function bar(pct, width = 20) {
  const filled = Math.round((pct / 100) * width)
  return '█'.repeat(filled) + '░'.repeat(width - filled)
}

function timestamp() {
  return new Date().toISOString().replace('T', ' ').split('.')[0]
}

// ── Command: status ─────────────────────────────────────────────────────────

function cmdStatus() {
  const slug = getActiveSprint()
  const workers = getDaemonWorkerStatus()
  const daemonLog = checkDaemonLog()
  const daemonEvents = daemonLog.exists ? parseDaemonLog(daemonLog.lines) : []
  const jscpdRuns = slug ? getJscpdRunsFromGitLog(slug) : []
  const lastJscpd = slug ? getLastJscpdResult(slug) : null
  const hookStats = estimateHookInvocations()
  const sprintHookStats = getSprintHookStats()
  const budgetStats = getHookBudgetStats()
  const stats = getSessionStats()
  const today = new Date().toISOString().split('T')[0]
  const todayEntry = stats.sessions?.find((s) => s.date === today)
  const sessionTokens = todayEntry
    ? (todayEntry.sources?.jscpd?.tokens || 0) +
      (todayEntry.sources?.hooks?.tokens || 0) +
      (todayEntry.sources?.daemon?.tokens || 0) +
      (todayEntry.sources?.sprint_hook?.tokens || 0)
    : 0

  const budget = parseInt(process.env.CLAUDE_TOKEN_BUDGET || '500000')
  const usedPct = budget > 0 ? Math.min(100, (sessionTokens / budget) * 100) : 0

  console.log('')
  console.log(`  Token Burn Tracker  ·  ${timestamp()}`)
  console.log('────────────────────────────────────────────────────────────────────')
  console.log(`  Sprint: ${slug || '(none)'}`)
  console.log(
    `  Session tokens: ${fmt(sessionTokens)} / ${fmt(budget)} ${bar(usedPct, 18)} ${usedPct.toFixed(1)}%`,
  )
  console.log('')

  const burners = []
  if (
    sessionTokens > 0 ||
    hookStats.invocations > 0 ||
    jscpdRuns.length > 0 ||
    daemonEvents.length > 0
  ) {
    const hookPct = sessionTokens > 0 ? (hookStats.tokens / sessionTokens) * 100 : 0
    const jscpdTokens =
      todayEntry?.sources?.jscpd?.tokens || jscpdRuns.length * TOKEN_ESTIMATES.jscpd.high
    const jscpdPct = sessionTokens > 0 ? (jscpdTokens / sessionTokens) * 100 : 0
    const daemonTokens = todayEntry?.sources?.daemon?.tokens || daemonEvents.length * 30000
    const daemonPct = sessionTokens > 0 ? (daemonTokens / sessionTokens) * 100 : 0
    const sprintHookTokens = sprintHookStats.tokens
    const sprintHookPct = sessionTokens > 0 ? (sprintHookTokens / sessionTokens) * 100 : 0

    if (jscpdTokens > 0)
      burners.push({ source: 'jscpd', tokens: jscpdTokens, pct: jscpdPct, runs: jscpdRuns.length })
    if (hookStats.tokens > 0)
      burners.push({
        source: 'hooks',
        tokens: hookStats.tokens,
        pct: hookPct,
        runs: hookStats.invocations,
      })
    if (daemonTokens > 0)
      burners.push({
        source: 'daemon',
        tokens: daemonTokens,
        pct: daemonPct,
        runs: daemonEvents.length,
      })
    if (sprintHookTokens > 0)
      burners.push({
        source: 'sprint-hook',
        tokens: sprintHookTokens,
        pct: sprintHookPct,
        runs: sprintHookStats.resolutions,
      })
  }

  burners.sort((a, b) => b.tokens - a.tokens)

  console.log('  TOP BURNS')
  if (burners.length === 0) {
    console.log('  (no burn data yet — hooks + jscpd will accumulate during session)')
  } else {
    for (const b of burners) {
      const name = b.source.padEnd(14)
      const pctBar = bar(b.pct, 12)
      console.log(
        `  ${name}  ${fmt(b.tokens).padStart(10)} tokens  ${pctBar}  ${b.pct.toFixed(1)}%  (${b.runs} runs)`,
      )
    }
  }
  console.log('')

  console.log('  DAEMON WORKERS')
  if (workers.length === 0) {
    console.log('  (daemon not configured in settings.json)')
  } else {
    for (const w of workers) {
      const lastEvent = daemonEvents.filter((e) => e.worker === w.name).slice(-1)[0]
      const nextStr =
        w.interval === '2h'
          ? 'in ~2h'
          : w.interval === '4h'
            ? 'in ~4h'
            : w.interval === '8h'
              ? 'in ~8h'
              : w.interval
      const lastStr = lastEvent?.time || 'never'
      const durStr = lastEvent?.duration ? `${lastEvent.duration}ms` : '—'
      const tokStr = lastEvent?.tokens ? fmt(lastEvent.tokens) : '?'
      console.log(
        `  ${w.name.padEnd(14)}  next: ${nextStr.padStart(8)}  last: ${lastStr}  dur: ${durStr.padEnd(8)}  tokens: ${tokStr}`,
      )
    }
  }
  console.log('')

  console.log('  LAST JSCPD SCAN')
  if (!slug) {
    console.log('  (no active sprint)')
  } else if (!lastJscpd) {
    console.log('  (no scan found in last 7 days)')
  } else {
    const ageMs = Date.now() - new Date(lastJscpd.mtime).getTime()
    const ageMin = Math.round(ageMs / 60000)
    console.log(`  File: .husky/logs/${lastJscpd.logFile}`)
    console.log(`  Time: ${lastJscpd.mtime} (${ageMin}m ago)`)
    console.log(`  Duplications: ${lastJscpd.dupCount}`)
    console.log(`  Tokens: ~${fmt(lastJscpd.tokens)}`)
    console.log(`  Runs (7d): ${jscpdRuns.length}`)
  }
  console.log('')

  console.log('  HOOK BUDGET')
  console.log(
    `  Budget: ${HOOK_BUDGET_MS}ms | Hit rate: ${budgetStats.budgetHitRate}% | Time saved: ${budgetStats.timeSavedMs}ms`,
  )
  console.log(
    `  Hook invocations: ${hookStats.invocations} | Tokens: ${fmt(hookStats.tokens)} | Avg: ${hookStats.avgPerInvocation}/inv`,
  )
  console.log('')

  console.log('────────────────────────────────────────────────────────────────────')
  console.log(`  Stats file: ${STATS_FILE}`)
  console.log(`  Daemon log: ${daemonLog.exists ? DAEMON_LOG + ' (active)' : '(not found)'}`)
  console.log('')
}

// ── Command: burn-report ───────────────────────────────────────────────────

function cmdBurnReport() {
  const stats = getSessionStats()
  const days = aggregate30DayBurn()
  const slug = getActiveSprint()
  const jscpdRuns = slug ? getJscpdRunsFromGitLog(slug) : []

  console.log('')
  console.log('  TOKEN BURN REPORT — Last 7 Days')
  console.log('════════════════════════════════════════════════════════════════════')

  const dayKeys = Object.keys(days).sort().slice(-7)

  if (dayKeys.length === 0) {
    console.log('  No data in last 7 days. Run hooks + jscpd to collect.')
  } else {
    for (const day of dayKeys) {
      const d = days[day]
      const total = d.jscpd + d.hooks + d.daemon + d.sprint_hook
      console.log(`  ${day}  total: ${fmt(total).padStart(10)} tokens`)
      console.log(
        `          jscpd: ${fmt(d.jscpd).padStart(8)}  hooks: ${fmt(d.hooks).padStart(8)}  daemon: ${fmt(d.daemon).padStart(8)}  sprint-hook: ${fmt(d.sprint_hook).padStart(8)}`,
      )
    }

    const totals = { jscpd: 0, hooks: 0, daemon: 0, sprint_hook: 0, all: 0 }
    for (const day of dayKeys) {
      totals.jscpd += days[day].jscpd
      totals.hooks += days[day].hooks
      totals.daemon += days[day].daemon
      totals.sprint_hook += days[day].sprint_hook
      totals.all += totals.jscpd + totals.hooks + totals.daemon + totals.sprint_hook
    }

    console.log('')
    console.log('  7-DAY TOTALS')
    const allSum = totals.jscpd + totals.hooks + totals.daemon + totals.sprint_hook
    for (const [src, label] of [
      ['jscpd', 'jscpd scans'],
      ['hooks', 'hook handlers'],
      ['daemon', 'daemon workers'],
      ['sprint_hook', 'sprint-hook'],
    ]) {
      const t = totals[src]
      const pct = allSum > 0 ? ((t / allSum) * 100).toFixed(1) : '0.0'
      const pctBar = bar(parseFloat(pct), 12)
      console.log(`  ${src.padEnd(12)}  ${fmt(t).padStart(10)} tokens  ${pctBar}  ${pct}%`)
    }
    console.log(`  ${'TOTAL'.padEnd(12)}  ${fmt(allSum).padStart(10)} tokens`)
  }

  console.log('')
  console.log('  JSCPD RUNS (7d)')
  if (jscpdRuns.length === 0) {
    console.log('  (none in last 7 days)')
  } else {
    for (const run of jscpdRuns.slice(0, 10)) {
      console.log(`  ${run.date}  ${run.sha.slice(0, 7)}  ~${fmt(run.tokens)} tokens`)
    }
    if (jscpdRuns.length > 10) {
      console.log(`  ... and ${jscpdRuns.length - 10} more`)
    }
  }

  console.log('')
  console.log('  RECOMMENDATIONS')
  const recommendations = []
  const sevenDayTotals = { jscpd: 0, hooks: 0, daemon: 0, sprint_hook: 0 }
  for (const day of dayKeys) {
    sevenDayTotals.jscpd += days[day]?.jscpd || 0
    sevenDayTotals.hooks += days[day]?.hooks || 0
    sevenDayTotals.daemon += days[day]?.daemon || 0
    sevenDayTotals.sprint_hook += days[day]?.sprint_hook || 0
  }

  if (sevenDayTotals.jscpd > 500_000) {
    recommendations.push(
      '🔴 jscpd is your #1 burner — consider skipping scans for non-sprint commits or caching results longer.',
    )
  }
  if (sevenDayTotals.jscpd > 100_000) {
    recommendations.push(
      '🟡 jscpd burn elevated — the 120s timeout + lockfile guard help, but still significant.',
    )
  }
  if (sevenDayTotals.hooks > 300_000) {
    recommendations.push(
      '🟡 hook invocations elevated — consider reducing PreToolUse hooks or increasing HOOK_BUDGET_MS.',
    )
  }
  if (sevenDayTotals.sprint_hook > 50_000) {
    recommendations.push('🟢 sprint-hook cache (5min TTL) is active — pre-cache is working.')
  }
  if (recommendations.length === 0) {
    recommendations.push('🟢 Token burn is within normal parameters.')
  }
  for (const r of recommendations) {
    console.log(`  ${r}`)
  }
  console.log('')
}

// ── Command: estimate ────────────────────────────────────────────────────────

function cmdEstimate() {
  console.log('')
  console.log('  TOKEN BURN ESTIMATES')
  console.log('════════════════════════════════════════════════════════════════════')
  console.log('')
  console.log('  Source                     Low        High       Avg         Notes')
  console.log('  ──────────────────────────────────────────────────────────────────')

  for (const [key, src] of Object.entries(TOKEN_ESTIMATES)) {
    const avg = Math.round((src.low + src.high) / 2)
    console.log(
      `  ${src.label.padEnd(26)}  ${fmt(src.low).padStart(8)}  ${fmt(src.high).padStart(8)}  ${fmt(avg).padStart(8)}  ${key}`,
    )
  }

  console.log('')
  console.log('  PER-TOOL HOOK OVERHEAD (settings.json hooks)')
  console.log('  ──────────────────────────────────────────────────────────────────')

  const hookOverhead = [
    { event: 'PreToolUse:Bash', hooks: 2, desc: 'hook-handler + sprint-hook' },
    { event: 'PreToolUse:Edit', hooks: 2, desc: 'hook-handler + sprint-hook' },
    { event: 'PostToolUse:Edit', hooks: 1, desc: 'hook-handler only' },
    { event: 'PostToolUse:Bash', hooks: 1, desc: 'hook-handler only' },
    { event: 'UserPromptSubmit', hooks: 1, desc: 'hook-handler route' },
    { event: 'SessionStart', hooks: 2, desc: 'hook-handler + auto-memory' },
    { event: 'SessionEnd', hooks: 1, desc: 'hook-handler' },
    { event: 'Stop', hooks: 1, desc: 'auto-memory sync' },
    { event: 'PreCompact', hooks: 2, desc: 'hook-handler + session-end' },
  ]

  for (const h of hookOverhead) {
    const tokens = h.hooks * 850
    console.log(`  ${h.event.padEnd(22)}  ${fmt(tokens).padStart(8)} tokens  (${h.desc})`)
  }

  console.log('')
  console.log('  SPRINT HOOK RESOLUTION (cached)')
  console.log('  ──────────────────────────────────────────────────────────────────')
  console.log('  Operation:  git rev-parse --show-toplevel + state.json read')
  console.log(`  Per call:   200-500 tokens  (was ~500-1000 before 5-min cache)`)
  console.log('  Budget:     HOOK_BUDGET_MS=3000ms — exits early if exceeded')
  console.log('  Cache TTL:  5 minutes (sprint-hook.cjs line 31)')
  console.log('')

  const settings = getSettingsJson()
  const daemonWorkers = settings?.claudeFlow?.daemon?.workers || []
  console.log('  DAEMON WORKERS (from .claude/settings.json)')
  console.log('  ──────────────────────────────────────────────────────────────────')
  for (const w of daemonWorkers) {
    const sched = settings?.claudeFlow?.daemon?.schedules?.[w] || {}
    console.log(
      `  ${w.padEnd(16)}  interval: ${(sched.interval || '?').padStart(5)}  priority: ${sched.priority || 'low'}`,
    )
    console.log(
      `                 est. tokens: ${fmt(TOKEN_ESTIMATES[`daemon_${w}`]?.high || 50000)} / run`,
    )
  }
  console.log('')
}

// ── Main dispatch ───────────────────────────────────────────────────────────

switch (cmd) {
  case 'status':
    cmdStatus()
    break
  case 'burn-report':
    cmdBurnReport()
    break
  case 'estimate':
    cmdEstimate()
    break
  default:
    console.error(`Unknown command: ${cmd}`)
    console.error('Usage: sprint-token-tracker.mjs [status|burn-report|estimate]')
    process.exit(1)
}
