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
    { type: 'thinking', thinking: 'hmm' },
    { type: 'text', text: 'reply' },
    { type: 'tool_use', name: 'Bash', input: { command: 'git status' } }] } })
  check('claude: assistant record interleaves blocks', Array.isArray(a) && a.length === 3
        && a[0].kind === 'thinking' && a[0].text === 'hmm'
        && a[1].kind === 'assistant' && a[1].text === 'reply'
        && a[2].kind === 'tool' && a[2].text === 'Bash(git status)')
  check('claude: phi heredoc suppressed', claudeToEntry({ type: 'assistant',
    message: { content: [{ type: 'tool_use', name: 'Bash',
      input: { command: "node scripts/runner.mjs <<'EOF'\ngoto('x')\nEOF" } }] },
  }) === null)
  const edit = claudeToEntry({ type: 'assistant', message: { content: [
    { type: 'tool_use', name: 'Edit', input: { file_path: 'src/app.ts' } }] } })
  check('claude: edit titled like Claude Code', Array.isArray(edit)
        && edit[0].kind === 'tool' && edit[0].text === 'Update(src/app.ts)')
  const abs = claudeToEntry({ type: 'assistant', message: { content: [
    { type: 'tool_use', name: 'Read',
      input: { file_path: join(process.cwd(), 'src/x.ts') } }] } })
  check('claude: paths shown cwd-relative', Array.isArray(abs)
        && abs[0].text === 'Read(src/x.ts)')
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
  const started = codexToEntry({ type: 'event_msg',
    payload: { type: 'task_started', turn_id: 'turn-1' } })
  check('codex: task start becomes transient working state',
        started?.kind === 'activity' && started.text === 'working')
  const completed = codexToEntry({ type: 'event_msg',
    payload: { type: 'task_complete', turn_id: 'turn-1' } })
  check('codex: task completion becomes transient waiting state',
        completed?.kind === 'activity' && completed.text === 'waiting')
  const aborted = codexToEntry({ type: 'event_msg',
    payload: { type: 'turn_aborted', turn_id: 'turn-1' } })
  check('codex: aborted turn returns to waiting state',
        aborted?.kind === 'activity' && aborted.text === 'waiting')
  check('codex: response_item message skipped (no duplicates)', codexToEntry({
    type: 'response_item', payload: { role: 'user', content: 'x' } }) === null)
  check('codex: [phi-console] echo suppressed', codexToEntry({ type: 'event_msg',
    payload: { type: 'user_message', message: ' [phi-console] go' } }) === null)
  const th = codexToEntry({ type: 'event_msg',
    payload: { type: 'agent_reasoning', text: '**Scanning repo**' } })
  check('codex: reasoning becomes thinking', th?.kind === 'thinking'
        && th.text === '**Scanning repo**')
  const ran = codexToEntry({ type: 'response_item', payload: {
    type: 'function_call', name: 'shell',
    arguments: '{"command":["bash","-lc","git status"]}' } })
  check('codex: shell call titled like the TUI', ran?.kind === 'tool'
        && ran.text === 'Ran git status')
  check('codex: wait call is machinery', codexToEntry({ type: 'response_item',
    payload: { type: 'function_call', name: 'wait',
      arguments: '{"cell_id":"2"}' } }) === null)
  check('codex: wait_agent call defers to structured events', codexToEntry({
    type: 'response_item', payload: { type: 'function_call', name: 'wait_agent',
      arguments: '{"timeout_ms":30000}' } }) === null)
  const waitingOne = codexToEntry({ type: 'event_msg', payload: {
    type: 'collab_waiting_begin', receiver_thread_ids: ['thread-a'],
    receiver_agents: [{ thread_id: 'thread-a', agent_nickname: 'Newton',
      agent_role: 'worker' }] } })
  check('codex: single-agent wait matches the TUI title',
        waitingOne?.kind === 'tool' && waitingOne.text === 'Waiting for Newton [worker]'
        && waitingOne.detail === undefined)
  const waitingMany = codexToEntry({ type: 'event_msg', payload: {
    type: 'collab_waiting_begin', receiver_thread_ids: ['thread-a', 'thread-b'],
    receiver_agents: [
      { thread_id: 'thread-a', agent_nickname: 'Newton', agent_role: 'worker' },
      { thread_id: 'thread-b', agent_nickname: 'Kepler', agent_role: 'explorer' },
    ] } })
  check('codex: multi-agent wait includes indented agent details',
        waitingMany?.text === 'Waiting for 2 agents'
        && waitingMany.detail === 'Newton [worker]\nKepler [explorer]')
  const finishedWaiting = codexToEntry({ type: 'event_msg', payload: {
    type: 'collab_waiting_end', agent_statuses: [
      { thread_id: 'thread-a', agent_nickname: 'Newton', agent_role: 'worker',
        status: { completed: 'done' } },
      { thread_id: 'thread-b', agent_nickname: 'Kepler', agent_role: 'explorer',
        status: { errored: 'tool timeout' } },
    ], statuses: {} } })
  check('codex: wait completion includes final agent statuses',
        finishedWaiting?.kind === 'tool' && finishedWaiting.text === 'Finished waiting'
        && finishedWaiting.detail === 'Newton [worker]: Completed - done\n'
          + 'Kepler [explorer]: Error - tool timeout')
  check('codex: phi heredoc suppressed', codexToEntry({ type: 'response_item',
    payload: { type: 'custom_tool_call', name: 'exec',
      input: 'const r = await tools.exec_command({ cmd: "node /x/runner.mjs" })' },
  }) === null)
  const repl = codexToEntry({ type: 'response_item', payload: {
    type: 'custom_tool_call', name: 'exec',
    input: 'const r = await tools.exec_command({\n  cmd: "git log --oneline"\n})' } })
  check('codex: repl exec unwraps the real command', repl?.kind === 'tool'
        && repl.text === 'Ran git log --oneline')
  check('codex: repl cell plumbing is machinery', codexToEntry({
    type: 'response_item', payload: { type: 'custom_tool_call', name: 'exec',
      input: 'const r = await tools.write_stdin({ session_id: 1, chars: "" })' },
  }) === null)
  const plan = codexToEntry({ type: 'response_item', payload: {
    type: 'function_call', name: 'update_plan',
    arguments: '{"plan":[{"step":"scan","status":"completed"},'
      + '{"step":"fix","status":"pending"}]}' } })
  check('codex: update_plan cell', plan?.kind === 'tool' && plan.text === 'Updated Plan'
        && plan.detail === '✔ scan · ○ fix')
  const patch = codexToEntry({ type: 'response_item', payload: {
    type: 'function_call', name: 'apply_patch',
    arguments: JSON.stringify({
      input: '*** Begin Patch\n*** Update File: src/a.ts\n'
        + '*** Add File: src/b.ts\n*** End Patch' }) } })
  check('codex: apply_patch names its files', patch?.kind === 'tool'
        && patch.text === 'Edited src/a.ts (+1 more)')
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
  const a = piToEntry({ type: 'message', timestamp: '2026-07-17T03:00:00Z',
    message: { role: 'assistant', content: [
      { type: 'thinking', thinking: 'first thought' },
      { type: 'thinking', thinking: 'second thought' },
      { type: 'text', text: 'reply' },
      { type: 'toolCall', id: 'pi-bash-1', name: 'bash',
        arguments: { command: 'printf "1\\n2\\n3\\n4\\n5\\n6\\n7\\n"', timeout: 5 } },
    ] } })
  check('pi: assistant preserves native block order', Array.isArray(a) && a.length === 3
        && a[0].kind === 'thinking'
        && a[0].text === 'first thought\n\nsecond thought'
        && a[1].kind === 'assistant' && a[1].text === 'reply'
        && a[2].kind === 'tool')
  check('pi: bash call uses native title and pending card metadata',
        a[2].text === '$ printf "1\\n2\\n3\\n4\\n5\\n6\\n7\\n" (timeout 5s)'
        && a[2].sourceId === 'pi-bash-1' && a[2].toolState === 'pending')
  const bashResult = piToEntry({ type: 'message', timestamp: '2026-07-17T03:00:01.200Z',
    message: { role: 'toolResult', toolCallId: 'pi-bash-1', toolName: 'bash',
      isError: false, content: [{ type: 'text', text: '1\n2\n3\n4\n5\n6\n7' }] } })
  check('pi: bash result settles same card with collapsed tail and duration',
        bashResult?.sourceId === 'pi-bash-1' && bashResult.toolState === 'success'
        && bashResult.text.startsWith('$ printf')
        && bashResult.detail === '... (2 earlier lines, to expand)\n3\n4\n5\n6\n7\nTook 1.2s')

  const read = piToEntry({ type: 'message', message: { role: 'assistant', content: [
    { type: 'toolCall', id: 'pi-read-1', name: 'read',
      arguments: { path: 'src/app.ts', offset: 11, limit: 20 } }] } })
  check('pi: read call includes native line range', read?.text === 'read src/app.ts:11-30')
  const readResult = piToEntry({ type: 'message', message: { role: 'toolResult',
    toolCallId: 'pi-read-1', toolName: 'read', isError: false,
    content: [{ type: 'text', text: 'file contents stay collapsed' }] } })
  check('pi: successful read stays collapsed', readResult?.toolState === 'success'
        && readResult.detail === undefined)

  const write = piToEntry({ type: 'message', message: { role: 'assistant', content: [
    { type: 'toolCall', id: 'pi-write-1', name: 'write', arguments: {
      path: 'notes.txt', content: Array.from({ length: 12 }, (_, i) => `line ${i + 1}`).join('\n'),
    } }] } })
  check('pi: write card previews ten lines like Pi', write?.text === 'write notes.txt'
        && write.detail.includes('line 10\n... (2 more lines, 12 total, to expand)'))

  const edit = piToEntry({ type: 'message', message: { role: 'assistant', content: [
    { type: 'toolCall', id: 'pi-edit-1', name: 'edit',
      arguments: { path: 'src/app.ts', edits: [{ oldText: 'old', newText: 'new' }] } }] } })
  const editResult = piToEntry({ type: 'message', message: { role: 'toolResult',
    toolCallId: 'pi-edit-1', toolName: 'edit', isError: false, content: [],
    details: { diff: '  same\n-old\n+new' } } })
  check('pi: edit result settles card with native diff', edit?.text === 'edit src/app.ts'
        && editResult?.sourceId === 'pi-edit-1'
        && editResult.detail === '  same\n-old\n+new')

  const plumbing = piToEntry({ type: 'message', message: { role: 'assistant', content: [
    { type: 'toolCall', id: 'pi-phi-1', name: 'bash',
      arguments: { command: 'node tools/phi-browser-skill/scripts/runner.mjs' } }] } })
  check('pi: phi browser plumbing call is suppressed', plumbing === null)
  check('pi: matching plumbing result is suppressed', piToEntry({ type: 'message',
    message: { role: 'toolResult', toolCallId: 'pi-phi-1', toolName: 'bash',
      isError: false, content: [{ type: 'text', text: 'machinery' }] } }) === null)

  const length = piToEntry({ type: 'message', message: { role: 'assistant',
    content: [{ type: 'text', text: 'partial' }], stopReason: 'length' } })
  check('pi: length stop matches native error', Array.isArray(length)
        && length[0].kind === 'assistant' && length[1].kind === 'error'
        && length[1].text.includes('maximum output token limit'))
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
