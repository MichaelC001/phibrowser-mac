# Space presentation and store lifetime

`SpaceModel` and `SpaceURLRule` are SwiftData persistence models. They remain
inside LocalStore operations and synchronous backup reads; UI, routing caches,
menus, bindings, and delayed callbacks must not retain them. Resetting or
releasing their ModelContext can invalidate even a scalar property read.

LocalStore reads and publishers copy these records into `Space` and
`SpaceRoutingRule`. `Space` is an ordinary `ObservableObject` class. Its published
`content` contains only copied fields; SwiftUI can observe the instance directly.
SpaceManager reconciles each incoming list, updating existing instances within
the same store. The incoming list is authoritative, including deletions and an
empty list. Routing rules are immutable values because the editor owns its draft.

Each LocalStore instance has a unique identifier, including when the same account
and directory are reopened after rollback. SpaceManager never reuses Space
instances across that boundary. Retained presentations remain readable, but
delayed edits must pass their originating `storeIdentifier` to the manager's
mutation methods. The unscoped overload defaults are for immediate commands that
resolve against the current account. Menus and editors that can outlive a store
must preserve their originating identity. A profile change waiting for a parked
window to materialize retains that identity through its completion and recursive
entry.

Before the final queued operation closes a store, LocalStore synchronously posts
`willCloseNotification` on the main actor. Space and rule publishers complete;
SpaceManager cancels its subscriptions and retires its binding generation.
Already queued deliveries check that generation before publishing. Presentation
and window slots remain alive during Guest import, while user mutations and
user-initiated Space activation are suspended.

Binding the target account synchronously replaces both Space and rule lists,
even when empty. During Guest promotion, automatic fallback selection waits for
the existing account-transition coordinator to apply the migration receipt's
Space and Profile mappings. Window replacement also remaps active, last regular,
and pending Space identifiers before the target controller registers. A restored
Guest store is bound through the same path with a new store identifier.

`SpaceStoreLifetimeTests` exercise retained reads after actual store closure,
observable updates, account replacement, empty targets, rollback reopening,
stale edits, queued old saves, and publisher termination.
`GuestDataMigrationTests` also execute a real migration with colliding Space IDs
and verify the target presentation and receipt-based selection.

This boundary does not change the SwiftData schema or replace window-scoped
BrowserState ownership. Other persistent model types still require their own
lifetime review before being retained across a store transition.
