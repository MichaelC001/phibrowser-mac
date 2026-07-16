// Copyright 2026 Phinomenon Inc.
//
// Pi adapter for the session mirror: locates the driving Pi session's
// transcript (session format v3 JSONL under ~/.pi/agent/sessions/<munged
// cwd>/<timestamp>_<uuid>.jsonl) and parses its records into console lines.
// Everything downstream (control file, cursor, batched forward, terminal
// injection) is the shared core — this file only knows what is Pi-specific.
//
// Discovery: Pi exports no session id to its shells (only the
// PI_CODING_AGENT marker, set in the CLI's own process and inherited), so
// the session is matched by evidence, never guessed: among session files
// written in the last 30 minutes, prefer the one whose header line's cwd
// matches ours and whose tail mentions the task id (Pi records the
// assistant's toolCall — task name included — before the shell runs). The
// header line also carries the session's uuid, which becomes the cursor key.

import { openSync, readSync, closeSync, readdirSync, statSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { homedir } from 'node:os'
import { join, basename } from 'node:path'

// A session file not written for this long belongs to an ended/parked session.
const SESSION_MAX_AGE_MS = 30 * 60 * 1000

/**
 * One session-v3 JSONL record → a console line, or null to skip. Only
 * `message` records matter; `toolResult` role is machinery, and assistant
 * content keeps its text blocks only (thinking and toolCall are noise here —
 * the skill's own action lines already narrate the tool activity).
 */
export function toEntry(obj) {
  if (!obj || obj.type !== 'message' || !obj.message) return null
  const ts = Date.parse(obj.timestamp || '') || undefined
  const role = obj.message.role
  if (role !== 'user' && role !== 'assistant') return null
  const text = (obj.message.content || [])
    .filter((b) => b && b.type === 'text' && b.text)
    .map((b) => b.text).join('\n\n')
  if (role === 'user') {
    // Pi prepends the full <skill> document to every user turn's text; the
    // real prompt (if any) follows the closing tag. A skill-only turn is
    // machinery, not a prompt.
    const close = text.lastIndexOf('</skill>')
    const prompt = (close >= 0 ? text.slice(close + '</skill>'.length) : text).trim()
    if (!prompt) return null
    // A console command the daemon injected comes back around as a user
    // message; the app already echoed it at enqueue time.
    if (prompt.startsWith('[phi-console]')) return null
    return { kind: 'user', text: prompt, ts }
  }
  return text.trim() ? { kind: 'assistant', text, ts } : null
}

/**
 * The driving Pi session's transcript, or null. `agentPid` (the resolved
 * agent-root process) backs the under-Pi gate when the env marker is
 * stripped. Returns {sessionKey, path, format:'pi'}.
 */
export function discoverPiTranscript(taskId, agentPid) {
  if (!underPi(agentPid)) return null
  const files = recentSessionFiles(sessionsRoot())
  if (!files.length) return null
  const cwd = process.cwd()
  const scored = files.map((f) => {
    let score = 0
    let sessionId = null
    try {
      const header = JSON.parse(firstLine(f.path) || 'null')
      if (header?.type === 'session') {
        sessionId = header.id || null
        if (header.cwd === cwd) score += 2
      }
    } catch {}
    if (taskId && tailOf(f.path).includes(jsonEscaped(taskId))) score += 3
    return { ...f, score, sessionId }
  }).sort((a, b) => b.score - a.score || b.mtime - a.mtime)
  const best = scored[0]
  if (!best || best.score === 0) return null
  return {
    sessionKey: best.sessionId || `pi-${Math.round(best.mtime)}`,
    path: best.path,
    format: 'pi',
  }
}

// --- gate / filesystem helpers ------------------------------------------------

function underPi(agentPid) {
  if (process.env.PI_CODING_AGENT) return true
  try {
    if (agentPid) {
      // Pi brands itself via argv[0] ("pi" running node), so check the
      // command line, not the executable name.
      const argv0 = execFileSync('/bin/ps', ['-o', 'command=', '-p', String(agentPid)],
                                 { encoding: 'utf8' }).trim().split(/\s+/)[0] || ''
      return basename(argv0).toLowerCase() === 'pi'
    }
  } catch {}
  return false
}

function sessionsRoot() {
  return process.env.PI_CODING_AGENT_SESSION_DIR
    || join(homedir(), '.pi', 'agent', 'sessions')
}

/** Fresh session files across all project subdirs, newest first. */
function recentSessionFiles(root) {
  const out = []
  const now = Date.now()
  let dirs = []
  try { dirs = readdirSync(root) } catch { return out }
  for (const dir of dirs) {
    let files = []
    try { files = readdirSync(join(root, dir)) } catch { continue }
    for (const file of files) {
      if (!file.endsWith('.jsonl')) continue
      try {
        const path = join(root, dir, file)
        const mtime = statSync(path).mtimeMs
        if (now - mtime <= SESSION_MAX_AGE_MS) out.push({ path, mtime })
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

/** taskId as it appears inside the session's JSON-encoded command text. */
function jsonEscaped(value) {
  return JSON.stringify(String(value)).slice(1, -1)
}
