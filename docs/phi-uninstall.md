# Phi Uninstall

Phi owns the user-facing uninstall flow. Sentinel retains its existing uninstall implementation,
but Phi does not call it or depend on it.

## Deletion scope

The uninstall action always removes the current channel's complete Phi and Sentinel data set and
the running Phi app:

- `~/Library/Application Support/<Phi bundle ID>`
- `~/Library/Caches/<Phi bundle ID>`
- `~/Library/Application Support/<Sentinel bundle ID>`
- `~/Library/Caches/<Sentinel bundle ID>`
- `~/Library/Preferences/<Phi bundle ID>.plist`
- `~/Library/Preferences/<Sentinel bundle ID>.plist`
- `~/Library/WebKit/<Phi bundle ID>` and `~/Library/WebKit/<Sentinel bundle ID>`
- The matching Phi and Sentinel entries under `~/Library/HTTPStorages`
- `~/Library/Application Support/com.phibrowser.TimeMachine/<Phi bundle ID>`
- `~/Library/Application Support/com.phibrowser.sentinel.TimeMachine/<Sentinel bundle ID>`
- `~/Library/Logs/PhiSentinel`, `PhiSentinel-Canary`, and `PhiSentinel-Dev`
- Phi's channel-specific Bitwarden session keychain item
- The verified running Phi `.app` bundle

Stable, Canary, and development data is isolated by bundle identifier. The shared app-group
container is intentionally retained because its contents cannot be safely attributed to one
channel. The shared Chromium Safe Storage key is also retained because deleting it could make a
sibling channel's encrypted profile unreadable. The independent Bitwarden desktop app and its data
are unrelated and are never touched.

## Shutdown and deletion sequence

1. The user chooses **Help > Uninstall Phi...**, directly below **Manage User Data**, and Phi
   presents one critical confirmation alert.
2. Phi verifies its own signed app bundle and prepares a private copy of the embedded uninstaller.
3. Phi unregisters Sentinel, stops the Sentinel watchdog, and requests Sentinel termination.
4. Phi launches the copied uninstaller and requests normal application termination so Chromium
   completes its shutdown without starting any deletion in-process.
5. The uninstaller waits for both Phi and the same-channel Sentinel to exit.
6. The uninstaller re-verifies the app signature, validates every filesystem, preferences, and
   keychain target against the channel allowlist, deletes the channel's data, checks that Phi did
   not restart, and deletes the app bundle in a separate final stage.

The copied helper is necessary because an executable inside the app bundle cannot reliably remove
its containing bundle while continuing the uninstall. Preparing and launching it before Phi exits
also allows startup failures to be reported while the UI still exists.

## Safety boundaries

- The helper accepts only `uninstall-plan.json` beside its copied executable in the private,
  current-user-owned `0700` workspace that Phi created directly under its temporary directory.
- The app bundle must have the expected Phi bundle identifier and team identifier.
- The deletion plan rejects filesystem roots, `~/Library`, shared data directories, other Phi
  channels, foreign preferences domains or keychain accounts, non-`.app` application targets,
  symlinks (including symlinked parents), paths that resolve outside the lexical allowlisted roots,
  and an app bundle that overlaps any data target.
- No deletion begins until both Phi and Sentinel are no longer running.
- Data deletion is best-effort, matching Sentinel's existing behavior. Failures are written to the
  unified system log, and the app-bundle stage still runs unless Phi has restarted.
- A failure before helper launch restores Sentinel according to the existing user preferences and
  leaves all data untouched.
