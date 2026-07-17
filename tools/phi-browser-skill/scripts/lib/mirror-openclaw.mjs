// Copyright 2026 Phinomenon Inc.
//
// OpenClaw adapter for the session mirror: locates the driving OpenClaw
// session's transcript and parses its events into console lines. OpenClaw
// (openclaw/openclaw) is a headless always-on gateway daemon — sessions live
// as rows in a per-agent SQLite database
// (~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite,
// transcript_events keyed by (session_id, seq); the old sessions/*.jsonl
// files are legacy archives), so the tailer polls rows by seq through
// lib/mirror-sqlite.
//
// Two OpenClaw-specific deviations from the terminal agents:
//   - Discovery: exec-tool children carry OPENCLAW_SHELL/OPENCLAW_CLI env
//     markers but NO session id, so the session is matched by evidence like
//     Codex/Pi: among sessions updated in the last 30 minutes, the one whose
//     recent transcript events mention the task id (the exec toolCall that
//     spawned this very heredoc is recorded before the shell runs). No
//     evidence → no mirror (never guess).
//   - Console→session delivery: there is no terminal to type into — the
//     gateway is a daemon and its "terminal" surfaces are WebSocket clients.
//     deliverOpenclaw() sends the command through the openclaw CLI
//     (`openclaw agent --session-id … --message …`, gateway URL/auth from
//     the user's own config), which starts a run in that session — the same
//     "wake an idle session" semantics as typed text elsewhere.
//
// Assumes the gateway (and its state dir) is on this Mac; a remote-gateway
// setup simply discovers nothing and keeps the say()/queue fallback.

import { existsSync, readdirSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { queryRows, sqlString } from './mirror-sqlite.mjs'

// A session not updated for this long belongs to an ended/parked run.
const SESSION_MAX_AGE_MS = 30 * 60 * 1000
// Evidence window: the spawning toolCall sits within the newest events.
const EVIDENCE_EVENTS = 50
// How long deliverOpenclaw waits for the CLI to fail before calling the
// command accepted: CLI errors (no gateway, bad auth, unknown session) exit
// within a moment; a healthy call may keep streaming the run's output far
// longer than the daemon can block.
const ACCEPT_WAIT_MS = 15 * 1000

/**
 * The driving OpenClaw session's transcript, or null. Returns
 * {sessionKey, path, format:'openclaw'} — sessionKey is the OpenClaw
 * session_id, used both for the tail and for deliverOpenclaw.
 */
export function discoverOpenclawTranscript(taskId) {
  if (!taskId || !underOpenclaw()) return null
  const candidates = []
  for (const db of agentDatabases()) {
    let sessions = []
    try {
      sessions = queryRows(db, 'SELECT session_id, updated_at FROM sessions'
        + ' ORDER BY updated_at DESC LIMIT 8')
    } catch { continue }
    for (const s of sessions) {
      if (!s.session_id || !isFresh(s.updated_at)) continue
      candidates.push({ db, sessionId: s.session_id, updatedAt: msOf(s.updated_at) })
    }
  }
  const needle = jsonEscaped(taskId)
  const withEvidence = candidates.filter((c) => {
    try {
      const rows = queryRows(c.db,
        'SELECT event_json FROM transcript_events'
        + ` WHERE session_id = ${sqlString(c.sessionId)}`
        + ` ORDER BY seq DESC LIMIT ${EVIDENCE_EVENTS}`)
      return rows.some((r) => String(r.event_json || '').includes(needle))
    } catch { return false }
  }).sort((a, b) => b.updatedAt - a.updatedAt)
  const best = withEvidence[0]
  if (!best) return null
  return { sessionKey: best.sessionId, path: best.db, format: 'openclaw' }
}

/** SQL for transcript events after `since`, ascending. */
export function openclawQuery(sessionId, since) {
  return 'SELECT seq, event_json FROM transcript_events'
    + ` WHERE session_id = ${sqlString(sessionId)} AND seq > ${Number(since)}`
    + ' ORDER BY seq LIMIT 200'
}

/** One transcript_events row → the tail item (raw is the event's own JSON). */
export function openclawRowToItem(row) {
  if (!row || typeof row.seq !== 'number' || !row.event_json) return null
  return { index: row.seq, raw: row.event_json }
}

/**
 * One transcript event → a console line, or null to skip. Only `message`
 * entries matter (session header, compaction, custom_message and friends are
 * machinery); user content is a string or text blocks, assistant content
 * keeps its text blocks only (thinking and toolCall are noise here), and
 * toolResult messages are skipped entirely.
 */
export function toEntry(obj) {
  if (!obj || obj.type !== 'message' || !obj.message) return null
  const role = obj.message.role
  if (role !== 'user' && role !== 'assistant') return null
  const ts = Date.parse(obj.timestamp || '') || obj.message.timestamp || undefined
  const content = obj.message.content
  const text = typeof content === 'string' ? content
    : Array.isArray(content)
      ? content.filter((b) => b && b.type === 'text' && b.text)
        .map((b) => b.text).join('\n\n')
      : ''
  if (!text.trim()) return null
  if (role === 'user') {
    // A console command deliverOpenclaw sent comes back around as a user
    // message; the app already echoed it at enqueue time.
    if (text.trimStart().startsWith('[phi-console]')) return null
    return { kind: 'user', text, ts }
  }
  return { kind: 'assistant', text, ts }
}

/**
 * Sends a console command into the session through the openclaw CLI.
 * Resolves when the CLI exits cleanly or is still running after
 * ACCEPT_WAIT_MS (the run outlives our patience — the message was
 * accepted); rejects on a prompt nonzero exit or a missing binary, which
 * the bridge turns into its usual retry.
 */
export function deliverOpenclaw(sessionId, text) {
  return new Promise((resolve, reject) => {
    let child
    try {
      child = spawn(openclawBin(),
                    ['agent', '--session-id', String(sessionId), '--message', text],
                    { stdio: 'ignore' })
    } catch (err) { reject(err); return }
    const timer = setTimeout(() => { child.unref() ; resolve() }, ACCEPT_WAIT_MS)
    child.once('error', (err) => { clearTimeout(timer); reject(err) })
    child.once('exit', (code) => {
      clearTimeout(timer)
      if (code === 0) resolve()
      else reject(new Error(`openclaw agent exited ${code}`))
    })
  })
}

// --- gate / filesystem helpers ------------------------------------------------

function underOpenclaw() {
  return Boolean(process.env.OPENCLAW_SHELL || process.env.OPENCLAW_CLI)
}

function stateDir() {
  return process.env.PHI_OPENCLAW_STATE_DIR || process.env.OPENCLAW_STATE_DIR
    || join(homedir(), '.openclaw')
}

/** Every agent's transcript database under the state dir. */
function agentDatabases() {
  const out = []
  const agents = join(stateDir(), 'agents')
  let dirs = []
  try { dirs = readdirSync(agents) } catch { return out }
  for (const dir of dirs) {
    const db = join(agents, dir, 'agent', 'openclaw-agent.sqlite')
    if (existsSync(db)) out.push(db)
  }
  return out
}

// sessions.updated_at units are not contractual — normalize to ms.
function msOf(value) {
  const n = Number(value) || 0
  return n > 1e12 ? n : n * 1000
}

function isFresh(updatedAt) {
  return Date.now() - msOf(updatedAt) <= SESSION_MAX_AGE_MS
}

function openclawBin() {
  if (process.env.PHI_OPENCLAW_BIN) return process.env.PHI_OPENCLAW_BIN
  for (const p of [join(homedir(), '.local', 'bin', 'openclaw'),
                   '/opt/homebrew/bin/openclaw', '/usr/local/bin/openclaw']) {
    if (existsSync(p)) return p
  }
  return 'openclaw'  // PATH
}

/** taskId as it appears inside the event's JSON-encoded command text. */
function jsonEscaped(value) {
  return JSON.stringify(String(value)).slice(1, -1)
}
