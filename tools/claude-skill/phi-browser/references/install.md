# phi-browser skill — setup

## 1. Install the skill

Easiest: in Phi Browser open **Settings → General → Developer**, under "Install
the phi-browser skill" click **Install** next to your agent — Claude Code
(`~/.claude/skills`), Codex (`~/.codex/skills`), or OpenClaw
(`~/.openclaw/skills`). This links the skill bundled inside the app into that
agent's `skills/phi-browser`, so it stays current with each Phi Browser update.

Or link it by hand from a source checkout (swap the destination for your agent):

```bash
ln -sfn /Users/jixiang/Phi/phibrowser-mac/tools/claude-skill/phi-browser ~/.claude/skills/phi-browser
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

Developer TCP override: launching the binary with `--remote-debugging-port=0`
(or `defaults write <bundle id> PhiRemoteDebuggingPort -int 0`, then relaunch)
still exposes a plain localhost CDP port with no per-agent consent — for raw
CDP debugging tools (chrome://inspect, Puppeteer). It has no authenticated
agent-Space surface, so the phi-browser skill does NOT use it: the skill always
requires the app socket above. Enabling the port does not enable the skill.

## 3. Verify

After enabling the toggle (no relaunch needed):

```bash
# The app writes the socket's path here; only this Mac's processes can reach it.
SOCK=$(head -1 ~/Library/Application\ Support/com.phibrowser.canary.Mac/CDPAgentSocket)
curl -s --unix-socket "$SOCK" http://localhost/json/version
```

The first request triggers the consent prompt — approve it in Phi, then the
JSON version blob prints. Then a smoke round:

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

## Troubleshooting

- **CDP endpoint not found**: the toggle isn't on for the bundle id actually
  running (canary vs release), so no `CDPAgentSocket` pointer file exists. Turn
  on Settings ▸ Developer ▸ Remote debugging (no relaunch). Set
  `PHI_USER_DATA_DIR` to override the user-data-dir candidates.
- **Access denied**: you (or a stale *Always Allow*) denied this agent. Approve
  the next prompt, or remove the agent under Settings ▸ Developer ▸ Remote
  debugging ▸ Remembered agents and reconnect to be asked again.
- **Endpoint not responding / first call hangs**: the first connection waits on
  the consent prompt — approve it in Phi. If it's genuinely stuck, toggle
  Remote debugging off and on to restart the listener.
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
