#!/usr/bin/env node
// Copyright 2026 Phinomenon Inc.
//
// Self-test for the session mirror's agent adapters. Run after changing any
// scripts/lib/mirror-*.mjs:
//   node scripts/selftest-mirror.mjs
//
// Everything runs against fixtures — no Phi and no agents needed.
// Covers: each agent's toEntry parsing
// (echo suppression, machinery skipping), the SQLite tail source against
// throwaway databases shaped like Hermes'/OpenClaw's, the env-gated session
// discovery for the two SQLite agents, and OpenClaw's CLI delivery seam.
// Exits non-zero when any check fails.

import { mkdtempSync, rmSync, writeFileSync, readFileSync, chmodSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { toEntry as claudeToEntry } from './lib/mirror-claude.mjs'
import { toEntry as codexToEntry } from './lib/mirror-codex.mjs'
import { toEntry as piToEntry } from './lib/mirror-pi.mjs'
import {
  toEntry as hermesToEntry, hermesQuery, hermesRowToItem, discoverHermesTranscript,
} from './lib/mirror-hermes.mjs'
import {
  toEntry as openclawToEntry, openclawQuery, openclawRowToItem,
  discoverOpenclawTranscript, deliverOpenclaw,
} from './lib/mirror-openclaw.mjs'
import { SqliteTail } from './lib/mirror-sqlite.mjs'

const results = []
function check(name, ok, detail = '') {
  results.push({ name, ok: !!ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`)
}

const dir = mkdtempSync(join(tmpdir(), 'phi-mirror-selftest-'))
const sql = (db, stmt) => execFileSync('/usr/bin/sqlite3', [db, stmt], { encoding: 'utf8' })

// --- toEntry: Claude Code ------------------------------------------------------

{
  const e = claudeToEntry({ type: 'user', timestamp: '2026-07-17T03:00:00Z',
                            message: { content: 'hello there' } })
  check('claude: user string', e?.kind === 'user' && e.text === 'hello there' && e.ts > 0)
  check('claude: tool_result-only user is machinery', claudeToEntry({
    type: 'user', message: { content: [{ type: 'tool_result', content: 'x' }] },
  }) === null)
  const a = claudeToEntry({ type: 'assistant', message: { content: [
    { type: 'text', text: 'reply' }, { type: 'tool_use', name: 'Bash' }] } })
  check('claude: assistant text blocks only', a?.kind === 'assistant' && a.text === 'reply')
  check('claude: meta skipped', claudeToEntry({ type: 'user', isMeta: true,
    message: { content: 'x' } }) === null)
  check('claude: [phi-console] echo suppressed', claudeToEntry({ type: 'user',
    message: { content: '[phi-console] do it' } }) === null)
}

// --- toEntry: Codex ------------------------------------------------------------

{
  const u = codexToEntry({ type: 'event_msg', timestamp: '2026-07-17T03:00:00Z',
                           payload: { type: 'user_message', message: 'hello' } })
  check('codex: event_msg user', u?.kind === 'user' && u.text === 'hello')
  const a = codexToEntry({ type: 'event_msg',
                           payload: { type: 'agent_message', message: 'reply' } })
  check('codex: event_msg agent', a?.kind === 'assistant' && a.text === 'reply')
  check('codex: response_item skipped (no duplicates)', codexToEntry({
    type: 'response_item', payload: { role: 'user', content: 'x' } }) === null)
  check('codex: [phi-console] echo suppressed', codexToEntry({ type: 'event_msg',
    payload: { type: 'user_message', message: ' [phi-console] go' } }) === null)
}

// --- toEntry: Pi ---------------------------------------------------------------

{
  const u = piToEntry({ type: 'message', timestamp: '2026-07-17T03:00:00Z',
    message: { role: 'user', content: [
      { type: 'text', text: '<skill>doc doc</skill>\nreal prompt' }] } })
  check('pi: skill preamble stripped', u?.kind === 'user' && u.text === 'real prompt')
  check('pi: skill-only turn is machinery', piToEntry({ type: 'message',
    message: { role: 'user', content: [{ type: 'text', text: '<skill>doc</skill>' }] },
  }) === null)
  const a = piToEntry({ type: 'message', message: { role: 'assistant',
    content: [{ type: 'text', text: 'reply' }] } })
  check('pi: assistant text', a?.kind === 'assistant' && a.text === 'reply')
  check('pi: toolResult skipped', piToEntry({ type: 'message',
    message: { role: 'toolResult', content: [{ type: 'text', text: 'x' }] } }) === null)
}

// --- toEntry: Hermes -----------------------------------------------------------

{
  const u = hermesToEntry({ id: 5, role: 'user', content: 'hello', timestamp: 1752741600.5 })
  check('hermes: user row', u?.kind === 'user' && u.text === 'hello'
        && u.ts === Math.round(1752741600.5 * 1000))
  const a = hermesToEntry({ id: 6, role: 'assistant', content: 'reply' })
  check('hermes: assistant row', a?.kind === 'assistant' && a.text === 'reply')
  const m = hermesToEntry({ id: 7, role: 'user',
    content: '\x00json:[{"type":"text","text":"multi"},{"type":"image_url","image_url":{}}]' })
  check('hermes: multimodal keeps text blocks', m?.kind === 'user' && m.text === 'multi')
  check('hermes: broken multimodal skipped', hermesToEntry({ id: 8, role: 'user',
    content: '\x00json:not-json' }) === null)
  check('hermes: tool row skipped', hermesToEntry({ id: 9, role: 'tool',
    content: 'x' }) === null)
  check('hermes: [phi-console] echo suppressed', hermesToEntry({ id: 10,
    role: 'user', content: '[phi-console] go' }) === null)
}

// --- toEntry: OpenClaw ---------------------------------------------------------

{
  const u = openclawToEntry({ type: 'message', timestamp: '2026-07-17T03:00:00Z',
    message: { role: 'user', content: [{ type: 'text', text: 'hello' }] } })
  check('openclaw: user blocks', u?.kind === 'user' && u.text === 'hello' && u.ts > 0)
  const us = openclawToEntry({ type: 'message',
    message: { role: 'user', content: 'plain string', timestamp: 1752741600000 } })
  check('openclaw: user string content', us?.kind === 'user'
        && us.text === 'plain string' && us.ts === 1752741600000)
  const a = openclawToEntry({ type: 'message', message: { role: 'assistant',
    content: [{ type: 'thinking', thinking: 'hmm' }, { type: 'text', text: 'reply' },
              { type: 'toolCall', id: 't1', name: 'exec', arguments: {} }] } })
  check('openclaw: assistant text only', a?.kind === 'assistant' && a.text === 'reply')
  check('openclaw: toolResult skipped', openclawToEntry({ type: 'message',
    message: { role: 'toolResult', toolCallId: 't1', content: [] } }) === null)
  check('openclaw: session header skipped', openclawToEntry({ type: 'session',
    version: 3, id: 's1' }) === null)
  check('openclaw: compaction skipped', openclawToEntry({ type: 'compaction',
    summary: 's' }) === null)
  check('openclaw: [phi-console] echo suppressed', openclawToEntry({ type: 'message',
    message: { role: 'user', content: '[phi-console] go' } }) === null)
}

// --- SqliteTail: Hermes-shaped database ----------------------------------------

{
  const db = join(dir, 'state.db')
  sql(db, `CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT, role TEXT, content TEXT, timestamp REAL,
    active INTEGER DEFAULT 1);`)
  sql(db, `INSERT INTO messages (session_id, role, content, timestamp) VALUES
    ('s1','user','hello',1752741600.0),
    ('s1','assistant','reply',1752741601.0),
    ('s2','user','other session',1752741602.0),
    ('s1','tool','machinery',1752741603.0),
    ('s1','user','inactive',1752741604.0);`)
  sql(db, `UPDATE messages SET active = 0 WHERE content = 'inactive';`)
  const tail = new SqliteTail(db, (since) => hermesQuery('s1', since), hermesRowToItem)
  const first = tail.readNew()
  check('hermes tail: session+role filtered, ordered',
        first.length === 2 && first[0].index < first[1].index
        && JSON.parse(first[0].raw).content === 'hello'
        && JSON.parse(first[1].raw).content === 'reply',
        JSON.stringify(first.map((i) => i.index)))
  check('hermes tail: quiet when nothing new', tail.readNew().length === 0)
  sql(db, `INSERT INTO messages (session_id, role, content, timestamp) VALUES
    ('s1','user','again',1752741605.0);`)
  const second = tail.readNew()
  check('hermes tail: only appended rows', second.length === 1
        && JSON.parse(second[0].raw).content === 'again')
  let threw = false
  try { new SqliteTail(join(dir, 'missing.db'), () => '', () => null).readNew() }
  catch { threw = true }
  check('sqlite tail: missing db throws (transcript gone)', threw)
}

// --- SqliteTail + discovery + delivery: OpenClaw-shaped state dir ---------------

{
  const state = join(dir, 'openclaw-state')
  const db = join(state, 'agents', 'main', 'agent', 'openclaw-agent.sqlite')
  execFileSync('/bin/mkdir', ['-p', join(state, 'agents', 'main', 'agent')])
  sql(db, `CREATE TABLE sessions (session_id TEXT PRIMARY KEY,
    session_key TEXT NOT NULL, updated_at INTEGER);
    CREATE TABLE transcript_events (session_id TEXT NOT NULL, seq INTEGER NOT NULL,
    event_json TEXT NOT NULL, created_at INTEGER NOT NULL,
    PRIMARY KEY (session_id, seq));`)
  const now = Date.now()
  const ev = (o) => JSON.stringify(o).replace(/'/g, "''")
  sql(db, `INSERT INTO sessions VALUES
    ('sess-fresh','agent:main:main',${now}),
    ('sess-stale','agent:main:other',${now - 2 * 60 * 60 * 1000});`)
  sql(db, `INSERT INTO transcript_events VALUES
    ('sess-fresh',1,'${ev({ type: 'session', version: 3, id: 'sess-fresh' })}',${now}),
    ('sess-fresh',2,'${ev({ type: 'message', message: { role: 'user', content: 'open example.com' } })}',${now}),
    ('sess-fresh',3,'${ev({ type: 'message', message: { role: 'assistant', content: [
      { type: 'text', text: 'on it' },
      { type: 'toolCall', id: 't1', name: 'exec', arguments: { command: 'node runner.mjs task-abc123' } }] } })}',${now});`)

  const tail = new SqliteTail(db, (since) => openclawQuery('sess-fresh', since),
                              openclawRowToItem)
  const items = tail.readNew()
  const entries = items.map((i) => openclawToEntry(JSON.parse(i.raw))).filter(Boolean)
  check('openclaw tail: events → console lines', items.length === 3
        && entries.length === 2 && entries[0].kind === 'user'
        && entries[1].text === 'on it', JSON.stringify(entries))

  const env = { PHI_OPENCLAW_STATE_DIR: state, OPENCLAW_SHELL: 'exec' }
  const saved = {}
  for (const [k, v] of Object.entries(env)) { saved[k] = process.env[k]; process.env[k] = v }
  try {
    const hit = discoverOpenclawTranscript('task-abc123')
    check('openclaw discovery: evidence match', hit?.sessionKey === 'sess-fresh'
          && hit.path === db && hit.format === 'openclaw', JSON.stringify(hit))
    check('openclaw discovery: no evidence → no mirror',
          discoverOpenclawTranscript('task-elsewhere') === null)
    delete process.env.OPENCLAW_SHELL
    check('openclaw discovery: env gate', discoverOpenclawTranscript('task-abc123') === null)
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v
    }
  }

  // Delivery seam: a stub CLI proves argv shape and both exit paths.
  const okBin = join(dir, 'openclaw-ok')
  const argsFile = join(dir, 'openclaw-args')
  writeFileSync(okBin, `#!/bin/sh\nprintf '%s\\n' "$@" > ${argsFile}\nexit 0\n`)
  chmodSync(okBin, 0o755)
  const badBin = join(dir, 'openclaw-bad')
  writeFileSync(badBin, '#!/bin/sh\nexit 3\n')
  chmodSync(badBin, 0o755)
  process.env.PHI_OPENCLAW_BIN = okBin
  let delivered = false
  try { await deliverOpenclaw('sess-fresh', '[phi-console] hi'); delivered = true } catch {}
  const argv = delivered ? readFileSync(argsFile, 'utf8').trim().split('\n') : []
  check('openclaw delivery: CLI argv', delivered
        && argv.join(' ') === 'agent --session-id sess-fresh --message [phi-console] hi',
        argv.join(' '))
  process.env.PHI_OPENCLAW_BIN = badBin
  let rejected = false
  try { await deliverOpenclaw('sess-fresh', 'x') } catch { rejected = true }
  check('openclaw delivery: nonzero exit rejects (bridge retries)', rejected)
  delete process.env.PHI_OPENCLAW_BIN
}

// --- discovery: Hermes ---------------------------------------------------------

{
  const home = join(dir, 'hermes-home')
  execFileSync('/bin/mkdir', ['-p', home])
  sql(join(home, 'state.db'), 'CREATE TABLE messages (id INTEGER PRIMARY KEY);')
  const saved = { PHI_HERMES_HOME: process.env.PHI_HERMES_HOME,
                  HERMES_SESSION_ID: process.env.HERMES_SESSION_ID }
  process.env.PHI_HERMES_HOME = home
  process.env.HERMES_SESSION_ID = '20260717_120000_abc123'
  try {
    const hit = discoverHermesTranscript()
    check('hermes discovery: env session id', hit?.sessionKey === '20260717_120000_abc123'
          && hit.path === join(home, 'state.db') && hit.format === 'hermes')
    delete process.env.HERMES_SESSION_ID
    check('hermes discovery: env gate', discoverHermesTranscript() === null)
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v
    }
  }
}

// --- summary -------------------------------------------------------------------

rmSync(dir, { recursive: true, force: true })
const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
