// Copyright 2026 Phinomenon Inc.
//
// Terminal injection for the two-way session mirror: delivers a command the
// user typed into Phi's Agent Transcript console INTO the driving code
// agent's own terminal, as if typed there — so a console command wakes an
// idle session instead of waiting for its next round. The tailer daemon
// calls this only while the task is IDLE (a live round drains the queue
// itself via readUserMessages/waitForUserMessage), and the injection is
// double-guarded:
//   - the target tab is located by the agent process's controlling TTY, so
//     text can only land in the terminal running THIS session;
//   - the agent process group must own the tty's foreground — if the user
//     is at a bare shell prompt (agent exited, ctrl-z, …) nothing is sent,
//     because the text would execute as a shell command.
// Requires macOS Automation permission (node → Terminal/iTerm2), prompted on
// the first probe. Denied permission, tmux, or an unsupported terminal just
// leaves messages queued for the driver's next readUserMessages() — the
// pre-injection behavior. Known edge: text the user is mid-typing in the
// agent's input box joins the injected line; rare enough to accept.
//
// Two delivery shapes, chosen by the caller per agent:
//   - one-shot (default): text + terminator in a single write. Claude
//     Code's, Pi's, and Hermes' inputs submit on the terminator.
//   - split (Codex): Codex's TUI reclassifies characters arriving ≤8ms
//     apart as a paste and turns an Enter within 120ms of the last one into
//     a literal newline instead of a submit (tui paste_burst.rs) — a
//     one-shot write therefore fills the composer and never sends. So:
//     write the body, wait out the suppress window, then send Enter as its
//     own keystroke. The Enter must be a CR (0x0D): Codex maps a raw-mode
//     LF to Ctrl+J = insert-newline. Both terminals deliver CR — iTerm2's
//     `write text` appends CR by construction, and Terminal.app's
//     `do script` terminator was probed as 0x0D.

import { execFileSync } from 'node:child_process'

// Comfortably past Codex's 120ms Enter-suppress window (re-armed per char).
const SUBMIT_DELAY_MS = 250

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function ps(args) {
  return execFileSync('/bin/ps', args, { encoding: 'utf8' }).trim()
}

/** The controlling terminal of `pid` as "ttys011", or null (no tty). */
export function ttyOfPid(pid) {
  try {
    const tty = ps(['-o', 'tty=', '-p', String(pid)])
    return tty && tty !== '??' ? tty : null
  } catch { return null }
}

/**
 * True when `pid`'s process group owns its terminal's foreground — i.e. the
 * agent is the program the user's keystrokes would reach right now.
 */
export function isForeground(pid) {
  try {
    const [pgid, tpgid] = ps(['-o', 'pgid=,tpgid=', '-p', String(pid)])
      .split(/\s+/).filter(Boolean).map(Number)
    return pgid > 0 && pgid === tpgid
  } catch { return false }
}

// Both scripts take (ttyName, mode[, text]): mode "probe" only locates the
// tab; "send" delivers text + terminator; "type" delivers the text alone
// where the terminal allows it (iTerm2 — Terminal.app's do script always
// appends its CR, which the split flow's paste-burst window absorbs as a
// harmless newline); "enter" delivers a lone CR. `application id … is
// running` is a plain property read — it never launches the app. Terminal's
// `do script … in tab` and iTerm2's `write text` both write to the tab's
// tty input, which the foreground program receives as typed input.
const TERMINAL_SCRIPT = `
on run argv
  set theTty to "/dev/" & item 1 of argv
  set theMode to item 2 of argv
  if application id "com.apple.Terminal" is not running then return "notrunning"
  tell application id "com.apple.Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is theTty then
          if theMode is "send" or theMode is "type" then
            do script (item 3 of argv) in t
          else if theMode is "enter" then
            do script "" in t
          end if
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "notfound"
end run`

const ITERM_SCRIPT = `
on run argv
  set theTty to "/dev/" & item 1 of argv
  set theMode to item 2 of argv
  if application id "com.googlecode.iterm2" is not running then return "notrunning"
  tell application id "com.googlecode.iterm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is theTty then
            if theMode is "send" then
              tell s to write text (item 3 of argv)
            else if theMode is "type" then
              tell s to write text (item 3 of argv) newline NO
            else if theMode is "enter" then
              tell s to write text ""
            end if
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "notfound"
end run`

const APPS = [
  { name: 'Terminal', script: TERMINAL_SCRIPT, hint: 'Apple_Terminal' },
  { name: 'iTerm2', script: ITERM_SCRIPT, hint: 'iTerm.app' },
]

function runScript(script, args) {
  // The first run blocks on the Automation consent prompt; the timeout keeps
  // the daemon healthy if it's ignored (probe again on the next message).
  return execFileSync('/usr/bin/osascript', ['-e', script, ...args],
                      { encoding: 'utf8', timeout: 20000 }).trim()
}

/**
 * Locates the terminal tab attached to `tty`. `termHint` (the driving
 * session's TERM_PROGRAM, recorded at spawn) orders the search. Returns the
 * app entry to pass to injectText, or null when no terminal owns the tty
 * (denied automation, tmux, an unsupported terminal).
 */
export function probeTerminal(tty, termHint = '') {
  const order = [...APPS].sort((a, b) =>
    (b.hint === termHint ? 1 : 0) - (a.hint === termHint ? 1 : 0))
  for (const app of order) {
    try {
      if (runScript(app.script, [tty, 'probe']) === 'ok') return app
    } catch {}  // not installed / permission denied
  }
  return null
}

/**
 * Types `text` into the tab holding `tty` and submits it. Default is one
 * write (text + terminator); `split: true` types the body, waits out the
 * paste-burst window, then presses Enter separately (see header — Codex).
 * Throws on failure.
 */
export async function injectText(app, tty, text, { split = false } = {}) {
  const line = String(text).replace(/\s*\n\s*/g, ' ').trim()
  if (!line) return
  const step = (mode, ...args) => {
    const res = runScript(app.script, [tty, mode, ...args])
    if (res !== 'ok') throw new Error(`inject failed: ${res}`)
  }
  if (!split) {
    step('send', line)
    return
  }
  step('type', line)
  await sleep(SUBMIT_DELAY_MS)
  step('enter')
}
