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

/** One transcript JSONL object → a console line, or null to skip. */
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
    const texts = msg.content.filter((b) => b && b.type === 'text' && b.text
      && b.text.trim()).map((b) => b.text)
    return texts.length ? { kind: 'assistant', text: texts.join('\n\n'), ts } : null
  }

  return null
}

/**
 * A console command the daemon injected into the terminal comes back around
 * as a user prompt carrying this marker — the app already echoed it in the
 * console at enqueue time, so mirroring it again would duplicate the line.
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
