# Notification cards

Extensions show the browser's notification card with
`chrome.phinomenonPrivate.sendMessageToApp("notification", message)`. The
message reaches `ExtensionMessageRouter`, which hands it to
[`NotificationCardManager`](../Sources/Notifications/MessageCard/NotificationCardManager.swift).
Every card shares one five-card queue, the account's popup preference and the
sidebar or overlay presentation. Agents on the direct channel use
[`notification.show`](agent-notification-cards.md) instead, which shows action
cards only.

## Showing a card

```js
{
  action: 'notification.card.request',
  messageId: 'task-report:run-1',
  payload: {
    task_id: 'chat-1',     // identity: a card with the same task_id replaces it
    kind: 'action',        // optional: 'action' (default) or 'working'
    task_type: 'task-report',
    title: 'Search web comments and reviews',
    description: 'The comments lean positive.',
    button_title: 'View details', // action cards only; defaults to "Run"
    timestamp: 1760000000000,
    expires_at: 1760000300000,    // epoch ms; 0 or absent never expires
  },
}
```

An absent or unrecognised `kind` is an action card. Its primary button sends
`accept`, its close button sends `reject`, and expiry or eviction from the queue
sends `timeout`, as a `notification.card.response` broadcast.

## Conversation cards

A card with `task_type: 'task-report'` is a conversation card: its `task_id`
is a saved conversation. Its primary button first tries to show that
conversation in the AI Chat panel of the window the card was clicked in. The
app asks phi-agent which Profile owns the conversation and shows it only when
it belongs to no Profile or to that window's. The window's focused tab must
also be able to show the panel, so the new tab page, incognito windows and
the group overview do not qualify. An open panel on another conversation
reloads onto this one.

The `accept` decision then carries `opened_in: 'sidebar'` when the panel
showed the conversation, and the Sidecar opens nothing more. Without it, the
Sidecar opens the conversation in the Phi Chat window as before. The card
leaves the queue on the click, before the lookup finishes.

## Working cards

A `working` card shows that the agent is still on a task. It renders like a
running reply in Phi Chat: the agent avatar with a shimmering "Working" status
and cycling dots, the `title`, and the `description` as the current activity
beside the wandering accent dot. It has no button, and `button_title` is
ignored.

- **Progress:** resend the same `task_id` with `kind: 'working'` and the new
  `description`. The card updates where it stands. It does not move to the
  front of the stack or reopen a stack the user hid.
- **Result:** send an action card with the same `task_id`. It replaces the
  working card and moves to the front like any new card.
- **Withdrawal:** revoke the working card's `messageId`.

Set `expires_at` on a working card so it is taken down if the sender stops
without a result or revoke. Closing it sends `reject`, and expiry sends
`timeout`, as for any card.

## Revoking a card

```js
{ action: 'notification.card.revoke', messageId: 'task-report:run-1' }
```

This takes down every card shown under that `messageId` and sends no decision.
The reply is the `messageId` when a card was taken down, or an empty string when
none was showing.
