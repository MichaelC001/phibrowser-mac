// Copyright 2026 Phinomenon Inc.
//
// Claude Code adapter for the session mirror (the tailer daemon,
// scripts/mirror-tailer.mjs): session discovery and transcript parsing.
// Kept separate from the agent-neutral core so each agent's sibling
// (mirror-codex, -pi, -hermes, -openclaw) supplies only these two pieces
// and reuses everything else.

import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

/**
 * The driving Claude Code session's transcript, or null. Exact: Claude Code
 * exports its session id to every shell command, and the transcript path is
 * located by session id across project dirs rather than by deriving the
 * munged cwd folder name — immune to the munging rules changing.
 */
export function discoverClaudeTranscript() {
  const sessionId = process.env.CLAUDE_CODE_SESSION_ID
  if (!sessionId) return null
  try {
    const projects = join(homedir(), '.claude', 'projects')
    for (const dir of readdirSync(projects)) {
      const path = join(projects, dir, `${sessionId}.jsonl`)
      if (existsSync(path)) return { sessionKey: sessionId, path, format: 'claude' }
    }
  } catch {}
  return null
}

/**
 * One transcript JSONL object → console line(s): a single entry, an array
 * (an assistant record interleaves thinking, prose, and tool calls in block
 * order), or null to skip.
 */
export function toEntry(obj) {
  if (!obj || obj.isMeta) return null
  const msg = obj.message
  const ts = Date.parse(obj.timestamp || '') || undefined

  if (obj.type === 'user' && msg) {
    const content = msg.content
    if (typeof content === 'string') {
      return content.trim() ? userEntry(content, ts) : null
    }
    if (Array.isArray(content)) {
      // A user turn that is purely tool_result is machinery, not a prompt.
      const texts = content.filter((b) => b && b.type === 'text' && b.text)
        .map((b) => b.text)
      return texts.length ? userEntry(texts.join('\n\n'), ts) : null
    }
    return null
  }

  if (obj.type === 'assistant' && msg && Array.isArray(msg.content)) {
    const out = []
    for (const b of msg.content) {
      if (!b) continue
      if (b.type === 'text' && b.text && b.text.trim()) {
        out.push({ kind: 'assistant', text: b.text, ts })
      } else if (b.type === 'thinking' && b.thinking && b.thinking.trim()) {
        out.push({ kind: 'thinking', text: b.thinking, ts })
      } else if (b.type === 'tool_use') {
        const e = toolEntry(b, ts)
        if (e) out.push(e)
      }
    }
    return out.length ? out : null
  }

  return null
}

// The phi heredocs that drive the browser are already narrated line-by-line
// by the skill's own action log; mirroring the Bash call too would double
// every step.
const PHI_PLUMBING = /runner\.mjs|phi-browser/

/**
 * A tool_use block → the console line Claude Code itself shows for it
 * ("Bash(git status)", "Update(src/app.ts)", "Search(pattern)"), or null
 * for skill plumbing.
 */
function toolEntry(block, ts) {
  const name = block.name || 'Tool'
  const input = block.input || {}
  switch (name) {
    case 'Bash': {
      const cmd = String(input.command || '')
      if (PHI_PLUMBING.test(cmd)) return null
      return tool(`Bash(${condense(cmd)})`, ts)
    }
    case 'Read': return tool(`Read(${condense(shortPath(input.file_path))})`, ts)
    case 'Write': return tool(`Write(${condense(shortPath(input.file_path))})`, ts)
    case 'Edit': return tool(`Update(${condense(shortPath(input.file_path))})`, ts)
    case 'Grep': return tool(`Search(${condense(input.pattern)})`, ts)
    case 'Glob': return tool(`Search(${condense(input.pattern)})`, ts)
    case 'Task': return tool(`Task(${condense(input.description || '')})`, ts)
    case 'WebFetch': return tool(`Fetch(${condense(input.url)})`, ts)
    case 'WebSearch': return tool(`Web Search(${condense(input.query)})`, ts)
    case 'TodoWrite': return tool('Update Todos', ts)
    case 'Skill': return tool(`Skill(${condense(input.skill)})`, ts)
    default: {
      let args = ''
      try { args = JSON.stringify(input) } catch {}
      return tool(`${name}(${condense(args === '{}' ? '' : args)})`, ts)
    }
  }
}

function tool(text, ts) {
  return { kind: 'tool', text, ts }
}

/**
 * Claude Code prints paths relative to the working directory (or ~-abbreviated);
 * the daemon runs in the driving session's cwd, so the same trim applies here.
 */
function shortPath(value) {
  const s = String(value ?? '')
  const cwd = process.cwd()
  if (s.startsWith(`${cwd}/`)) return s.slice(cwd.length + 1)
  const home = homedir()
  if (s.startsWith(`${home}/`)) return `~${s.slice(home.length)}`
  return s
}

/** First non-empty line, whitespace collapsed, capped for a title slot. */
function condense(value, max = 120) {
  const line = String(value ?? '').split('\n').map((l) => l.trim())
    .find((l) => l) || ''
  const s = line.replace(/\s+/g, ' ')
  return s.length > max ? `${s.slice(0, max)}…` : s
}

/**
 * A user prompt carrying the "[phi-console]" marker is a console command
 * delivered into the session — the app already echoed it in the console at
 * enqueue time, so mirroring it again would duplicate the line.
 */
function userEntry(text, ts) {
  if (text.trimStart().startsWith('[phi-console]')) return null
  return { kind: 'user', text, ts }
}

/**
 * The transcript's non-empty lines. The session cursor counts EXACTLY these
 * (see mirror-core readCursor) — a reader that counts lines differently
 * would corrupt the cursor, so readers go through here or replicate this
 * filter precisely (the tailer's incremental reader does).
 */
export function transcriptLines(path) {
  return readFileSync(path, 'utf8').split('\n').filter((l) => l.trim())
}
