# Native Bookmark Manager Specification

## Goal

Replace the Chromium bookmark-manager surface with a native AppKit page for
Phi bookmarks. The page renders the current Space's bookmark tree in a
two-column `DiffableOutlineView`, supports flat search results, native multiple
selection, bookmark-only drag and drop, inline editing, split-bookmark editing,
context menus, and moving items to another Space.

## Product Contract

### Entry and lifetime

- The page is represented by the existing `phi://bookmarks` route, normalized
  by `URLProcessor` to `chrome://bookmarks`.
- The sidebar bookmark button keeps opening that route.
- The Bookmarks main menu adds a `Bookmark Manager` item using the existing
  `IDC_SHOW_BOOKMARK_MANAGER` shortcut (`Option-Command-B`).
- `WebContentViewController` recognizes the bookmark-manager URL and mounts a
  native child controller in `hostView`, following the native mounting and
  split-pane ownership rules used by Group Overview and Native NTP.
- The route remains a real browser tab. Closing, selecting, moving, and
  splitting that tab therefore retain normal browser semantics. The hidden
  Chromium view remains the navigation owner, while AppKit owns presentation.
- Navigating the tab away from the bookmark-manager URL unmounts the native
  page and restores the Chromium content view.

This URL-driven integration deliberately avoids a second window-scoped
presentation flag beside `groupOverviewState`.

### Scope

- The initial scope is the manager tab's `BrowserState` pair:
  `(profileId, spaceId)`.
- Scope is represented by an explicit `BookmarkManagementScope` value rather
  than being re-read from the globally active window inside rows or menu
  actions.
- The initial page reuses the `BrowserState`-owned `BookmarkManager`. That
  manager stays permanently bound to its BrowserState because it also owns
  live normal/split bookmark bindings; the page must not retarget it in place.
- The page captures an immutable scope, BrowserState, and store at creation
  time. A later Space filter can swap in a separate scope-bound tree source
  without changing the outline projection or cells.
- V1 does not add a visible Space filter.
- Moving bookmarks to another Space leaves the manager on its source scope;
  it does not activate the destination Space.
- Incognito continues to expose no bookmark manager because the Bookmarks menu
  and bookmark tree are already unavailable there.

### Layout

- AppKit only. SwiftUI is not used for the page or its cells.
- Header: `Bookmarks` title, trailing `New Folder` button, and `NSSearchField`.
- Body: one `DiffableOutlineView` inside an `NSScrollView`.
- Columns:
  - `Website`: folder icon, or one/two 16-point favicons followed by the title.
  - `Address`: child count for a folder; the URL for a regular bookmark; or
    `primaryURL | secondaryURL` for a split bookmark.
- The Website column is the outline column. The Address column stretches with
  the page. Rows use native full-width selection and standard outline
  disclosure indicators.
- An empty scope shows a centered, localized empty-state label without adding
  a synthetic bookmark node.

### Tree and search projection

- Stable item identity is `(scope, bookmark GUID)` and the snapshot stores the
  existing `Bookmark` object. A refresh must not manufacture replacement row
  objects for unchanged IDs.
- Normal mode preserves source tree order and parent/child relationships.
- Search trims whitespace and performs localized, case- and
  diacritic-insensitive matching against title, primary URL, secondary title,
  and secondary URL.
- Search results are depth-first source order, flat root rows. Folder matches
  are included, but they are not expandable while search is active.
- Structural drop validation is disabled while search is active because a flat
  result index is not a sibling index in the persisted tree. Dragging out
  remains allowed.
- Entering or leaving search uses a new diffable snapshot. Unsafe cross-parent
  transitions may fall back to `reloadData` through the existing planner.
- Display signatures are compared between projections and changed GUIDs are
  placed in `reloadIDs`, so title, URL, split, favicon, and child-count changes
  refresh cells without replacing stable objects.
- `DiffableOutlineView.reloadWith` is the only structural refresh path. The
  datasource projection is committed inside `updateDataSource`, not in the
  completion callback. Rapid publications use a generation guard and retain
  the view's latest-wins behavior.

### Selection

- `NSOutlineView.allowsMultipleSelection` supplies standard Command- and
  Shift-selection behavior. The page does not reuse `TabMultiSelection`, whose
  implicit active-tab, split-tab, and tab-group rules do not apply here.
- Actions derive ordered bookmark GUIDs from selected rows at invocation time.
- After a snapshot apply, selection is restored by GUID for items still
  visible. Hidden, filtered, moved-out, or deleted rows leave the selection.
- Right-clicking an already-selected row keeps the batch selection.
  Right-clicking an unselected row first replaces it with a single selection.
- Double-clicking a bookmark opens it through `BrowserState.openBookmark`.
  Double-clicking a folder toggles expansion.

### Drag and drop

- The page writes the existing `.phiBookmark`, `.bookmarks`, and
  `.sourceWindowId` pasteboard fields for compatibility with sidebar and pinned
  targets.
- A drag beginning on a selected row snapshots all selected GUIDs in visible
  order. A drag beginning outside the selection represents only that row.
- Internal drops accept bookmark payloads from the same browser window and
  scope. V1 does not accept tab, pinned-tab, group, or cross-window imports.
- Drop on a folder appends to that folder. Drop between siblings resolves to
  their real parent GUID and child index. Drop at root resolves to a nil parent.
- Self-drops, folder-to-descendant drops, selected-target drops, and no-op
  placements are rejected.
- Batch commits call `BrowserState.moveSelectedBookmarks` /
  `LocalStore.moveSelectedBookmarks` once. The UI never loops single-item moves.
  Existing folder-plus-descendant and same-parent index normalization remains
  authoritative.

### Editing and creation

- `New Folder` creates an `Untitled` root folder with a known GUID. When that
  GUID arrives through the bookmark publisher, the Website cell enters inline
  editing.
- A single regular bookmark or folder exposes `Edit`. It enters inline title
  editing in the Website cell. A regular bookmark's Address cell is also
  directly editable by double-click.
- Return commits a non-empty trimmed value. Escape cancels. Losing focus
  commits. Invalid or empty values restore the persisted value and beep.
- Updating a regular bookmark URL uses `BookmarkManager.updateBookmark`, so an
  open bookmark tab follows the saved URL through the existing navigation seam.
- A split bookmark never enters inline editing. `Edit` presents
  `EditPinnedTabPresenter` in bookmark mode from the manager controller's own
  window, passing its explicit profile/Space scope, current parent GUID, both
  titles, and both URLs. Saving preserves the existing double-optional
  secondary-field semantics.

### Context menus and keyboard actions

- Single folder: Edit, New Nested Folder, Move to Space, Delete.
- Single regular bookmark: Open, Copy Link, Edit, Move to Space, Delete.
- Single split bookmark: Open, Copy Left URL, Copy Right URL, Edit (modal),
  Move to Space, Delete.
- Multiple selection: Move to Space and Delete only.
- Move targets exclude the source Space, incognito Spaces, and unavailable
  destinations. The batch move uses one scope-aware mutation and does not
  switch Spaces.
- The scope-aware move is a `BrowserState` operation accepting explicit
  bookmark GUIDs. It preserves live normal/split bookmark detachment before
  delegating persistence to `LocalStore.moveBookmarks`; the page must not call
  that low-level API directly.
- Delete and Command-Delete remove the selected bookmark roots. A multi-item
  or folder deletion asks for confirmation; a single leaf follows the existing
  immediate sidebar behavior.
- Menu actions hold GUIDs and the explicit source scope, not stale row objects
  or `MainBrowserWindowControllersManager.shared.activeWindowController`.

## Ownership and files

### Data and pure projection

- Create `Sources/UserInterface/WebContent/BookmarkManager/BookmarkManagementScope.swift`
  for explicit `(profileId, spaceId)` identity.
- Create `Sources/UserInterface/WebContent/BookmarkManager/BookmarkManagerProjection.swift`
  for normal/search projections, display signatures, flat filtering, and
  `DiffableOutlineSnapshot` construction.
- Create `Sources/UserInterface/WebContent/BookmarkManager/BookmarkManagerDropResolver.swift`
  for pure parent/index validation.
- Modify `Sources/UserInterface/Sidebar/TabList/BookmarkModel.swift` only to
  expose the current immutable scope and create a folder with a caller-supplied
  stable GUID. Do not make the manager's scope mutable.
- Modify `Sources/States/BrowserState.swift` to expose an explicit-GUID batch
  Space-move operation that preserves the existing live bookmark-detachment
  behavior without activating the destination Space.
- Add focused pure tests in
  `Tests/PhiBrowserTests/BookmarkManagerProjectionTests.swift` and
  `Tests/PhiBrowserTests/BookmarkManagerDropResolverTests.swift`.

### AppKit page

- Create `Sources/UserInterface/WebContent/BookmarkManager/BookmarkManagerViewController.swift`
  for layout, bindings, outline datasource/delegate, selection restoration,
  drag/drop, editing, actions, and modal presentation.
- Create `Sources/UserInterface/WebContent/BookmarkManager/BookmarkManagerCellView.swift`
  for native Website and Address cells and cancellable profile-scoped favicon
  loading.
- Reuse `ProfileScopedFaviconRepository`; every cell reconfiguration cancels
  both favicon handles and guards asynchronous results by represented GUID.
- Reuse existing bookmark pasteboard types and the existing batch persistence
  seam rather than adding another drag contract.

### Route and menu integration

- Modify `Sources/UserInterface/WebContent/WebContentViewController.swift` to
  add the bookmark-manager content mode, mount/unmount the AppKit child, and
  return its view from `splitPaneContentView()` when its tab participates in a
  split.
- Modify `Sources/Application/BookmarkMenuContentBuilder.swift` and
  `Sources/Application/AppController+Menu.swift` to add and dispatch the
  Bookmark Manager entry.
- Keep `SidebarViewController`'s existing `phi://bookmarks` entry unchanged;
  it automatically reaches the native route.
- Register new sources and tests in `Phi.xcodeproj/project.pbxproj`.

## Phased implementation and commits

### Phase 1: Specification

- Land this specification alone.
- Commit: `docs: specify native bookmark manager`

### Phase 2: Scoped model, projection, and drop semantics

- Add explicit manager scope and stable folder creation.
- Add pure tree/search snapshot projection and drop resolver.
- Add focused unit tests.
- Commit: `feat: add bookmark manager data projection`

### Phase 3: AppKit page and bookmark interactions

- Add header, two-column outline, diffable updates, empty/search states,
  multi-selection, internal drag/drop, cells, favicons, inline editing, split
  modal editing, context menus, deletion, and Space moves.
- Add focused controller/cell tests where behavior can be exercised without a
  live Chromium process.
- Commit: `feat: build native bookmark manager interface`

### Phase 4: Route and menu integration

- Mount the native page for the bookmark-manager URL, including split-pane
  lookup.
- Add the main-menu entry and shortcut routing.
- Add menu and route tests.
- Commit: `feat: open native bookmark manager from bookmarks menu`

## Verification

For every phase:

```sh
git diff --check
```

Final verification must run outside the Codex sandbox after quitting Phi
Canary, per repository instructions:

```sh
osascript -e 'tell application id "com.phibrowser.canary.Mac" to quit'

xcodebuild build-for-testing \
  -project Phi.xcodeproj \
  -scheme PhiBrowser-canary \
  -destination platform=macOS \
  -derivedDataPath build/DerivedData-Codex

xcodebuild test-without-building \
  -project Phi.xcodeproj \
  -scheme PhiBrowser-canary \
  -destination platform=macOS \
  -derivedDataPath build/DerivedData-Codex \
  -only-testing:PhiBrowserTests/BookmarkManagerProjectionTests \
  -only-testing:PhiBrowserTests/BookmarkManagerDropResolverTests
```

Manual acceptance remains separate from compile/test verification:

- Open from the Bookmarks menu and sidebar button.
- Verify two-column layout at narrow and wide content widths.
- Add, rename, URL-edit, delete, expand, and reorder nested items.
- Search title, both split URLs, and diacritics; verify flat results.
- Command/Shift select, right-click selected/unselected rows, and batch drag.
- Verify a split row shows two favicons and `left | right` URLs.
- Edit a split and verify both live and closed split bookmarks persist.
- Move single and multiple items to another Space without changing the
  manager's displayed Space.
- Put the manager tab in a split and switch focus between panes.

## Explicit non-goals

- A visible Space filter or all-Spaces aggregation.
- Cross-window manager drops.
- Dragging tabs into the manager to create bookmarks.
- Import/export UI changes.
- Replacing sidebar bookmark cells or `TabMultiSelection`.
- A new persistence schema or Chromium bookmark bridge.
