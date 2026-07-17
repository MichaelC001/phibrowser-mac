// Copyright 2026 Phinomenon Inc.
//
// Hermes adapter for the session mirror: locates the driving Hermes session
// (NousResearch/hermes-agent) and parses its message rows into console
// lines. Hermes stores every session in one SQLite database —
// ~/.hermes/state.db, messages table — not per-session JSONL, so the tailer
// polls rows by autoincrement id through lib/mirror-sqlite. Everything
// downstream (control file, cursor, batched forward, terminal injection) is
// the shared core.
//
// Discovery is exact: Hermes exports HERMES_SESSION_ID into every tool
// subprocess (the strongest binding of all five agents — gate and session
// key in one). Injection reuses the terminal path unchanged: the classic
// `hermes` CLI is a prompt_toolkit REPL where Enter submits typed text. The
// --tui / desktop / gateway surfaces have no reachable terminal — their
// console commands stay queued for the next round, the standard fallback.

import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { sqlString } from './mirror-sqlite.mjs'

/**
 * The driving Hermes session's database, or null. Returns
 * {sessionKey, path, format:'hermes'} — sessionKey is the Hermes session id,
 * which is also the messages.session_id the tail polls.
 */
export function discoverHermesTranscript() {
  const sessionId = process.env.HERMES_SESSION_ID
  if (!sessionId) return null
  const db = join(hermesHome(), 'state.db')
  return existsSync(db) ? { sessionKey: sessionId, path: db, format: 'hermes' } : null
}

function hermesHome() {
  return process.env.PHI_HERMES_HOME || process.env.HERMES_HOME
    || join(homedir(), '.hermes')
}

/**
 * SQL for message rows after `since`, ascending. Role filtering happens
 * here (tool/system rows are machinery) and rewinds are honored via
 * active=1 — a rewound-away row simply stops existing for the mirror.
 */
export function hermesQuery(sessionId, since) {
  return `SELECT id, role, content, timestamp FROM messages`
    + ` WHERE session_id = ${sqlString(sessionId)} AND id > ${Number(since)}`
    + ` AND active = 1 AND role IN ('user','assistant')`
    + ` ORDER BY id LIMIT 200`
}

/** One messages row → the tail item (raw carries the row for toEntry). */
export function hermesRowToItem(row) {
  if (!row || typeof row.id !== 'number') return null
  return { index: row.id, raw: JSON.stringify(row) }
}

/** One messages row (as queried above) → a console line, or null to skip. */
export function toEntry(obj) {
  if (!obj || (obj.role !== 'user' && obj.role !== 'assistant')) return null
  const text = contentText(obj.content)
  if (!text) return null
  const ts = obj.timestamp ? Math.round(Number(obj.timestamp) * 1000) : undefined
  if (obj.role === 'user') {
    // A console command the daemon injected comes back around as a user
    // message; the app already echoed it at enqueue time.
    if (text.trimStart().startsWith('[phi-console]')) return null
    return { kind: 'user', text, ts }
  }
  return { kind: 'assistant', text, ts }
}

// Hermes content is a plain string, or "\x00json:"-prefixed JSON when the
// message is multimodal — then keep the text blocks and drop the rest.
const JSON_PREFIX = '\x00json:'

function contentText(content) {
  if (typeof content !== 'string' || !content.trim()) return null
  if (!content.startsWith(JSON_PREFIX)) return content.trim() ? content : null
  try {
    const blocks = JSON.parse(content.slice(JSON_PREFIX.length))
    if (!Array.isArray(blocks)) return null
    const texts = blocks.filter((b) => b && b.type === 'text' && b.text)
      .map((b) => b.text)
    return texts.length ? texts.join('\n\n') : null
  } catch { return null }
}
