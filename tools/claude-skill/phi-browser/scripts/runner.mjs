#!/usr/bin/env node
// Copyright 2026 Phinomenon Inc.
//
// phi-browser heredoc runner: reads a script from stdin and executes it with
// all helpers in scope. Usage:
//   node runner.mjs <<'EOF'
//   const task = await ensureAgentSpace('my task')
//   cliLog(await snapshotText())
//   EOF

// The CDP client speaks WebSocket over the app's Unix socket with a
// hand-rolled frame codec (no global WebSocket needed), but still uses modern
// Node APIs throughout. Fail with the actual requirement instead of an obscure
// error from deep inside the first connect.
if (Number(process.versions.node.split('.')[0]) < 22) {
  console.error(
    `phi-browser: Node >= 22 required (running ${process.version})`)
  process.exit(2)
}

const { __dispose, ...surface } = await import('./lib/helpers.mjs')

// The heredoc body compiles as a plain async-function body inside this ES
// module: `import … from` statements can't appear there, and ESM has no
// ambient `require`. Provide one anchored at the caller's cwd, so
// require('node:fs') works and relative/node_modules lookups resolve the way
// a script run from that directory would.
const { createRequire } = await import('node:module')
const { join } = await import('node:path')
surface.require = createRequire(join(process.cwd(), '__phi-heredoc__.mjs'))

// A killed round (Bash-tool timeout, Ctrl-C) should still flip the Space's
// busy badge back to idle — best effort, the default handler would just die.
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    __dispose().catch(() => {}).finally(() => process.exit(130))
  })
}

let source = ''
process.stdin.setEncoding('utf8')
for await (const chunk of process.stdin) source += chunk

if (!source.trim()) {
  console.error('phi-browser: empty script on stdin')
  process.exit(2)
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const names = Object.keys(surface)
const values = names.map((n) => surface[n])

let exitCode = 0
try {
  const fn = new AsyncFunction(...names, source)
  await fn(...values)
} catch (err) {
  console.error(`phi-browser error: ${err?.message || err}`)
  // A few stack frames locate the failing line inside the heredoc (the
  // script compiles as an anonymous async function, so frames read
  // "<anonymous>:LINE"). Skip the message line already printed above.
  const frames = String(err?.stack || '')
    .split('\n').slice(1, 6).join('\n')
  if (frames) console.error(frames)
  exitCode = 1
} finally {
  await __dispose().catch(() => {})
}
process.exit(exitCode)
