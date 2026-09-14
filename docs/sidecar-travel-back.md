# Sidecar browser-scene restoration

Date: 2026-09-09. Updated: 2026-09-14. Status: same-Profile integration verified;
extended lifecycle acceptance remains outstanding.

## Independent integration (2026-09-14)

The owner approved publishing the committed same-Profile stage without taking
ongoing cross-Profile/isolation changes from either source worktree. This replays
`b04a028a` onto dev `2621fb7a`, paired with phi-ai `f7a19df42` integrated onto
staging `b0dd0f8b7`. The Xcode project retains dev's SiteMemory router registration
alongside the new Travel Back files. Cross-Profile handoff, Space-identity
reopening, runtime-identity hints and standalone Phi Chat restoration are not
part of this stage.

The integrated Canary `build-for-testing` passed with signing disabled and a
command-local Xcode developer directory. All eight pure policy tests passed in
an isolated SwiftPM fixture linked to the actual policy/test files. The paired
Sidecar passed 962 tests, 10 metadata tests, 37 root type-check tasks, changed-file
lint/format and its build. No browser was launched or installed. Coordinate
native, Sidecar and phi-agent registry-v2 delivery; do not replace a local
Profile-isolation/registry-v3 setup with this earlier stage. Full lifecycle and
first-paint acceptance remain outstanding.

## Decision and ownership

Travel Back restores the page and the two-pane split recorded by a conversation.
The owner chose full page/order/orientation/ratio/focus restoration, preserving
conflicting current work by opening a new pair instead of dismantling it.
Browser and Sidecar ship together; the new flow has no old-browser probe or
mutation fallback. Existing `toggleChatSidebar` callers remain unchanged.

`ExtensionMessageRouter` authenticates/translates the UI request;
`BrowserState+TravelBack` owns window/tab/split/sidebar lifecycle. The pure
`TravelBackScene` policy owns validation and anchor/conflict selection. Existing
`aiChatTabs` and `chatIdentifier(for:)` remain the only sidebar ownership model.
The resolver now includes in-flight creation keys so two split panes cannot
request independent Sidecars while the shared one is still being created.

This is a trusted built-in UI operation, not the external-agent automation API.
It does not expose arbitrary tab commands or bypass agent permission checks for
CDP callers. Conversation identity/content never enter the native restore API;
Sidecar retains conversation selection, session storage and acknowledgement.

## Message contract

All messages use existing `sendMessageToApp(type, payload, {timeout})` and one
request-scoped reply through `ExtensionMessaging`, never a broadcast reply.
Common fields: `profileId`, `windowId` (the current normal browser window), and
optional `boundTabId` (the sender Sidecar's fixed URL binding).

| Type | Additional input | Success `result` |
| --- | --- | --- |
| `sidecar.travelBack.snapshot` | none | page, active tab, window/profile, optional split geometry, live `relatedTabIds` |
| `sidecar.travelBack.restore` | `snapshot` | destination tab/window, actual `sidebar`, optional `sourceSidebar`, `sameSidecar` |
| `sidecar.travelBack.closeSource` | `sourceSidebar`, `destinationSidebar` | `{}` after exact-instance collapse, or no-op when the source binding disappeared |

A sidebar reference is `{windowId, chatTabId, boundTabId}`. `chatTabId` is the
actual sidebar WebContents ID; `boundTabId` is parsed from its fixed URL. That
URL can still name a closed pane after the shared Sidecar migrates to its
survivor. Source resolution follows `aiChatTabs` back to its live owner; while
its split is focused, capture selects the focused pane rather than the original
URL-bound pane. The receiver's handoff key must use this returned `boundTabId`,
not the restored content tab ID. Equal source/destination references require an
in-place return with no handoff, close or source reset.

Replies are `{ok:true,result:...}` or `{ok:false,error:<code>}`. Codes are
`unauthorized_sender`, `invalid_snapshot`, `unavailable`, `target_changed`,
`busy`, and `timed_out`; messages do not echo payloads/URLs. Native preparation
confirms lifecycle state, not page load, React conversation selection or paint.

Snapshot split data is `{members:[PageRef,PageRef],orientation,ratio,activeIndex}`.
Orientation names the divider: `vertical` is left/right, `horizontal` top/bottom.
Ratio is the primary pane's share, strictly between zero and one. The old
members-only format defaults at restore to vertical/0.5 and the pane matching
the recorded page, or first if ambiguous. Capture never persists a filtered
partial split. URLs must be valid HTTP(S) URLs; the payload is limited to 64 KiB.
Live `relatedTabIds` are only for event routing and are not persisted. The
versioned storage schema belongs to phi-ai `shared-types/chat-metadata.ts`.

## Trust boundary and exclusions

Only the exact built-in Sidecar ID is accepted. Debug/CDP, unattributed and
other extension senders are refused before window lookup. Windows must be live,
authenticated, AI-enabled ordinary user windows with the declared profile;
incognito, kiosk, agent and placeholder windows are excluded. The recorded
Profile does not select a different live Profile: reopening uses the caller's
current one. Candidate tabs are searched only within that declared scope.

**The bridge does not authenticate the sender's Profile.** The owner explicitly
accepted the existing trusted-Sidecar model for this feature. A declared Profile
is a consistency check, not proof against a compromised Sidecar. Strong source
Profile isolation requires trusted Chromium sender context in a separate change.

Standalone Phi Chat uses an isolated dedicated Profile; its restore action is
disabled in Sidecar, including an imperative pre-window-access guard. It cannot
share the profile-local session handoff with user-profile Sidecars. Enabling it
requires an explicit target-Profile and cross-Profile conversation protocol.
A workspace page in an ordinary user Profile remains supported.

No scroll/form restoration, tab-group organization, pin/bookmark restoration or
Space-ID lookup is added. AI policy and sidebar/extension-panel mutual exclusion
remain native. The low-level explicit open is performed only after the target
is resolved and its normal web surface selected (which clears group overview).

## Lifecycle, latency and recovery

1. Prefer the current sidebar page when its full URL matches; otherwise use the
   recorded live tab ID. Never search unrelated tabs by URL. With no anchor,
   create a new page/pair in the current normal window.
2. Reuse a matching ordered split at the anchor. Complete a safe independent
   anchor with a **new** partner. On conflicting split or pinned/bookmark
   binding, create a fresh pair in the destination window without changing the
   original. This avoids merging or destroying an unrelated existing Sidecar.
3. Correlate new pages by a transient custom GUID, stripped on both Swift and
   Chromium sides before normal tab binding. Late arrivals strip it too.
   Window-owned lifecycle events, not URL guesses, complete creation waits.
4. Use the existing ordered split helper and align focus before split creation;
   arbitrary activation/reparenting during split creation has known blank-pane
   hazards. Wait for split/visual state on the next main turn, not inside the
   Chromium tab-strip mutation stack. Re-check live target identity after waits.
5. Request `createAIChatTab` directly before expand, using existing deduplication.
   The view's historical 300 ms timer is not needed on this path. No extension
   200 ms focus settle or repeated focus-relative toggle remains. Creation may
   begin while the content Tab still reports NTP, but expand waits for its
   `aiChatEnabled` event (not document load). The existing view ignores expand
   while disabled and does not replay it on enable; this readiness gate is
   necessary, not an arbitrary sleep. Actual page,
   WebContents/JS startup and animation still cost time; no measured 500 ms
   improvement is claimed.
6. Sidecar writes its session note, waits up to 7.5 s for consumption, then
   requests source collapse by exact sidebar identity and releases that chat.
   A shared instance never closes/releases itself. The source remains available
   on failed or unconfirmed handoff, even though the target may already be open.

One monotonic 8 s budget spans native restore; participating source/target windows
reject overlapping restores while it runs. The bridge has a 10 s deadline and
Sidecar steps an 11 s deadline. Timeouts are not cancellation of dispatched
Chromium commands: late page creation may leave standalone tabs, but it cannot
resume expired split/sidebar orchestration. No automatic tab deletion or focus
rollback is attempted. JS also blocks overlap until its raw promise settles.
Source close is addressed by WebContents identity, so late close cannot affect
whatever unrelated tab happens to be focused then. Changing source conversation
while a close is outstanding is not a native conversation-identity transaction.

Split/focus changes publish `sidecar.travelBack.sceneChanged` with only the
existing Sidecar bindings, never page/conversation data. Sidecar filters the
invalidation by its fixed binding, then reads a request-scoped snapshot. Either
member's navigation and split geometry participate in latest-context freshness;
there is no continuous per-sidebar polling.

## Verification and remaining acceptance

Automated validation must cover:

- Pure anchor selection, exact URL matching, legacy defaults, geometry validity,
  matching-pair reuse, conflicting-pair preservation and safe-anchor completion.
- Sidecar wire validation, actual binding handoff, same-instance no-op,
  acknowledgement-before-close/reset, source retention, timeout/late reply,
  Phi Chat disablement, and group-plus-split capture.
- Xcode `build-for-testing` with `PhiBrowser-canary`, Apple Silicon and signing
  disabled. Do not launch the app-hosted XCTest runner beside live user browsers.
  Pure policy tests can execute in an isolated SwiftPM fixture using the actual
  `TravelBackScene.swift` and `TravelBackSceneTests.swift` without app code.

Validation on 2026-09-09: root phi-ai type check and changed-file ESLint,
884 Sidecar tests, 10 metadata tests, Sidecar build, and native Xcode 26.6
`build-for-testing` passed during the edit loop. All 8 pure native policy tests
executed successfully in the isolated fixture; this is not execution of the
native lifecycle or app-hosted suite. The workspace's pre-existing Node 26
versus requested Node 24 warning and large extension-chunk warnings remain.

On 2026-09-10 the owner confirmed the exercised restore flow after the Sidecar
follow-up fixes for arrival reminders, latest-Tab rebasing, warm receiver message
preservation and departure attachment isolation. This is user-reported acceptance,
not an instrumented run of every lifecycle case. Before committing, the native
change was reapplied without conflicts onto `origin/dev` at `3a9fc111` in
`feature/sidecar-travel-back`; Xcode `build-for-testing` passed there. The eight
pure policy tests and ten shared metadata tests also passed again; Sidecar's
latest edit-loop suite passed all 911 tests and its pre-commit parity checks
passed. This integration build reused the local Phi framework through an ignored
worktree symlink; it did not launch or replace an installed browser.

Remaining manual acceptance with matching browser/Sidecar includes the cases
below not covered by that owner report: cold and warm sidebars,
left/right and top/bottom layouts with unequal ratios, either focused pane,
a closed original bound pane, same shared instance, conflict/new pair, original
Tab gone, target close/move during restoration, split inside a tab group,
cross-window focus, and an unavailable native reply. Confirm the restored chat
and reminder suppression, not merely an API success. Inspect latency separately;
a successful build does not prove first-paint or native view attachment.

The earlier intermittent full white sidebar was not reproduced. This replaces
the proven unsafe departure ordering but does not establish that incident's
rendering root cause.
