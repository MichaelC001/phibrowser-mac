// Copyright 2026 Phinomenon Inc.
//
// Minimal dependency-free CDP client for Phi Browser (Node >= 22). The Phi app
// owns a Unix-domain socket, authenticates the connecting process, and injects
// the accepted connection into Chromium's DevTools server; agent-Space
// management/lifecycle is served by the app directly on the same socket
// (/phi-agent). This client discovers the socket from a pointer file the app
// writes and speaks HTTP + the CDP WebSocket over it. The `--remote-debugging
// -port` developer override exposes raw CDP for other tools but has no
// authenticated agent-Space surface, so the skill requires the socket.

import crypto from 'node:crypto'
import http from 'node:http'
import net from 'node:net'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const CANDIDATE_DIRS = [
  process.env.PHI_USER_DATA_DIR,
  join(homedir(), 'Library/Application Support/com.phibrowser.canary.Mac'),
  join(homedir(), 'Library/Application Support/com.phibrowser.Mac'),
].filter(Boolean)

// The consent prompt can hold the very first connection open while the user
// decides, so the first HTTP request tolerates a long wait.
const CONSENT_WAIT_MS = 180000

const NOT_FOUND_MESSAGE =
  'Phi Browser CDP endpoint not found. Turn on Settings ▸ Developer ▸ ' +
  'Remote debugging ▸ “Allow agents to control Phi (CDP)” (it applies ' +
  'immediately — no relaunch), then approve this agent when Phi asks. ' +
  'See references/install.md.'

const DENIED_MESSAGE =
  'Phi Browser denied this agent CDP access. Approve it in the Phi prompt ' +
  '(or remove it under Settings ▸ Developer ▸ Remote debugging ▸ ' +
  'Remembered agents and reconnect to be asked again).'

const TCP_ONLY_MESSAGE =
  'Phi Browser\'s --remote-debugging-port is on, but the phi-browser skill ' +
  'needs the app-owned socket: agent Spaces require authenticated access. ' +
  'Turn on Settings ▸ Developer ▸ Remote debugging ▸ “Allow agents to control ' +
  'Phi (CDP)”. The debugging port serves raw CDP tools only.'

/**
 * All plausible endpoints in precedence order — the PHI_USER_DATA_DIR
 * override, then canary, then stable: UDS pointers first (across ALL dirs),
 * then any `--remote-debugging-port` TCP override. A pointer or socket FILE
 * can outlive a crashed app (a crash skips the clean-quit unlink), so
 * existence is not liveness — callers walk the list and probe, see
 * discoverLiveEndpoint. Each entry is `{kind: 'uds', socketPath}` or
 * `{kind: 'tcp'}`.
 */
export function discoverEndpoints() {
  const out = []
  for (const dir of CANDIDATE_DIRS) {
    const pointer = join(dir, 'CDPAgentSocket')
    if (!existsSync(pointer)) continue
    const socketPath = readFileSync(pointer, 'utf8')
      .split('\n').map((l) => l.trim()).filter(Boolean)[0]
    if (socketPath && existsSync(socketPath)) {
      out.push({ kind: 'uds', socketPath })
    }
  }
  for (const dir of CANDIDATE_DIRS) {
    if (existsSync(join(dir, 'DevToolsActivePort'))) out.push({ kind: 'tcp' })
  }
  return out
}

/** True for errors meaning "this socket file has no listener behind it" —
 *  a crash-orphaned socket refuses instantly (a crash skips the clean-quit
 *  unlink), so walking on to the next candidate is safe. Anything else is a
 *  real answer from a live endpoint (denial, sandbox wall, timeout) and
 *  must propagate. NEVER probe with a naked connect(2) instead: a zero-byte
 *  connection reaches the app's serial consent pipeline as an unidentifiable
 *  peer — liveness is only checked with real, identified requests. */
export function isDeadSocketError(err) {
  return /ECONNREFUSED|ENOENT/.test(String(err?.message || err))
}

/** Legacy sync discovery: the first candidate by precedence, unprobed. */
export function discoverEndpoint() {
  const all = discoverEndpoints()
  if (all.length === 0) throw new Error(NOT_FOUND_MESSAGE)
  return all[0]
}

/**
 * The claim header carried on every connection to the app socket: names the
 * agent session this process acts for, so the app's consent prompt resolves
 * the AGENT even when the connecting process's ancestry no longer reaches it
 * (a hand-back watcher orphaned by a backgrounding shell, the detached mirror
 * daemon). Chromium-bound requests carry it too — DevTools ignores unknown
 * headers — so every connection of a round lands on the same identity and
 * grant. An identification aid like argv[0] branding, not a security
 * boundary: the app only honors a live same-user pid (see
 * AgentPeerIdentity.resolveClaimed).
 */
function agentPidHeader(agentPid) {
  return Number.isInteger(agentPid) && agentPid > 0
    ? { 'X-Phi-Agent-Pid': String(agentPid) }
    : {}
}

/** GETs a JSON document from the app socket over HTTP. */
function httpGetJson(endpoint, path, timeoutMs, agentPid = null) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { socketPath: endpoint.socketPath, path,
        headers: { Host: 'localhost', ...agentPidHeader(agentPid) } },
      (res) => {
      let body = ''
      res.setEncoding('utf8')
      res.on('data', (d) => { body += d })
      res.on('end', () => {
        if (res.statusCode === 403) { reject(new Error(DENIED_MESSAGE)); return }
        if (res.statusCode !== 200) {
          reject(new Error(`status ${res.statusCode}`)); return
        }
        try { resolve(JSON.parse(body)) } catch (e) { reject(e) }
      })
    })
    req.setTimeout(timeoutMs, () => req.destroy(new Error('timed out')))
    req.on('error', reject)
    req.end()
  })
}

/**
 * Confirms the endpoint is live and returns `{ browserWsPath }` — the resource
 * path for the browser-target WebSocket upgrade. This is the first connection,
 * so it may trigger (and wait on) the consent prompt.
 */
export async function verifyEndpoint(endpoint, { agentPid = null } = {}) {
  let version
  try {
    version = await httpGetJson(endpoint, '/json/version', CONSENT_WAIT_MS, agentPid)
  } catch (err) {
    if (err.message === DENIED_MESSAGE) throw err
    // Codex runs shell commands in a seatbelt sandbox that by default denies
    // ALL network syscalls — including connect() on Phi's unix socket, which
    // then fails in 0 ms. Phi itself is usually fine and toggling it cannot
    // help, so name the real fix instead of the generic toggle advice (which
    // otherwise loops forever: every retry hits the same sandbox wall).
    if (process.env.CODEX_SANDBOX_NETWORK_DISABLED
        || (process.env.CODEX_SANDBOX && /connect|EPERM|ENETDOWN/i.test(err.message))) {
      throw new Error(
        `This shell runs inside Codex's network-disabled sandbox, which ` +
        `blocks Phi's app socket (Phi itself is likely fine). Fix it on the ` +
        `Codex side: add "[sandbox_workspace_write]\nnetwork_access = true" ` +
        `to ~/.codex/config.toml, or re-run this command with escalated ` +
        `(unsandboxed) permissions. [${err.message}]`)
    }
    throw new Error(
      `Phi Browser CDP endpoint is not responding. Toggle it off and on in ` +
      `Settings ▸ Developer ▸ Remote debugging. [${err.message}]`)
  }
  // The browser advertises its target as ws://<host>/devtools/browser/<uuid>;
  // only the path matters (the transport is our socket, not that host:port).
  const wsUrl = version.webSocketDebuggerUrl || ''
  const browserWsPath = wsUrl ? new URL(wsUrl).pathname : ''
  if (!browserWsPath) {
    throw new Error('Phi Browser did not advertise a browser WebSocket target.')
  }
  return { browserWsPath }
}

/**
 * A minimal RFC 6455 client that speaks WebSocket over an already-connected
 * stream (a Unix-domain socket here). Kept dependency-free — it emulates just
 * the sliver of the WHATWG WebSocket surface CdpClient uses: addEventListener
 * for open/message/error/close, send(string), close(). Server frames arrive
 * unmasked; client frames are masked per spec. Text frames only (CDP is JSON),
 * with continuation reassembly and ping/pong handling.
 */
export class UnixWebSocket {
  constructor({ socketPath, path, host = 'localhost', agentPid = null }) {
    this._listeners = { open: [], message: [], error: [], close: [] }
    this._buf = Buffer.alloc(0)
    this._handshakeDone = false
    this._closed = false
    this._fragOpcode = 0
    this._fragChunks = []
    this._agentPid = agentPid
    this._openSocket(socketPath, path, host)
  }

  addEventListener(type, cb, opts = {}) {
    if (opts.once) {
      const wrap = (ev) => { this._off(type, wrap); cb(ev) }
      this._listeners[type].push(wrap)
    } else {
      this._listeners[type].push(cb)
    }
  }

  _off(type, cb) {
    const a = this._listeners[type]
    const i = a.indexOf(cb)
    if (i >= 0) a.splice(i, 1)
  }

  _emit(type, ev) {
    for (const cb of [...this._listeners[type]]) {
      try { cb(ev) } catch {}
    }
  }

  _openSocket(socketPath, path, host) {
    const key = crypto.randomBytes(16).toString('base64')
    this._sock = net.connect({ path: socketPath })
    this._sock.on('error', (e) => this._emit('error', { error: e }))
    this._sock.on('close', () => {
      if (!this._closed) { this._closed = true; this._emit('close', {}) }
    })
    // The claim header sits right after Host so it lands inside the app's
    // single request-head peek (see agentPidHeader / AgentCDPListener).
    const [claimName, claimValue] = Object.entries(agentPidHeader(this._agentPid))[0] ?? []
    this._sock.on('connect', () => {
      this._sock.write(
        `GET ${path} HTTP/1.1\r\n` +
        `Host: ${host}\r\n` +
        (claimName ? `${claimName}: ${claimValue}\r\n` : '') +
        `Upgrade: websocket\r\n` +
        `Connection: Upgrade\r\n` +
        `Sec-WebSocket-Key: ${key}\r\n` +
        `Sec-WebSocket-Version: 13\r\n\r\n`)
    })
    this._sock.on('data', (chunk) => this._onData(chunk))
  }

  _onData(chunk) {
    this._buf = Buffer.concat([this._buf, chunk])
    if (!this._handshakeDone) {
      const idx = this._buf.indexOf('\r\n\r\n')
      if (idx < 0) return
      const head = this._buf.slice(0, idx).toString('latin1')
      const statusLine = head.split('\r\n')[0]
      // The app echoes the agent pid it resolved for this connection on the
      // /phi-agent upgrade — the authoritative ancestry answer for a round
      // that cannot walk its own (see helpers.appProvidedAgentPid).
      const claim = /^x-phi-agent-pid:\s*(\d+)\s*$/im.exec(head)
      this.peerAgentPid = claim ? Number(claim[1]) : null
      if (!/ 101 /.test(statusLine)) {
        const denied = / 403 /.test(statusLine)
        this._emit('error', {
          error: new Error(denied ? DENIED_MESSAGE
                                  : `WebSocket upgrade failed: ${statusLine}`),
        })
        this.close()
        return
      }
      this._buf = this._buf.subarray(idx + 4)
      this._handshakeDone = true
      this._emit('open', {})
    }
    this._drainFrames()
  }

  _drainFrames() {
    while (true) {
      if (this._buf.length < 2) return
      const b0 = this._buf[0]
      const b1 = this._buf[1]
      const fin = (b0 & 0x80) !== 0
      const opcode = b0 & 0x0f
      const masked = (b1 & 0x80) !== 0
      let len = b1 & 0x7f
      let offset = 2
      if (len === 126) {
        if (this._buf.length < 4) return
        len = this._buf.readUInt16BE(2)
        offset = 4
      } else if (len === 127) {
        if (this._buf.length < 10) return
        len = this._buf.readUInt32BE(2) * 2 ** 32 + this._buf.readUInt32BE(6)
        offset = 10
      }
      let maskKey = null
      if (masked) {
        if (this._buf.length < offset + 4) return
        maskKey = this._buf.subarray(offset, offset + 4)
        offset += 4
      }
      if (this._buf.length < offset + len) return
      let payload = this._buf.subarray(offset, offset + len)
      if (masked) {
        const out = Buffer.allocUnsafe(len)
        for (let i = 0; i < len; i++) out[i] = payload[i] ^ maskKey[i & 3]
        payload = out
      } else {
        payload = Buffer.from(payload)
      }
      this._buf = this._buf.subarray(offset + len)
      this._handleFrame(fin, opcode, payload)
    }
  }

  _handleFrame(fin, opcode, payload) {
    if (opcode === 0x8) {            // close
      this._writeFrame(0x8, payload)
      this.close()
      return
    }
    if (opcode === 0x9) {            // ping -> pong
      this._writeFrame(0xa, payload)
      return
    }
    if (opcode === 0xa) return       // pong

    if (opcode === 0x0) {            // continuation
      this._fragChunks.push(payload)
    } else {                         // text (0x1) / binary (0x2)
      this._fragOpcode = opcode
      this._fragChunks = [payload]
    }
    if (!fin) return
    const full = Buffer.concat(this._fragChunks)
    this._fragChunks = []
    if (this._fragOpcode === 0x1) {
      this._emit('message', { data: full.toString('utf8') })
    }
  }

  send(str) {
    this._writeFrame(0x1, Buffer.from(str, 'utf8'))
  }

  _writeFrame(opcode, payload) {
    if (this._closed || !this._sock.writable) return
    const len = payload.length
    let header
    if (len < 126) {
      header = Buffer.allocUnsafe(2)
      header[1] = 0x80 | len
    } else if (len < 65536) {
      header = Buffer.allocUnsafe(4)
      header[1] = 0x80 | 126
      header.writeUInt16BE(len, 2)
    } else {
      header = Buffer.allocUnsafe(10)
      header[1] = 0x80 | 127
      header.writeUInt32BE(Math.floor(len / 2 ** 32), 2)
      header.writeUInt32BE(len >>> 0, 6)
    }
    header[0] = 0x80 | opcode        // FIN + opcode
    const mask = crypto.randomBytes(4)
    const masked = Buffer.allocUnsafe(len)
    for (let i = 0; i < len; i++) masked[i] = payload[i] ^ mask[i & 3]
    this._sock.write(Buffer.concat([header, mask, masked]))
  }

  close() {
    if (this._closed) return
    this._closed = true
    try { this._sock.end() } catch {}
    this._emit('close', {})
  }
}

export class CdpClient {
  /** `transport` is `{ socketPath, wsPath, agentPid? }` on the app socket. */
  constructor(transport) {
    this.transport = transport
    this.nextId = 1
    this.pending = new Map()
    this.listeners = []
  }

  async connect() {
    this.ws = new UnixWebSocket({ socketPath: this.transport.socketPath,
                                  path: this.transport.wsPath,
                                  agentPid: this.transport.agentPid ?? null })
    await new Promise((resolve, reject) => {
      this.ws.addEventListener('open', () => resolve(), { once: true })
      this.ws.addEventListener('error', (ev) =>
        reject(ev?.error instanceof Error
          ? ev.error
          : new Error('WebSocket failed to connect to Phi Browser')),
        { once: true })
    })
    this.ws.addEventListener('message', (ev) => this.#onMessage(ev.data))
    this.ws.addEventListener('close', () => {
      for (const [, p] of this.pending) {
        p.reject(new Error('CDP connection closed'))
      }
      this.pending.clear()
    })
    return this
  }

  #onMessage(data) {
    let msg
    try { msg = JSON.parse(data) } catch { return }
    if (msg.id) {
      const p = this.pending.get(msg.id)
      if (!p) return
      this.pending.delete(msg.id)
      if (msg.error) {
        p.reject(new Error(`${p.method}: ${msg.error.message}`))
      } else {
        p.resolve(msg.result ?? {})
      }
      return
    }
    if (msg.method) {
      for (const l of this.listeners) {
        if (l.method !== msg.method) continue
        if (l.sessionId !== undefined && l.sessionId !== msg.sessionId) continue
        try { l.fn(msg.params ?? {}, msg.sessionId) } catch {}
      }
    }
  }

  /** Sends a command. `sessionId` targets a flat-mode attached session. */
  send(method, params = {}, sessionId = undefined, timeoutMs = 40000) {
    const id = this.nextId++
    const payload = { id, method, params }
    if (sessionId) payload.sessionId = sessionId
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method}: timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      this.pending.set(id, {
        method,
        resolve: (v) => { clearTimeout(timer); resolve(v) },
        reject: (e) => { clearTimeout(timer); reject(e) },
      })
      this.ws.send(JSON.stringify(payload))
    })
  }

  /** Subscribes to an event. Pass sessionId to scope to one session.
   *  Returns an unsubscribe function (older callers may ignore it). */
  on(method, fn, sessionId = undefined) {
    const entry = { method, fn, sessionId }
    this.listeners.push(entry)
    return () => {
      const idx = this.listeners.indexOf(entry)
      if (idx >= 0) this.listeners.splice(idx, 1)
    }
  }

  /** Resolves on the first matching event, or rejects on timeout. */
  waitFor(method, predicate = () => true, timeoutMs = 20000, sessionId = undefined) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = this.listeners.indexOf(entry)
        if (idx >= 0) this.listeners.splice(idx, 1)
        reject(new Error(`timed out waiting for ${method}`))
      }, timeoutMs)
      const entry = {
        method,
        sessionId,
        fn: (params, sid) => {
          if (!predicate(params, sid)) return
          clearTimeout(timer)
          const idx = this.listeners.indexOf(entry)
          if (idx >= 0) this.listeners.splice(idx, 1)
          resolve(params)
        },
      }
      this.listeners.push(entry)
    })
  }

  close() {
    try { this.ws.close() } catch {}
    try { this.phi?.close() } catch {}
  }
}

/**
 * The `agentSpace.*` channel: management + task-lifecycle calls the Mac client
 * owns outright. Over the app's Unix socket these go DIRECT to Swift (see
 * DirectPhiChannel) instead of tunnelling out to Chromium and back. Both
 * variants expose the same `send(type, payload) -> responseObj` /
 * `onEvent(type, cb)` surface, so helpers.mjs doesn't care which is in play.
 */
export class DirectPhiChannel {
  constructor({ socketPath, agentPid = null }) {
    this.socketPath = socketPath
    this.agentPid = agentPid
    this.nextId = 1
    this.pending = new Map()
    this.listeners = []
  }

  async connect() {
    // The agent-session pid rides the upgrade URL — kept alongside the newer
    // X-Phi-Agent-Pid header (which every connection carries) so an app that
    // predates the header still resolves the daemon's consent identity from
    // the query (see AgentCDPListener.claimedAgentPid).
    const path = Number.isInteger(this.agentPid) && this.agentPid > 0
      ? `/phi-agent?agentPid=${this.agentPid}`
      : '/phi-agent'
    this.ws = new UnixWebSocket({ socketPath: this.socketPath, path,
                                  agentPid: this.agentPid })
    await new Promise((resolve, reject) => {
      this.ws.addEventListener('open', () => resolve(), { once: true })
      this.ws.addEventListener('error', (ev) =>
        reject(ev?.error instanceof Error
          ? ev.error
          : new Error('phi-agent channel failed to connect')),
        { once: true })
    })
    // The agent pid the app resolved for this connection (see _onData).
    this.peerAgentPid = this.ws.peerAgentPid ?? null
    this.ws.addEventListener('message', (ev) => this.#onMessage(ev.data))
    this.ws.addEventListener('close', () => {
      for (const [, p] of this.pending) p.reject(new Error('phi-agent channel closed'))
      this.pending.clear()
    })
    return this
  }

  #onMessage(data) {
    let msg
    try { msg = JSON.parse(data) } catch { return }
    if (msg.event) {
      let payload = {}
      try { payload = JSON.parse(msg.payloadJson || '{}') } catch {}
      for (const l of this.listeners) {
        if (l.type === msg.event) { try { l.cb(payload) } catch {} }
      }
      return
    }
    if (msg.id == null) return
    const p = this.pending.get(msg.id)
    if (!p) return
    this.pending.delete(msg.id)
    if (msg.error) { p.reject(new Error(`${p.type}: ${msg.error}`)); return }
    let parsed
    try { parsed = JSON.parse(msg.responseJson) } catch {
      p.reject(new Error(`${p.type}: unparseable app response: ${msg.responseJson}`))
      return
    }
    p.resolve(parsed)
  }

  send(type, payload = {}, timeoutMs = 40000) {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${type}: timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      this.pending.set(id, {
        type,
        resolve: (v) => { clearTimeout(timer); resolve(v) },
        reject: (e) => { clearTimeout(timer); reject(e) },
      })
      this.ws.send(JSON.stringify({ id, type, payloadJson: JSON.stringify(payload) }))
    })
  }

  onEvent(type, cb) {
    const entry = { type, cb }
    this.listeners.push(entry)
    return () => {
      const idx = this.listeners.indexOf(entry)
      if (idx >= 0) this.listeners.splice(idx, 1)
    }
  }

  close() { try { this.ws.close() } catch {} }
}

export async function connectBrowser({ agentPid = null } = {}) {
  const candidates = discoverEndpoints()
  if (candidates.length === 0) throw new Error(NOT_FOUND_MESSAGE)
  const uds = candidates.filter((c) => c.kind === 'uds')
  if (uds.length === 0) {
    // The --remote-debugging-port override has no authenticated agent-Space
    // surface, so the skill can't drive agent Spaces over it.
    throw new Error(TCP_ONLY_MESSAGE)
  }
  let lastErr = null
  for (const endpoint of uds) {
    let browserWsPath
    try {
      ({ browserWsPath } = await verifyEndpoint(endpoint, { agentPid }))
    } catch (err) {
      // A crashed app's leftover socket refuses instantly — walk on so a
      // dead canary pointer can never shadow a live stable Phi. Real
      // answers (denial, sandbox wall, no-WS) propagate.
      if (isDeadSocketError(err)) { lastErr = err; continue }
      throw err
    }
    const client = new CdpClient({ socketPath: endpoint.socketPath,
                                   wsPath: browserWsPath, agentPid })
    await client.connect()
    // Management + lifecycle go straight to the app over a second WS on the
    // same socket (/phi-agent); page automation stays on the Chromium
    // browser-target WS above.
    client.phi = await new DirectPhiChannel({ socketPath: endpoint.socketPath,
                                              agentPid }).connect()
    return client
  }
  throw lastErr ?? new Error(NOT_FOUND_MESSAGE)
}
