// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

private final class BookmarkManagerOutlineView: DiffableOutlineView {
    var contextMenuProvider: (() -> NSMenu?)?
    var deleteSelectionHandler: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), (event.keyCode == 51 || event.keyCode == 117) {
            deleteSelectionHandler?()
            return
        }
        super.keyDown(with: event)
    }
}

final class BookmarkManagerViewController: NSViewController {
    private enum Column {
        static let website = NSUserInterfaceItemIdentifier("BookmarkManagerWebsite")
        static let address = NSUserInterfaceItemIdentifier("BookmarkManagerAddress")
        static let minimumWidth: CGFloat = 100
        static let defaultWidthDifference: CGFloat = 160
    }

    private enum Row {
        static let regularHeight: CGFloat = 30
        static let splitHeight: CGFloat = 58
    }

    private final class BookmarkActionContext: NSObject {
        let guids: [String]

        init(guids: [String]) {
            self.guids = guids
        }
    }

    private final class MoveActionContext: NSObject {
        let guids: [String]
        let targetSpaceId: String

        init(guids: [String], targetSpaceId: String) {
            self.guids = guids
            self.targetSpaceId = targetSpaceId
        }
    }

    private final class CopyActionContext: NSObject {
        let url: String

        init(url: String) {
            self.url = url
        }
    }

    private let browserState: BrowserState
    private let manager: BookmarkManager
    private let scope: BookmarkManagementScope
    private var projection: BookmarkManagerProjection?
    private var projectionGeneration = 0
    private var pendingEditGuid: String?
    private var didConfigureInitialColumnWidths = false
    private var cancellables = Set<AnyCancellable>()

    private let outlineView = BookmarkManagerOutlineView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let newFolderButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")

    init(browserState: BrowserState) {
        self.browserState = browserState
        self.manager = browserState.bookmarkManager
        self.scope = browserState.bookmarkManager.scope
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.windowBackground)
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindModel()
        rebuildProjection(animated: false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        configureInitialColumnWidthsIfNeeded()
    }

    func focusContent() {
        view.window?.makeFirstResponder(outlineView)
    }

    private func buildLayout() {
        let titleLabel = NSTextField(labelWithString: NSLocalizedString(
            "bookmarkManager.header.title",
            value: "Bookmarks",
            comment: "Bookmark manager - Page title"
        ))
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        newFolderButton.title = NSLocalizedString(
            "bookmarkManager.header.newFolderAction",
            value: "New Folder",
            comment: "Bookmark manager - Button that creates a root bookmark folder"
        )
        newFolderButton.bezelStyle = .rounded
        newFolderButton.target = self
        newFolderButton.action = #selector(createRootFolder(_:))
        newFolderButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.backgroundColor = .clear
        searchField.placeholderString = NSLocalizedString(
            "bookmarkManager.header.searchPlaceholder",
            value: "Search",
            comment: "Bookmark manager - Search field placeholder"
        )
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        configureOutlineView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(newFolderButton)
        view.addSubview(searchField)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            newFolderButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            newFolderButton.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -12),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            searchField.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 224),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func configureOutlineView() {
        let websiteColumn = NSTableColumn(identifier: Column.website)
        websiteColumn.title = NSLocalizedString(
            "bookmarkManager.column.websiteTitle",
            value: "Website",
            comment: "Bookmark manager - Header for the bookmark name column"
        )
        websiteColumn.minWidth = Column.minimumWidth
        websiteColumn.width = Column.minimumWidth
        websiteColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let addressColumn = NSTableColumn(identifier: Column.address)
        addressColumn.title = NSLocalizedString(
            "bookmarkManager.column.addressTitle",
            value: "Address",
            comment: "Bookmark manager - Header for the bookmark address column"
        )
        addressColumn.minWidth = Column.minimumWidth
        addressColumn.width = Column.minimumWidth
        addressColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        outlineView.addTableColumn(websiteColumn)
        outlineView.addTableColumn(addressColumn)
        outlineView.outlineTableColumn = websiteColumn
        outlineView.headerView = NSTableHeaderView()
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.rowHeight = Row.regularHeight
        outlineView.indentationPerLevel = 18
        outlineView.intercellSpacing = .zero
        outlineView.gridStyleMask = .solidHorizontalGridLineMask
        outlineView.gridColor = .separatorColor
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.autoresizingMask = [.width]
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineDoubleClicked(_:))
        outlineView.registerForDraggedTypes([.phiBookmark, .bookmarks, .sourceWindowId])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        outlineView.deleteSelectionHandler = { [weak self] in
            self?.requestDelete(guids: self?.selectedBookmarkGuids() ?? [])
        }
    }

    private func configureInitialColumnWidthsIfNeeded() {
        guard !didConfigureInitialColumnWidths,
              scrollView.contentSize.width > 0,
              let websiteColumn = outlineView.tableColumn(withIdentifier: Column.website),
              let addressColumn = outlineView.tableColumn(withIdentifier: Column.address) else {
            return
        }

        outlineView.sizeLastColumnToFit()
        let totalWidth = websiteColumn.width + addressColumn.width
        let maximumDifference = max(0, totalWidth - Column.minimumWidth * 2)
        let widthDifference = min(Column.defaultWidthDifference, maximumDifference)

        // Uniform autoresizing preserves this initial difference while both
        // columns continue to grow and shrink with the container.
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        websiteColumn.width = (totalWidth - widthDifference) / 2
        addressColumn.width = totalWidth - websiteColumn.width
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        didConfigureInitialColumnWidths = true
    }

    private func bindModel() {
        manager.$rootFolder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildProjection(animated: true)
            }
            .store(in: &cancellables)

        browserState.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.searchField.needsDisplay = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .bookmarkStartEditing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let bookmark = notification.object as? Bookmark,
                      self.manager.bookmark(withGuid: bookmark.guid) != nil else { return }
                self.startEditing(guid: bookmark.guid, column: .website)
            }
            .store(in: &cancellables)
    }

    private func rebuildProjection(animated: Bool) {
        guard isViewLoaded else { return }
        let selectedGuids = selectedBookmarkGuids()
        let next = BookmarkManagerProjection.make(
            scope: scope,
            rootBookmarks: manager.rootFolder.children,
            searchText: searchField.stringValue,
            previous: projection
        )
        projectionGeneration += 1
        let generation = projectionGeneration

        outlineView.reloadWith(
            next.snapshot,
            animated: animated,
            updateDataSource: { [weak self] in
                guard let self else { return }
                self.projection = next
                self.updateEmptyState(for: next)
            },
            completion: { [weak self] in
                guard let self, self.projectionGeneration == generation else { return }
                self.restoreExpandedFolders()
                self.restoreSelection(guids: selectedGuids)
                self.beginPendingEditIfPossible()
            }
        )
    }

    private func updateEmptyState(for projection: BookmarkManagerProjection) {
        let isEmpty = projection.rootIDs.isEmpty
        scrollView.isHidden = isEmpty
        emptyLabel.isHidden = !isEmpty
        guard isEmpty else { return }
        switch projection.mode {
        case .tree:
            emptyLabel.stringValue = NSLocalizedString(
                "bookmarkManager.emptyState.message",
                value: "No bookmarks in this Space",
                comment: "Bookmark manager - Empty state when the current Space has no bookmarks"
            )
        case .search:
            emptyLabel.stringValue = NSLocalizedString(
                "bookmarkManager.search.emptyState",
                value: "No matching bookmarks",
                comment: "Bookmark manager - Empty state when a search has no results"
            )
        }
    }

    private func restoreExpandedFolders() {
        guard projection?.mode == .tree else { return }
        for bookmark in manager.getAllBookmarks() where bookmark.isFolder && bookmark.isExpanded {
            outlineView.expandItem(bookmark)
        }
    }

    private func restoreSelection(guids: [String]) {
        let selected = Set(guids)
        var indexes = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            guard let bookmark = outlineView.item(atRow: row) as? Bookmark,
                  selected.contains(bookmark.guid) else { continue }
            indexes.insert(row)
        }
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func selectedBookmarkGuids() -> [String] {
        outlineView.selectedRowIndexes.compactMap { row in
            (outlineView.item(atRow: row) as? Bookmark)?.guid
        }
    }

    private func bookmarks(for guids: [String]) -> [Bookmark] {
        var seen = Set<String>()
        return guids.compactMap { guid in
            guard seen.insert(guid).inserted else { return nil }
            return manager.bookmark(withGuid: guid)
        }
    }

    private func rootBookmarks(for guids: [String]) -> [Bookmark] {
        let candidates = bookmarks(for: guids)
        let selected = Set(candidates.map(\.guid))
        return candidates.filter { bookmark in
            var parent = bookmark.parent
            while let current = parent {
                if selected.contains(current.guid) { return false }
                parent = current.parent
            }
            return true
        }
    }

    private func startEditing(guid: String, column: BookmarkManagerCellView.Column) {
        guard let bookmark = manager.bookmark(withGuid: guid) else { return }
        let row = outlineView.row(forItem: bookmark)
        guard row >= 0 else { return }
        let columnIndex = column == .website ? 0 : 1
        let cell = outlineView.view(atColumn: columnIndex, row: row, makeIfNecessary: true)
            as? BookmarkManagerCellView
        cell?.beginEditing()
    }

    private func beginPendingEditIfPossible() {
        guard let guid = pendingEditGuid,
              let bookmark = manager.bookmark(withGuid: guid) else { return }
        if let parent = bookmark.parent {
            outlineView.expandItem(parent)
        }
        pendingEditGuid = nil
        DispatchQueue.main.async { [weak self] in
            self?.startEditing(guid: guid, column: .website)
        }
    }

    @objc private func createRootFolder(_ sender: Any?) {
        createFolder(in: nil)
    }

    private func createFolder(in parent: Bookmark?) {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            rebuildProjection(animated: true)
        }
        let guid = UUID().uuidString
        pendingEditGuid = guid
        parent?.isExpanded = true
        manager.addFolder(
            title: NSLocalizedString(
                "sidebar.bookmarkFolder.defaultName",
                value: "Untitled",
                comment: "Default name for new bookmark folder"
            ),
            to: parent,
            guid: guid
        )
    }

    @objc private func outlineDoubleClicked(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0, let bookmark = sender.item(atRow: row) as? Bookmark else { return }
        if bookmark.isFolder {
            sender.isItemExpanded(bookmark) ? sender.collapseItem(bookmark) : sender.expandItem(bookmark)
            return
        }
        let isSplit = bookmark.secondaryUrl?.isEmpty == false
        if sender.clickedColumn == 1, !isSplit {
            startEditing(guid: bookmark.guid, column: .address)
            return
        }
        browserState.openBookmark(bookmark)
    }

    private func makeContextMenu() -> NSMenu? {
        let guids = selectedBookmarkGuids()
        let selected = bookmarks(for: guids)
        guard !selected.isEmpty else { return nil }

        let menu = NSMenu()
        if selected.count > 1 {
            appendMoveMenu(to: menu, guids: guids)
            appendDeleteItem(to: menu, guids: guids, addsSeparator: !menu.items.isEmpty)
            return menu
        }

        guard let bookmark = selected.first else { return nil }
        if bookmark.isFolder {
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "bookmarkManager.contextMenu.editAction",
                    value: "Edit",
                    comment: "Bookmark manager context menu - Edit a single bookmark or folder"
                ),
                action: #selector(editMenuItem(_:)),
                context: BookmarkActionContext(guids: [bookmark.guid])
            ))
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "sidebar.bookmarkContextMenu.newNestedFolderAction",
                    value: "New Nested Folder...",
                    comment: "Bookmark New Folder menu item"
                ),
                action: #selector(newNestedFolderMenuItem(_:)),
                context: BookmarkActionContext(guids: [bookmark.guid])
            ))
        } else {
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "bookmarkManager.contextMenu.openAction",
                    value: "Open",
                    comment: "Bookmark manager context menu - Open a bookmark"
                ),
                action: #selector(openMenuItem(_:)),
                context: BookmarkActionContext(guids: [bookmark.guid])
            ))
            if let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty {
                if let primaryURL = bookmark.url {
                    menu.addItem(copyItem(
                        title: NSLocalizedString(
                            "sidebar.bookmarkContextMenu.copyLeftPrimaryUrl",
                            value: "Copy Left URL",
                            comment: "Bookmark context menu - Copy the left (primary) URL of a split-view bookmark"
                        ),
                        url: primaryURL
                    ))
                }
                menu.addItem(copyItem(
                    title: NSLocalizedString(
                        "sidebar.bookmarkContextMenu.copyRightSecondaryUrl",
                        value: "Copy Right URL",
                        comment: "Bookmark context menu - Copy the right (secondary) URL of a split-view bookmark"
                    ),
                    url: secondaryURL
                ))
            } else if let url = bookmark.url {
                menu.addItem(copyItem(
                    title: NSLocalizedString(
                        "sidebar.bookmarkContextMenu.copyLinkAction",
                        value: "Copy Link",
                        comment: "Bookmark Copy Link menu item"
                    ),
                    url: url
                ))
            }
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "bookmarkManager.contextMenu.editAction",
                    value: "Edit",
                    comment: "Bookmark manager context menu - Edit a single bookmark or folder"
                ),
                action: #selector(editMenuItem(_:)),
                context: BookmarkActionContext(guids: [bookmark.guid])
            ))
        }

        appendMoveMenu(to: menu, guids: guids)
        appendDeleteItem(to: menu, guids: guids, addsSeparator: true)
        return menu
    }

    private func actionItem(
        title: String,
        action: Selector,
        context: Any
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = context
        return item
    }

    private func copyItem(title: String, url: String) -> NSMenuItem {
        actionItem(
            title: title,
            action: #selector(copyURLMenuItem(_:)),
            context: CopyActionContext(url: url)
        )
    }

    private func appendMoveMenu(to menu: NSMenu, guids: [String]) {
        guard PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue(),
              !browserState.isIncognito else { return }
        let targets = SpaceManager.shared.spaces.filter {
            $0.spaceId != scope.spaceId && !SpaceManager.isIncognitoSpaceId($0.spaceId)
        }
        guard !targets.isEmpty else { return }

        let parent = NSMenuItem(
            title: NSLocalizedString(
                "sidebar.bookmarkContextMenu.moveToSpaceSubmenu",
                value: "Move to Space",
                comment: "Bookmark context menu - Submenu to move this bookmark or folder to another Space"
            ),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        for space in targets {
            let item = actionItem(
                title: space.name,
                action: #selector(moveToSpaceMenuItem(_:)),
                context: MoveActionContext(guids: guids, targetSpaceId: space.spaceId)
            )
            item.image = SpaceIconView.menuImage(for: space.iconName)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func appendDeleteItem(to menu: NSMenu, guids: [String], addsSeparator: Bool) {
        if addsSeparator, menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        menu.addItem(actionItem(
            title: NSLocalizedString(
                "sidebar.bookmarkContextMenu.deleteAction",
                value: "Delete",
                comment: "Delete bookmark menu item"
            ),
            action: #selector(deleteMenuItem(_:)),
            context: BookmarkActionContext(guids: guids)
        ))
    }

    @objc private func openMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext,
              let bookmark = bookmarks(for: context.guids).first,
              !bookmark.isFolder else { return }
        browserState.openBookmark(bookmark)
    }

    @objc private func copyURLMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? CopyActionContext else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            URLProcessor.phiBrandEnsuredUrlString(context.url),
            forType: .string
        )
    }

    @objc private func editMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext,
              let bookmark = bookmarks(for: context.guids).first else { return }
        if bookmark.secondaryUrl?.isEmpty == false {
            presentSplitEditor(for: bookmark)
        } else {
            startEditing(guid: bookmark.guid, column: .website)
        }
    }

    @objc private func newNestedFolderMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext,
              let folder = bookmarks(for: context.guids).first,
              folder.isFolder else { return }
        createFolder(in: folder)
    }

    @objc private func moveToSpaceMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? MoveActionContext else { return }
        browserState.moveBookmarks(
            bookmarkGuids: context.guids,
            toSpaceId: context.targetSpaceId
        )
    }

    @objc private func deleteMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext else { return }
        requestDelete(guids: context.guids)
    }

    private func presentSplitEditor(for bookmark: Bookmark) {
        let bookmarkGuid = bookmark.guid
        let originalParentGuid = bookmark.parent?.guid
        let originalSecondaryURL = bookmark.secondaryUrl
        EditPinnedTabPresenter.presentModal(
            mode: .bookmark,
            title: bookmark.title,
            urlString: bookmark.url ?? "",
            secondaryUrlString: originalSecondaryURL,
            secondaryTitleString: bookmark.secondaryTitle,
            modelContainer: browserState.localStore.container,
            profileId: scope.profileId,
            spaceId: scope.spaceId,
            initialFolderGuid: originalParentGuid,
            from: view.window,
            onCreateFolder: { [weak self] folderName in
                guard let self else { return nil }
                let guid = UUID().uuidString
                self.browserState.localStore.createDirectory(
                    title: folderName,
                    profileId: self.scope.profileId,
                    parentId: nil,
                    guid: guid,
                    spaceId: self.scope.spaceId
                )
                return guid
            },
            onValidate: { [weak self] result in
                guard let self,
                      let primaryURL = result.url,
                      let secondaryURL = result.secondaryUrl,
                      self.browserState.localStore.normalizedURL(from: primaryURL) != nil,
                      self.browserState.localStore.normalizedURL(from: secondaryURL) != nil else {
                    NSSound.beep()
                    return false
                }
                return true
            }
        ) { [weak self] result in
            guard let self else { return }
            let secondaryURLUpdate: String?? = originalSecondaryURL == nil
                ? nil
                : .some(result.secondaryUrl ?? "")
            let secondaryTitleUpdate: String?? = originalSecondaryURL == nil
                ? nil
                : .some(result.secondaryTitle ?? "")
            self.manager.updateBookmark(
                guid: bookmarkGuid,
                title: result.title,
                url: result.url,
                secondaryUrl: secondaryURLUpdate,
                secondaryTitle: secondaryTitleUpdate
            )
            guard result.parentFolderGuid != originalParentGuid else { return }
            if let targetGuid = result.parentFolderGuid {
                if let target = self.manager.bookmark(withGuid: targetGuid) {
                    self.browserState.moveSelectedBookmarks(
                        bookmarkGuids: [bookmarkGuid],
                        to: target,
                        index: Int.max
                    )
                } else {
                    self.browserState.localStore.moveBookmark(
                        bookmarkGuid,
                        profileId: self.scope.profileId,
                        to: targetGuid,
                        newIndex: Int.max
                    )
                }
                return
            }
            self.browserState.moveSelectedBookmarks(
                bookmarkGuids: [bookmarkGuid],
                to: nil,
                index: Int.max
            )
        }
    }

    private func requestDelete(guids: [String]) {
        let roots = rootBookmarks(for: guids)
        guard !roots.isEmpty else { return }
        let requiresConfirmation = roots.count > 1 || roots.contains(where: \.isFolder)
        guard requiresConfirmation else {
            roots.forEach(manager.removeBookmark)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "bookmarkManager.deleteConfirmation.title",
            value: "Delete selected bookmarks?",
            comment: "Bookmark manager - Title of the confirmation shown before deleting multiple bookmarks or a folder"
        )
        alert.informativeText = NSLocalizedString(
            "bookmarkManager.deleteConfirmation.message",
            value: "Folders and everything inside them will be removed.",
            comment: "Bookmark manager - Explanation shown before deleting bookmark folders"
        )
        alert.addButton(withTitle: NSLocalizedString(
            "bookmarkManager.deleteConfirmation.deleteAction",
            value: "Delete",
            comment: "Bookmark manager delete confirmation - Destructive button title"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "bookmarkManager.deleteConfirmation.cancelAction",
            value: "Cancel",
            comment: "Bookmark manager delete confirmation - Cancel button title"
        ))

        let commit = { [weak self] in
            guard let self else { return }
            for root in roots {
                guard let current = self.manager.bookmark(withGuid: root.guid) else { continue }
                self.manager.removeBookmark(current)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { commit() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            commit()
        }
    }

    private func dropTarget(item: Any?, childIndex: Int) -> BookmarkManagerDropTarget? {
        if childIndex == NSOutlineViewDropOnItemIndex {
            guard let folder = item as? Bookmark, folder.isFolder else { return nil }
            return .onFolder(guid: folder.guid)
        }
        if let folder = item as? Bookmark, folder.isFolder {
            return .betweenSiblings(parentGuid: folder.guid, index: childIndex)
        }
        if item == nil {
            return .atRoot(index: childIndex)
        }
        return nil
    }

    private func dropResolution(
        info: NSDraggingInfo,
        item: Any?,
        childIndex: Int
    ) -> BookmarkManagerDropResolution? {
        let pasteboard = info.draggingPasteboard
        guard pasteboard.string(forType: .sourceWindowId) == String(browserState.windowId),
              let target = dropTarget(item: item, childIndex: childIndex) else {
            return nil
        }
        var guids = pasteboard.phiBookmarkGuids()
        if guids.isEmpty, let guid = pasteboard.string(forType: .phiBookmark) {
            guids = [guid]
        }
        return BookmarkManagerDropResolver.resolve(
            orderedBookmarkGuids: guids,
            target: target,
            rootFolder: manager.rootFolder,
            isSearchActive: projection?.mode != .tree
        )
    }
}

extension BookmarkManagerViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        rebuildProjection(animated: true)
    }
}

extension BookmarkManagerViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let projection else { return 0 }
        if let bookmark = item as? Bookmark {
            return projection.snapshot.childIDs(of: AnyHashable(projection.itemID(for: bookmark))).count
        }
        return projection.snapshot.rootIDs.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let projection else { return manager.rootFolder }
        let ids: [AnyHashable]
        if let bookmark = item as? Bookmark {
            ids = projection.snapshot.childIDs(of: AnyHashable(projection.itemID(for: bookmark)))
        } else {
            ids = projection.snapshot.rootIDs
        }
        guard ids.indices.contains(index), let child = projection.snapshot.item(for: ids[index]) else {
            return manager.rootFolder
        }
        return child
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard projection?.mode == .tree, let bookmark = item as? Bookmark else { return false }
        return bookmark.isFolder
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let bookmark = item as? Bookmark else { return nil }
        let row = outlineView.row(forItem: bookmark)
        let selected = row >= 0 && outlineView.selectedRowIndexes.contains(row)
        let guids = selected ? selectedBookmarkGuids() : [bookmark.guid]
        guard !guids.isEmpty else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(guids[0], forType: .phiBookmark)
        pasteboardItem.setString(guids.joined(separator: ","), forType: .bookmarks)
        pasteboardItem.setString(String(browserState.windowId), forType: .sourceWindowId)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard case .move = dropResolution(info: info, item: item, childIndex: index) else {
            return []
        }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard case .move(let plan) = dropResolution(
            info: info,
            item: item,
            childIndex: index
        ) else { return false }
        let targetFolder = plan.destinationParentGuid.flatMap {
            manager.bookmark(withGuid: $0)
        }
        return browserState.moveSelectedBookmarks(
            bookmarkGuids: plan.orderedBookmarkGuids,
            to: targetFolder,
            index: plan.destinationIndex
        )
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }
}

extension BookmarkManagerViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let bookmark = item as? Bookmark,
              bookmark.secondaryUrl?.isEmpty == false else {
            return Row.regularHeight
        }
        return Row.splitHeight
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let bookmark = item as? Bookmark,
              let identifier = tableColumn?.identifier else { return nil }
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self)
            as? BookmarkManagerCellView) ?? BookmarkManagerCellView(frame: .zero)
        cell.identifier = identifier
        if identifier == Column.website {
            cell.configure(
                bookmark: bookmark,
                scope: scope,
                column: .website,
                onCommit: { [weak self] title in
                    guard let self else { return false }
                    self.manager.updateBookmark(guid: bookmark.guid, title: title)
                    return true
                }
            )
        } else {
            cell.configure(
                bookmark: bookmark,
                scope: scope,
                column: .address,
                onCommit: bookmark.isFolder || bookmark.secondaryUrl?.isEmpty == false
                    ? nil
                    : { [weak self] url in
                        guard let self,
                              self.browserState.localStore.normalizedURL(from: url) != nil else {
                            return false
                        }
                        self.manager.updateBookmark(guid: bookmark.guid, url: url)
                        return true
                    }
            )
        }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? Bookmark)?.isExpanded = true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? Bookmark)?.isExpanded = false
    }
}
