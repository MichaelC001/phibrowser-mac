// Copyright 2026 Phinomenon Inc.
//
// Agent-neutral core of the session mirror: the per-session control file
// that binds a driving agent session to its browser task and its tailer
// daemon, the per-session transcript cursor, and the batched forward into
// the task's console. The daemon (scripts/mirror-tailer.mjs) supplies the
// agent-specific parts — transcript location and parsing (lib/mirror-claude
// for Claude Code today; Codex/Pi siblings later reuse everything here).
//
// Session binding is explicit, not inferred: the heredoc that starts a task
// KNOWS its own session (CLAUDE_CODE_SESSION_ID) and transcript, writes them
// into the control file, and spawns the daemon against it — so a concurrent
// unrelated session can never leak its conversation into someone else's
// console, and two agents driving two tasks each mirror into their own.

import {
  readFileSync, writeFileSync, unlinkSync, mkdirSync, readdirSync, statSync,
} from 'node:fs'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join, basename } from 'node:path'
import { discoverEndpoint, DirectPhiChannel } from './cdp.mjs'

// Same directory as helpers.mjs's task files — path derived identically on
// both sides so writer (heredoc) and reader (daemon) always agree.
const TASK_DIR = join(tmpdir(), 'phi-browser-tasks')

// First sight of a session key (fresh cursor): a RESUMED session replays the
// prior conversation's history under a NEW session id, and an unguarded
// backfill would re-mirror all of it as duplicates. The daemon only
// backfills lines authored since shortly before it started — which still
// covers the prompt that started the task.
export const BACKFILL_GRACE_MS = 10 * 60 * 1000

/**
 * The driving agent process's pid: the nearest ancestor that isn't a shell
 * or wrapper (for a heredoc, the agent above the tool shell). Recorded in
 * the control file so the daemon — reparented to launchd once the heredoc
 * exits — can still find the session's terminal and notice the agent dying.
 * Null when ps is unavailable.
 */
export function agentRootPid() {
  try {
    const out = execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,comm='],
                             { encoding: 'utf8' })
    const table = new Map()
    for (const line of out.split('\n')) {
      const m = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line)
      if (m) table.set(Number(m[1]), { ppid: Number(m[2]), comm: m[3] })
    }
    let pid = process.ppid
    for (let hops = 0; hops < 64 && pid > 1; hops++) {
      const proc = table.get(pid)
      if (!proc) break
      // Login shells report as "-zsh"; strip the marker before matching.
      const name = basename(proc.comm).replace(/^-/, '').toLowerCase()
      if (!PASSTHROUGH.has(name)) return pid
      if (proc.ppid === pid) break
      pid = proc.ppid
    }
  } catch {}
  return null
}

// Shell and wrapper processes skipped when walking ancestry for the agent
// root — the JS mirror of AgentPeerIdentity.passthroughNames plus the shells
// that sit between an agent and the tools it spawns.
const PASSTHROUGH = new Set([
  'sh', 'bash', 'zsh', 'dash', 'fish', 'csh', 'tcsh', 'ksh',
  'env', 'login', 'sudo', 'xargs', 'timeout', 'nohup', 'caffeinate', 'script',
  // Codex wraps sandboxed shell commands in seatbelt.
  'sandbox-exec',
])

// --- daemon control ----------------------------------------------------------

// One control file per session coordinates the mirror: the skill writes
// {taskId, transcriptPath, agentPid, termProgram, ts} on every
// ensureAgentSpace (refreshing the TTL and re-targeting a live daemon
// without a respawn), the daemon adds its pid claim, and complete() deletes
// the file — which is also how a running daemon is told to exit.

function daemonControlFile(sessionKey) {
  return join(TASK_DIR, `mirror-daemon-${sanitizeKey(sessionKey)}.json`)
}

export function readDaemonControl(sessionKey) {
  try {
    return JSON.parse(readFileSync(daemonControlFile(sessionKey), 'utf8'))
  } catch { return null }
}

export function writeDaemonControl(sessionKey, record) {
  try {
    mkdirSync(TASK_DIR, { recursive: true })
    writeFileSync(daemonControlFile(sessionKey), JSON.stringify(record))
    pruneStaleFiles()
  } catch {}
}

export function clearDaemonControl(sessionKey) {
  try { unlinkSync(daemonControlFile(sessionKey)) } catch {}
}

export function pidAlive(pid) {
  try { process.kill(pid, 0); return true } catch { return false }
}

// --- per-session transcript cursor ------------------------------------------

// The cursor is a count of non-empty lines into the session's append-only
// transcript, so every forward is idempotent and ordered: forward only what
// was added since the last one, advance only after a successful forward.

function cursorFile(sessionKey) {
  return join(TASK_DIR, `mirror-cursor-${sanitizeKey(sessionKey)}.json`)
}

/**
 * `known: false` means this session key has never been seen — the caller
 * should apply the BACKFILL_GRACE_MS guard (a resumed session replays prior
 * history under a fresh key; without the guard those lines mirror twice).
 */
export function readCursor(sessionKey) {
  try {
    const cursor = JSON.parse(readFileSync(cursorFile(sessionKey), 'utf8')).cursor
    return { cursor: cursor || 0, known: true }
  } catch { return { cursor: 0, known: false } }
}

export function writeCursor(sessionKey, cursor) {
  try {
    mkdirSync(TASK_DIR, { recursive: true })
    writeFileSync(cursorFile(sessionKey), JSON.stringify({ cursor }))
  } catch {}
}

function sanitizeKey(id) {
  return String(id || 'default').replace(/[^\w.-]/g, '_').slice(0, 80)
}

// --- app channel / forward ----------------------------------------------------

/**
 * A direct app-socket channel (throws if Phi or the socket is down). The
 * daemon holds one persistently — it also carries the agentSpace.userMessage
 * broadcasts that wake the console-command bridge — and reconnects by simply
 * calling this again after a send failure.
 */
export async function openPhiChannel() {
  const endpoint = discoverEndpoint()
  if (endpoint.kind !== 'uds') throw new Error('no app socket endpoint')
  return new DirectPhiChannel({ socketPath: endpoint.socketPath }).connect()
}

/**
 * Sends `entries` ([{kind, text, detail?, ts?}], oldest first) to the task's
 * console as ONE batched agentSpace.log call, so delivery is all-or-nothing:
 * a failure re-tries the whole batch on the next tick instead of duplicating
 * an already-delivered prefix. `touch: false` marks this as mirror traffic —
 * proof the SESSION is alive, not that it is still driving — so it never
 * extends an idle Space's keep-alive. Throws on any failure; the caller
 * advances its cursor only on success. Uses `channel` when given (the
 * daemon's persistent one), else a one-shot connection.
 */
export async function forwardEntries(taskId, entries, channel = null) {
  const own = channel == null
  const ch = own ? await openPhiChannel() : channel
  try {
    const res = await ch.send('agentSpace.log', {
      taskId,
      touch: false,
      entries: entries.map((e) => ({
        kind: e.kind,
        text: String(e.text).slice(0, 4000),
        ...(e.detail ? { detail: String(e.detail).slice(0, 500) } : {}),
        ...(e.ts ? { ts: e.ts } : {}),
      })),
    })
    if (res && res.ok === false) {
      throw new Error(res.error || 'agentSpace.log rejected')
    }
  } finally {
    if (own) ch.close()
  }
}

// --- housekeeping -------------------------------------------------------------

// Opportunistic, on control writes only: cursor and control leftovers from
// crashed sessions go after a week (their sessions are long over).
function pruneStaleFiles() {
  const now = Date.now()
  for (const file of readdirSync(TASK_DIR)) {
    if (!file.startsWith('mirror-cursor-') && !file.startsWith('mirror-daemon-')
        && !/^active(-\d+)?\.json$/.test(file)) continue
    try {
      const path = join(TASK_DIR, file)
      if (now - statSync(path).mtimeMs > 7 * 24 * 60 * 60 * 1000) unlinkSync(path)
    } catch {}
  }
}
