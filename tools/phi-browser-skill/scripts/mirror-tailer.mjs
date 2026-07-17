// Copyright 2026 Phinomenon Inc.
//
// Session-mirror tailer daemon — the bridge between a driving code agent
// session and its agent Space console, in BOTH directions, with no setup:
//
//   session → console: tails the session transcript and forwards new
//     prompt/prose lines (batched, cursor-ordered) so the console reads like
//     the agent's own conversation.
//   console → session: listens for the app's agentSpace.userMessage
//     broadcast; while the task is IDLE (no round live to drain the queue
//     itself) it drains the user's console commands and types them into the
//     session's own terminal tab — tty-matched and foreground-guarded (see
//     lib/mirror-inject.mjs) — so a console command wakes an idle session
//     instead of waiting for its next round.
//
// ensureAgentSpace spawns it detached (arg: session key) after writing the
// session's daemon control file. Lifetime is bounded by construction —
// every exit path is deliberate:
//   - control file deleted (complete() ran) or claimed by another pid
//   - control ts stale: no heredoc refreshed it for CONTROL_TTL_MS
//   - the driving agent process died (control.agentPid gone)
//   - the task is unknown to the app (ended); a later round respawns us
//   - the transcript file disappeared
// Everything is best-effort and silent: the daemon must never outlive its
// usefulness, and a premature exit only costs a respawn on the next round.

import { openSync, readSync, closeSync, statSync } from 'node:fs'
import {
  readDaemonControl, writeDaemonControl, readCursor, writeCursor,
  forwardEntries, openPhiChannel, pidAlive, BACKFILL_GRACE_MS,
} from './lib/mirror-core.mjs'
import { toEntry as claudeToEntry } from './lib/mirror-claude.mjs'
import { toEntry as codexToEntry } from './lib/mirror-codex.mjs'
import { toEntry as piToEntry } from './lib/mirror-pi.mjs'
import { ttyOfPid, isForeground, probeTerminal, injectText } from './lib/mirror-inject.mjs'

const POLL_MS = 1000
const CONTROL_TTL_MS = 30 * 60 * 1000
// The broadcast wakes the console-command bridge instantly; this sweep is
// the delivery guarantee for a missed broadcast (channel down, app restart).
const MESSAGE_SWEEP_MS = 10 * 1000
// Between-rounds keep-alive. The skill's own long-TTL ping runs at clean
// round end (__dispose) — but a driver whose harness SIGKILLs tool calls
// (Pi's 10s bash timeout) never disposes, the task falls back to the app's
// short default TTL, and it gets reaped mid-conversation: the re-created
// task then starts a fresh console, losing the mirrored history. The daemon
// is the one process that KNOWS the session is still alive (agentPid), so
// it heartbeats the task while it runs. Bounded on every side: the daemon
// exits with the session, with the control TTL (30 min after the last real
// round), and on complete() — so an abandoned Space still closes.
const HEARTBEAT_MS = 60 * 1000
const HEARTBEAT_TTL_SECONDS = 300
// Per-batch and in-memory bounds; overflow drops OLDEST (flood policy: a
// long backlog keeps its newest lines).
const MAX_LINES_PER_BATCH = 60
const MAX_PENDING = 500
// Delivery attempts per console command before giving up with a console
// error line (tab closed mid-task and the like).
const MAX_INJECT_ATTEMPTS = 5

const sessionKey = process.argv[2]
process.title = 'phi-mirror-tailer'
if (!sessionKey) process.exit(0)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

main().catch(() => {}).finally(() => process.exit(0))

async function main() {
  // Claim the session: exactly one daemon per session key. The write-then-
  // reread settles a spawn race — the loser sees the other pid and exits.
  let ctl = readDaemonControl(sessionKey)
  if (!ctl || !ctl.transcriptPath) return
  if (ctl.pid && ctl.pid !== process.pid && pidAlive(ctl.pid)) return
  writeDaemonControl(sessionKey, { ...ctl, pid: process.pid })
  await sleep(300)
  ctl = readDaemonControl(sessionKey)
  if (!ctl || ctl.pid !== process.pid) return

  const startTs = Date.now()
  let { cursor, known } = readCursor(sessionKey)
  const tail = new TranscriptTail(ctl.transcriptPath)
  // The transcript's dialect, chosen by whoever spawned us (see the
  // per-agent discover* in mirror-claude / mirror-codex / mirror-pi).
  const toEntry = ctl.format === 'codex' ? codexToEntry
    : ctl.format === 'pi' ? piToEntry
    : claudeToEntry
  const pending = []
  const bridge = new ConsoleCommandBridge()

  // Persistent app channel: carries the log forwards, the message drains,
  // and the userMessage broadcast. Marked dead on any send failure and
  // reopened lazily — while Phi is down, everything simply accumulates.
  let channel = null
  let bridgeWake = false
  let lastSweep = 0
  // First heartbeat after one interval — the round that spawned us is live
  // and already refreshing the clock itself.
  let lastHeartbeat = Date.now()
  const ensureChannel = async () => {
    if (channel) return channel
    // Name the driving agent session on the connection: this daemon is
    // detached (reparented to launchd once its spawning round exits), so the
    // app's ancestry walk can't reach the agent — the claimed pid keeps the
    // consent identity on the agent instead of this daemon.
    channel = await openPhiChannel({ agentPid: Number(ctl.agentPid) || null })
    channel.onEvent('agentSpace.userMessage', ({ taskId }) => {
      const cur = readDaemonControl(sessionKey)
      if (cur && cur.taskId === taskId) bridgeWake = true
    })
    return channel
  }
  const dropChannel = () => { try { channel?.close() } catch {}; channel = null }

  for (;;) {
    ctl = readDaemonControl(sessionKey)
    if (!ctl || ctl.pid !== process.pid) return       // dismissed or superseded
    if (Date.now() - (ctl.ts || 0) > CONTROL_TTL_MS) return
    if (ctl.agentPid && !pidAlive(ctl.agentPid)) return  // session closed

    // session → console
    let fresh
    try { fresh = tail.readNew() } catch { return }   // transcript gone
    pending.push(...fresh)
    while (pending.length && pending[0].index < cursor) pending.shift()
    if (pending.length > MAX_PENDING) pending.splice(0, pending.length - MAX_PENDING)
    if (pending.length && ctl.taskId) {
      let entries = []
      for (const { raw } of pending) {
        let obj
        try { obj = JSON.parse(raw) } catch { continue }
        const e = toEntry(obj)
        if (e) entries.push(e)
      }
      if (!known) {
        entries = entries.filter((e) => !e.ts || e.ts >= startTs - BACKFILL_GRACE_MS)
      }
      const nextCursor = pending[pending.length - 1].index + 1
      try {
        if (entries.length) {
          await forwardEntries(ctl.taskId, entries.slice(-MAX_LINES_PER_BATCH),
                               await ensureChannel())
        }
        cursor = nextCursor
        known = true
        writeCursor(sessionKey, cursor)
        pending.length = 0
      } catch (err) {
        if (String(err && err.message).includes('unknown_task')) return
        dropChannel()  // transient (Phi restarting): retry next tick
      }
    }

    // console → session
    if (bridgeWake || Date.now() - lastSweep >= MESSAGE_SWEEP_MS) {
      bridgeWake = false
      lastSweep = Date.now()
      try {
        const gone = await bridge.deliverPending(ctl, await ensureChannel())
        if (gone) return  // unknown task: ended
      } catch {
        dropChannel()
      }
    }

    // between-rounds keep-alive (see HEARTBEAT_MS)
    if (ctl.taskId && Date.now() - lastHeartbeat >= HEARTBEAT_MS) {
      lastHeartbeat = Date.now()
      try {
        const res = await (await ensureChannel()).send('agentSpace.ping', {
          taskId: ctl.taskId, ttlSeconds: HEARTBEAT_TTL_SECONDS,
        })
        if (res && res.ok === false) return  // task ended: exit, respawn re-creates
      } catch {
        dropChannel()
      }
    }

    await sleep(POLL_MS)
  }
}

/**
 * The console → session direction. Drains the app's queued console commands
 * and types them into the driving session's terminal, ONLY when:
 *   - the task is idle (a live round is expected to drain the queue itself —
 *     racing it would strand a waitForUserMessage on an empty queue), and
 *   - a terminal tab owning the agent's tty was located, and
 *   - the agent owns the tty foreground (never type into a bare shell).
 * When injection is unavailable the queue is left alone — the driver drains
 * it at its next round, the pre-bridge behavior. Commands are injected with
 * a "[phi-console]" prefix: the agent sees the provenance (answer via
 * narrate/console, not just the terminal), and the mirror suppresses the
 * echoed transcript line (the app already echoed the command at enqueue).
 */
class ConsoleCommandBridge {
  constructor() {
    this.injector = null      // resolved terminal app, probed lazily
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

    const tty = ttyOfPid(ctl.agentPid)
    if (!tty) return false
    if (!this.injector) {
      this.injector = probeTerminal(tty, ctl.termProgram || '')
      if (!this.injector) return false  // no permission/terminal: leave queued
    }
    if (!isForeground(ctl.agentPid)) return false

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
        injectText(this.injector, tty, `[phi-console] ${item.text}`)
        await sleep(300)  // separate Enter presses for queued commands
      } catch {
        item.attempts += 1
        if (item.attempts < MAX_INJECT_ATTEMPTS) {
          retry.push(item)
        } else {
          await forwardEntries(ctl.taskId, [{
            kind: 'error',
            text: 'Could not deliver your command to the agent’s terminal',
            detail: item.text.slice(0, 200),
          }], channel).catch(() => {})
        }
      }
    }
    this.undelivered = retry
    return false
  }
}

/**
 * Incremental transcript reader. Tracks a byte offset and a partial-line
 * remainder so each poll reads only appended bytes, and numbers complete
 * non-empty lines with the same absolute index the cursor counts (see
 * mirror-claude transcriptLines). A shrunken file (rotation) restarts from
 * zero — the cursor shift above then skips what was already forwarded.
 */
class TranscriptTail {
  constructor(path) {
    this.path = path
    this.offset = 0
    this.rest = ''
    this.seen = 0
  }

  /** New complete non-empty lines since the last call: [{index, raw}]. */
  readNew() {
    const size = statSync(this.path).size
    if (size < this.offset) { this.offset = 0; this.rest = ''; this.seen = 0 }
    if (size === this.offset) return []
    const fd = openSync(this.path, 'r')
    let chunk
    try {
      const buf = Buffer.alloc(size - this.offset)
      readSync(fd, buf, 0, buf.length, this.offset)
      this.offset = size
      chunk = this.rest + buf.toString('utf8')
    } finally {
      closeSync(fd)
    }
    const parts = chunk.split('\n')
    this.rest = parts.pop()  // incomplete tail (or '') waits for its newline
    const out = []
    for (const part of parts) {
      if (!part.trim()) continue
      out.push({ index: this.seen, raw: part })
      this.seen += 1
    }
    return out
  }
}
