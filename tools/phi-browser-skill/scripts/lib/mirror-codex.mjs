// Copyright 2026 Phinomenon Inc.
//
// Codex adapter for the session mirror: locates the driving Codex session's
// rollout transcript and parses its records into console lines. Everything
// downstream (control file, cursor, batched forward, terminal injection) is
// the shared core — this file only knows what is Codex-specific.
//
// Discovery, in order of confidence:
//   1. CODEX_THREAD_ID in the environment names the rollout file exactly
//      (rollout-<timestamp>-<threadId>.jsonl under ~/.codex/sessions).
//   2. Heuristic: among rollouts written in the last 30 minutes, prefer the
//      one whose session_meta cwd matches ours and whose tail mentions the
//      task id — the function_call that spawned this very heredoc (task name
//      included) is recorded in the rollout before the shell runs, so the
//      right file is both fresh and self-referential. No evidence → no
//      mirror (never guess: mirroring the WRONG session into the console is
//      worse than mirroring nothing).
// Both paths are gated on actually running under Codex (env markers or a
// codex ancestor process), so other agents never trigger rollout scans.

import { openSync, readSync, closeSync, readdirSync, statSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { homedir } from 'node:os'
import { join, basename } from 'node:path'

// A rollout not written for this long belongs to an ended/parked session.
const ROLLOUT_MAX_AGE_MS = 30 * 60 * 1000

/**
 * One rollout JSONL record → a console line, or null to skip. Rollouts carry
 * each message TWICE — as a `response_item` (raw model item, where role:user
 * also covers system-injected texts) and as an `event_msg` (the display
 * stream, only real prompts and replies). We parse event_msg exclusively:
 * one source, no duplicates, no machinery.
 */
export function toEntry(obj) {
  if (!obj || obj.type !== 'event_msg' || !obj.payload) return null
  const ts = Date.parse(obj.timestamp || '') || undefined
  const p = obj.payload
  if (typeof p.message !== 'string' || !p.message.trim()) return null
  if (p.type === 'user_message') {
    // A console command the daemon injected comes back around as a user
    // message; the app already echoed it at enqueue time.
    if (p.message.trimStart().startsWith('[phi-console]')) return null
    return { kind: 'user', text: p.message, ts }
  }
  if (p.type === 'agent_message') {
    return { kind: 'assistant', text: p.message, ts }
  }
  return null
}

/**
 * The driving Codex session's rollout, or null. `agentPid` (the resolved
 * agent-root process) backs the under-Codex gate when env markers are
 * stripped. Returns {sessionKey, path, format:'codex'}.
 */
export function discoverCodexTranscript(taskId, agentPid) {
  if (!underCodex(agentPid)) return null
  const rollouts = recentRollouts(sessionsRoot())
  if (!rollouts.length) return null

  const threadId = process.env.CODEX_THREAD_ID
  if (threadId) {
    const exact = rollouts.find((r) => basename(r.path).includes(threadId))
    if (exact) return { sessionKey: threadId, path: exact.path, format: 'codex' }
  }

  const cwd = process.cwd()
  const scored = rollouts.map((r) => {
    let score = 0
    try {
      const meta = JSON.parse(firstLine(r.path) || 'null')
      if (meta?.payload?.cwd === cwd) score += 2
    } catch {}
    if (taskId && tailOf(r.path).includes(jsonEscaped(taskId))) score += 3
    return { ...r, score }
  }).sort((a, b) => b.score - a.score || b.mtime - a.mtime)
  const best = scored[0]
  if (!best || best.score === 0) return null
  return {
    sessionKey: threadIdFromName(best.path) || `codex-${Math.round(best.mtime)}`,
    path: best.path,
    format: 'codex',
  }
}

// --- gate / filesystem helpers ------------------------------------------------

function underCodex(agentPid) {
  if (process.env.CODEX_THREAD_ID || process.env.CODEX_SANDBOX) return true
  try {
    if (agentPid) {
      const comm = execFileSync('/bin/ps', ['-o', 'comm=', '-p', String(agentPid)],
                                { encoding: 'utf8' }).trim()
      return basename(comm).toLowerCase().startsWith('codex')
    }
  } catch {}
  return false
}

function sessionsRoot() {
  if (process.env.PHI_CODEX_SESSIONS_DIR) return process.env.PHI_CODEX_SESSIONS_DIR
  return join(process.env.CODEX_HOME || join(homedir(), '.codex'), 'sessions')
}

/** Fresh rollout files from today's and yesterday's date folders, newest first. */
function recentRollouts(root) {
  const out = []
  const now = Date.now()
  for (const daysAgo of [0, 1]) {
    const d = new Date(now - daysAgo * 86400000)
    const dir = join(root, String(d.getFullYear()),
                     String(d.getMonth() + 1).padStart(2, '0'),
                     String(d.getDate()).padStart(2, '0'))
    let files = []
    try { files = readdirSync(dir) } catch { continue }
    for (const file of files) {
      if (!file.startsWith('rollout-') || !file.endsWith('.jsonl')) continue
      try {
        const path = join(dir, file)
        const mtime = statSync(path).mtimeMs
        if (now - mtime <= ROLLOUT_MAX_AGE_MS) out.push({ path, mtime })
      } catch {}
    }
  }
  return out.sort((a, b) => b.mtime - a.mtime)
}

function firstLine(path) {
  const fd = openSync(path, 'r')
  try {
    const buf = Buffer.alloc(8192)
    const n = readSync(fd, buf, 0, buf.length, 0)
    return buf.toString('utf8', 0, n).split('\n')[0]
  } finally { closeSync(fd) }
}

/** The file's last 64KB — enough tail to find the record that spawned us. */
function tailOf(path) {
  try {
    const size = statSync(path).size
    const want = Math.min(size, 64 * 1024)
    const fd = openSync(path, 'r')
    try {
      const buf = Buffer.alloc(want)
      readSync(fd, buf, 0, want, size - want)
      return buf.toString('utf8')
    } finally { closeSync(fd) }
  } catch { return '' }
}

/** taskId as it appears inside the rollout's JSON-encoded command text. */
function jsonEscaped(value) {
  return JSON.stringify(String(value)).slice(1, -1)
}

function threadIdFromName(path) {
  const m = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/
    .exec(basename(path))
  return m ? m[1] : null
}
