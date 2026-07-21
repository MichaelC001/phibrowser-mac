// Copyright 2026 Phinomenon Inc.
//
// OpenClaw adapter for the session mirror: locates the driving OpenClaw
// session's transcript and parses its events into console lines. OpenClaw
// (openclaw/openclaw) is a headless always-on gateway daemon — live session
// transcripts are Claude-style JSONL event files under the per-agent state
// dir (~/.openclaw/agents/<agentId>/sessions/<sessionId>.jsonl, with a
// sessions.json index and *.trajectory.jsonl artifacts alongside), so the
// tailer reads them with its shared JSONL TranscriptTail like the terminal
// agents. OpenClaw's database-first refactor plans to move transcripts into
// the per-agent SQLite as transcript_events rows, but shipped versions
// (through at least 2026.7.1) keep only cache/auth/memory tables there —
// revisit this adapter when transcripts actually land in SQLite.
//
// Two OpenClaw-specific deviations from the terminal agents:
//   - Discovery: exec-tool children carry OPENCLAW_SHELL/OPENCLAW_CLI env
//     markers but NO session id, so the session is matched by evidence like
//     Codex/Pi: among transcripts written in the last 30 minutes, the one
//     whose newest bytes mention the task id (the exec toolCall that
//     spawned this very heredoc is recorded before the shell runs). No
//     evidence → no mirror (never guess).
//   - Console→session delivery: there is no terminal to type into — the
//     gateway is a daemon and its "terminal" surfaces are WebSocket clients.
//     OpenclawConsoleBridge drains the app's queued console commands each
//     tailer tick and sends them through the openclaw CLI
//     (`openclaw agent --session-id … --message …`, gateway URL/auth from
//     the user's own config), which starts a run in that session — the same
//     "wake an idle session" semantics as typed text elsewhere.
//
// Assumes the gateway (and its state dir) is on this Mac; a remote-gateway
// setup simply discovers nothing and keeps the say()/queue fallback.

import {
  existsSync, readdirSync, statSync, openSync, readSync, closeSync,
} from 'node:fs'
import { spawn } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { forwardEntries } from './mirror-core.mjs'

// A transcript not written to for this long belongs to an ended/parked run.
const SESSION_MAX_AGE_MS = 30 * 60 * 1000
// Evidence window: the spawning toolCall sits within the newest bytes.
const EVIDENCE_TAIL_BYTES = 256 * 1024
// How long deliverOpenclaw waits for the CLI to fail before calling the
// command accepted: CLI errors (no gateway, bad auth, unknown session) exit
// within a moment; a healthy call may keep streaming the run's output far
// longer than the daemon can block.
const ACCEPT_WAIT_MS = 15 * 1000
// Delivery attempts per console command before giving up with a console
// error line (gateway unreachable and the like).
const MAX_DELIVER_ATTEMPTS = 5

/**
 * The driving OpenClaw session's transcript, or null. Returns
 * {sessionKey, path, format:'openclaw'} — sessionKey is the OpenClaw
 * session_id (the transcript's basename), used for deliverOpenclaw; path is
 * the JSONL file the tailer follows.
 */
export function discoverOpenclawTranscript(taskId) {
  if (!taskId || !underOpenclaw()) return null
  const needle = jsonEscaped(taskId)
  const candidates = []
  for (const dir of sessionDirs()) {
    let files = []
    try { files = readdirSync(dir) } catch { continue }
    for (const file of files) {
      // <sessionId>.jsonl is the live transcript; sessions.json and
      // *.trajectory.jsonl / *.trajectory-path.json are index and artifacts.
      if (!file.endsWith('.jsonl') || file.endsWith('.trajectory.jsonl')) continue
      const path = join(dir, file)
      let mtimeMs
      try { mtimeMs = statSync(path).mtimeMs } catch { continue }
      if (Date.now() - mtimeMs > SESSION_MAX_AGE_MS) continue
      candidates.push({ path, sessionId: file.slice(0, -'.jsonl'.length), mtimeMs })
    }
  }
  const withEvidence = candidates
    .filter((c) => tailText(c.path).includes(needle))
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
  const best = withEvidence[0]
  if (!best) return null
  return { sessionKey: best.sessionId, path: best.path, format: 'openclaw' }
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

/**
 * The console → session direction, driven by the tailer's sweep tick (the
 * daemon instantiates one per session for format 'openclaw' only — every
 * other terminal agent has no delivery transport and its commands stay
 * queued until the driver's next round). Drains the app's queued console
 * commands and delivers them into the driving session, ONLY when the task
 * is idle: a live round is expected to drain the queue itself, and racing
 * it would strand a waitForUserMessage on an empty queue. Commands are
 * delivered with a "[phi-console]" prefix: the agent sees the provenance
 * (answer via narrate/console, not just its own surface), and toEntry
 * suppresses the echoed transcript line (the app already echoed the command
 * at enqueue).
 */
export class OpenclawConsoleBridge {
  // `deliver` is a seam for fixture tests; the daemon uses the real CLI.
  constructor(sessionKey, { deliver = deliverOpenclaw } = {}) {
    this.sessionKey = sessionKey
    this.deliver = deliver
    this.undelivered = []     // [{text, attempts}] retrying across ticks
  }

  /** True means the task no longer exists — the daemon should exit. */
  async deliverPending(ctl, channel) {
    if (!ctl.taskId || !ctl.agentPid) return false
    const { tasks } = await channel.send('agentSpace.list', {})
    const task = (tasks || []).find((t) => t.taskId === ctl.taskId)
    if (!task) return true
    const queued = task.pendingUserMessages || 0
    if (!queued && !this.undelivered.length) return false
    // Deliver only between rounds: a live round drains the queue itself
    // (readUserMessages / waitForUserMessage), and a starting one gets the
    // count in its ensureAgentSpace return.
    if (task.status !== 'idle') return false

    if (queued) {
      const { messages } = await channel.send(
        'agentSpace.readUserMessages', { taskId: ctl.taskId })
      for (const m of messages || []) {
        this.undelivered.push({ text: m.text, attempts: 0 })
      }
    }
    const retry = []
    for (const item of this.undelivered) {
      try {
        await this.deliver(this.sessionKey, `[phi-console] ${item.text}`)
        await new Promise((r) => setTimeout(r, 300))  // pace successive deliveries
      } catch {
        item.attempts += 1
        if (item.attempts < MAX_DELIVER_ATTEMPTS) {
          retry.push(item)
        } else {
          await forwardEntries(ctl.taskId, [{
            kind: 'error',
            text: 'Could not deliver your command to the agent',
            detail: item.text.slice(0, 200),
          }], channel).catch(() => {})
        }
      }
    }
    this.undelivered = retry
    return false
  }
}

// --- gate / filesystem helpers ------------------------------------------------

function underOpenclaw() {
  return Boolean(process.env.OPENCLAW_SHELL || process.env.OPENCLAW_CLI)
}

function stateDir() {
  return process.env.PHI_OPENCLAW_STATE_DIR || process.env.OPENCLAW_STATE_DIR
    || join(homedir(), '.openclaw')
}

/** Every agent's live-transcript directory under the state dir. */
function sessionDirs() {
  const out = []
  const agents = join(stateDir(), 'agents')
  let dirs = []
  try { dirs = readdirSync(agents) } catch { return out }
  for (const dir of dirs) {
    const d = join(agents, dir, 'sessions')
    if (existsSync(d)) out.push(d)
  }
  return out
}

/** The newest EVIDENCE_TAIL_BYTES of the file as text ('' on any error). */
function tailText(path) {
  try {
    const size = statSync(path).size
    const start = Math.max(0, size - EVIDENCE_TAIL_BYTES)
    const fd = openSync(path, 'r')
    try {
      const buf = Buffer.alloc(size - start)
      readSync(fd, buf, 0, buf.length, start)
      return buf.toString('utf8')
    } finally {
      closeSync(fd)
    }
  } catch { return '' }
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
