# phi-browser skill — setup

## 1. Install the skill

Easiest: in Phi Browser open **Settings → General → Developer**, under "Install
the phi-browser skill" click **Install** next to your agent — Claude Code
(`~/.claude/skills`), Codex (`~/.codex/skills`), Cursor (`~/.cursor/skills`),
OpenClaw (`~/.openclaw/skills`), Pi (`~/.pi/agent/skills`), or Hermes
(`~/.hermes/skills`). This links the skill bundled inside the app into that
agent's `skills/phi-browser`, so it stays current with each Phi Browser update.
For Pi, Install also links a companion extension at
`~/.pi/agent/extensions/phi-browser`; run `/reload` in an already-open Pi
session so it can wake automatically when Agent Transcript receives a command.

Or link it by hand from the repository root (swap the skill destination for
another agent). Pi needs both links:

```bash
mkdir -p ~/.pi/agent/skills ~/.pi/agent/extensions
ln -sfn "$PWD/tools/phi-browser-skill" ~/.pi/agent/skills/phi-browser
ln -sfn "$PWD/tools/phi-browser-skill/extensions/pi" ~/.pi/agent/extensions/phi-browser
```

Requires Node >= 22. No npm dependencies.

## 2. Enable agent CDP access (one-time, in Settings)

The endpoint is OFF by default. Turn it on in **Settings ▸ Developer ▸ Remote
debugging ▸ "Allow agents to control Phi (CDP)"**. It applies immediately —
**no relaunch** — because the Phi app itself owns the socket and starts or
stops it live with the toggle.

How it works, and why it's safe:

- Phi opens a **Unix-domain socket** (not a TCP port), so nothing on the
  network — and no other user's processes — can reach it.
- The first time a given agent connects, Phi identifies the connecting process
  (peer credentials + code signature) and shows a **consent prompt**: *Allow
  Once*, *Always Allow*, or *Deny*. Only after you allow does the connection
  reach the browser.
- *Always Allow* is remembered per agent under **Settings ▸ Developer ▸ Remote
  debugging ▸ Remembered agents**; **Remove** there makes that agent ask again.
- Turning the toggle off stops new connections and severs any live ones at
  once.

## 3. Verify

After enabling the toggle (no relaunch needed):

```bash
# The app writes the socket's path here; only this Mac's processes can reach it.
SOCK=$(head -1 ~/Library/Application\ Support/com.phibrowser.canary.Mac/CDPAgentSocket)
curl -s --unix-socket "$SOCK" http://localhost/json/version
```

The first request triggers the consent prompt — approve it in Phi, then the
JSON version blob prints. Then a smoke round (swap `~/.claude/skills` for
your agent's skills folder):

```bash
node ~/.claude/skills/phi-browser/scripts/runner.mjs <<'EOF'
const task = await ensureAgentSpace('smoke test')
cliLog(task)
await openTab('https://example.com')
cliLog(await pageInfo())
EOF
```

A robot (🤖) Space pip with a pulsing badge appears in the Space switcher;
click it to watch the agent live.

For a full functional pass (skill development), run the self-test instead —
it drives a throwaway hidden Space against a local HTTP server, ~60s:

```bash
node ~/.claude/skills/phi-browser/scripts/selftest.mjs
```

For an eyes-on check of what a WATCHING user sees — the handoff prompt and
the mirrored input animations (cursor glides, click ripples, paced typing,
scrolling) — run the interactive demo and follow its terminal instructions:
it hands you control, and performs every input primitive on a local demo
page once you click "Hand back" (~2 min of your attention):

```bash
node ~/.claude/skills/phi-browser/scripts/selftest-animations.mjs
```

## 4. Session mirror (automatic, two-way)

The Agent Transcript panel (View ▸ Agent Transcript) always shows the browser
action steps, narration, rounds, and lifecycle. Under all six supported
agents — Claude Code, Codex, OpenClaw, Pi, Hermes, and Cursor — the driving
session is ALSO mirrored automatically, in both directions, with no setup:
`ensureAgentSpace` locates the session's own transcript and spawns a small
tailer daemon (`scripts/mirror-tailer.mjs`). Discovery is per agent,
mirroring nothing rather than guessing wrong:

- **Claude Code** — exact, by the exported `CLAUDE_CODE_SESSION_ID`
  (transcript JSONL under `~/.claude/projects`).
- **Hermes** — exact, by the exported `HERMES_SESSION_ID`; the transcript is
  rows in `~/.hermes/state.db` (SQLite), polled read-only.
- **Codex** — by thread id when `CODEX_THREAD_ID` is exported, else by a
  rollout heuristic (fresh rollout whose recorded cwd matches and whose tail
  mentions the task).
- **OpenClaw** — by evidence over the gateway's per-agent session
  transcripts (`~/.openclaw/agents/*/sessions/<sessionId>.jsonl`): the
  freshly-written transcript whose newest events mention the task. Assumes
  the gateway runs on this Mac.
- **Pi** — by the same evidence heuristic over its session files.
- **Cursor** — by the strongest evidence its transcripts offer: the IDE
  records the agent's Shell command — the skill heredoc itself — in
  `~/.cursor/projects/<project>/agent-transcripts/<id>/<id>.jsonl` before
  the shell runs, so the freshly written transcript containing this exact
  round's script is the session. (Tool outputs are not recorded there, so
  the task-id evidence the other heuristics use can never appear.)

The mirror then

- forwards your prompts and the assistant's reply prose into the Space's
  console while the task is live, and
- delivers commands you type into the console back INTO the idle session
  (prefixed `[phi-console]`) where the agent has a delivery transport. Pi's
  installed companion extension calls its supported in-process
  `pi.sendUserMessage()` API, which wakes the session immediately. OpenClaw
  uses `openclaw agent --session-id … --message …` through its gateway.
  Hermes is resumed headless (`hermes --resume <session-id> -z …`) — the
  woken turn appends to the same session in state.db and mirrors back into
  the console (an interactive TUI open on that session shows the exchange
  only after its next reload). The remaining agents — Claude Code, Codex,
  and Cursor — have no transport, so their commands stay queued until the
  next round drains them via `readUserMessages()`; under Cursor the console
  additionally posts a notice saying so, because an ended Cursor turn never
  runs another round until you prompt Cursor again.

The daemon exits on its own when the task completes, when the session goes
quiet for 30 minutes, when the agent process exits, or when the task
disappears. Set `PHI_NO_SESSION_MIRROR=1` in the environment to opt out.

Under other agents, call `say('…')` from a heredoc to reflect your own prose
into the console manually — `say(text, {role:'user'})` echoes a user line;
`narrate(text)` doubles as narration + the overlay pill.

After changing any mirror code, run its fixture selftest (no Phi or agents
needed): `node scripts/selftest-mirror.mjs`.

## Troubleshooting

- **CDP endpoint not found**: the toggle isn't on for the bundle id actually
  running (canary vs release), so no `CDPAgentSocket` pointer file exists. Turn
  on Settings ▸ Developer ▸ Remote debugging (no relaunch). Set
  `PHI_USER_DATA_DIR` to override the user-data-dir candidates.
- **Console shows browser steps but not the conversation**: the session
  couldn't be identified (Claude Code: update the CLI so it exports
  `CLAUDE_CODE_SESSION_ID`; Hermes: the session must export
  `HERMES_SESSION_ID` — the classic CLI does; Codex/OpenClaw/Pi/Cursor: the
  evidence heuristic found no match — or use `say()`), the transcript store
  isn't where discovery looks (`PHI_CODEX_SESSIONS_DIR`, `PHI_HERMES_HOME`,
  `PHI_OPENCLAW_STATE_DIR`, `PHI_CURSOR_STATE_DIR`,
  `PI_CODING_AGENT_SESSION_DIR` override the roots),
  `PHI_NO_SESSION_MIRROR` is set, or the skill running your heredocs
  predates the session mirror — rebuild Phi so the bundled skill has it.
- **Under Pi: console commands wait for “continue”**: the companion extension
  is not loaded. Install Pi again from Phi settings, then run `/reload` in Pi.
  The skill link alone can mirror the transcript but cannot call Pi's
  in-process `sendUserMessage()` API.
- **Console commands don't reach another terminal agent's idle session**:
  Claude Code, Codex, and Cursor have no supported delivery transport, so
  commands are picked up at the next round rather than typed into a
  terminal.
- **Under Cursor: console commands answer with a "queued" notice**: that is
  the designed behavior, not a failure. Cursor's IDE agent has no ingress
  an outside process may use (deeplinks open new chats, its app-control
  MCP has no message tool, and the cursor-agent CLI keeps a separate
  session store), so nothing can wake an ended Cursor turn. A command sent
  while the agent is still working arrives at its next phi-browser step;
  after the turn ends, send Cursor any message and it will read the queue
  at the start of that round.
- **Under OpenClaw: console commands stay queued**: the daemon delivers via
  the `openclaw` CLI — it must be installed (PATH, `~/.local/bin`, or set
  `PHI_OPENCLAW_BIN`) and able to reach your gateway. Check
  `openclaw agent --session-id <id> --message test` by hand.
- **Under Hermes: console commands stay queued**: the daemon delivers via
  the `hermes` CLI — it must be installed (PATH, `~/.local/bin`, or set
  `PHI_HERMES_BIN`). Check `hermes --resume <session-id> -z test` by hand.
- **Access denied**: you (or a stale *Always Allow*) denied this agent. Approve
  the next prompt, or remove the agent under Settings ▸ Developer ▸ Remote
  debugging ▸ Remembered agents and reconnect to be asked again.
- **Endpoint not responding / first call hangs**: the first connection waits on
  the consent prompt — approve it in Phi. If it's genuinely stuck, toggle
  Remote debugging off and on to restart the listener.
- **Empty reply from `/json/version` (older builds)**: a lingering
  `PhiRemoteDebuggingPort` default moved CDP onto its retired TCP transport
  and off the app socket, so connections were dropped without a reply. Run
  `defaults delete <bundle id> PhiRemoteDebuggingPort` and relaunch; current
  builds ignore and purge that default at startup.
- **Under Codex: "network-disabled sandbox" / endpoint not responding on
  every attempt**: Codex's default seatbelt sandbox denies all network
  syscalls, which includes connecting to Phi's unix socket — Phi is fine and
  toggling it changes nothing. Allow network in Codex's workspace sandbox:

  ```toml
  # ~/.codex/config.toml
  [sandbox_workspace_write]
  network_access = true
  ```

  or approve escalated (unsandboxed) execution when Codex asks.
- **"No Phi app connection available"**: the CDP endpoint is up but the Mac
  client's message router has no registered connection to the framework (the
  `PhiAgentSpace` domain tunnels every `agentSpace.*` call through it). Seen
  right after launch before any window exists, or when the app side is
  stopped or half-initialized (e.g. a paused Xcode debug session, or local
  changes to the embedded-extension launch flags — the router rides that
  infrastructure). Open a Phi window and retry; if it persists, relaunch
  Phi Browser. Distinct from "unknown method" below, which means the
  framework itself is too old.
- **"PhiAgentSpace.sendMessage" unknown method**: the running Phi Framework
  predates the PhiAgentSpace domain. Rebuild it:
  `autoninja -C out/PhiRelease "Phi Framework.framework"` in chromium/src,
  then rebuild/relaunch the Swift app (scheme PhiBrowser-canary).
- **create_failed from ensureAgentSpace**: no browser window is open yet —
  open one Phi window first, then retry.
