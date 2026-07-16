// Copyright 2026 Phinomenon Inc.
//
// Claude Code transcript parsing for the session mirror (the tailer daemon,
// scripts/mirror-tailer.mjs). Kept separate from the agent-neutral core so
// a Codex/Pi sibling supplies its own parsing and reuses everything else.

import { readFileSync } from 'node:fs'

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
