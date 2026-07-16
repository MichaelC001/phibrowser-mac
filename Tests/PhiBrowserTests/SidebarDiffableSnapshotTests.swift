// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

private final class SnapshotSidebarItem: SidebarItem {
    let id: AnyHashable
    let title: String
    var childrenItems: [SidebarItem]
    private let isExpandableOverride: Bool?
    private let itemTypeOverride: SidebarItemType?

    init(
        id: String,
        title: String? = nil,
        children: [SidebarItem] = [],
        isExpandable: Bool? = nil,
        itemType: SidebarItemType? = nil
    ) {
        self.id = AnyHashable(id)
        self.title = title ?? id
        self.childrenItems = children
        self.isExpandableOverride = isExpandable
        self.itemTypeOverride = itemType
    }

    var url: String? { nil }
    var iconName: String? { nil }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { isExpandableOverride ?? !childrenItems.isEmpty }
    var hasChildren: Bool { isExpandable }
    var depth: Int { 0 }
    var itemType: SidebarItemType { itemTypeOverride ?? (isExpandable ? .bookmarkFolder : .bookmark) }
    var isActive: Bool { false }
    var isSelectable: Bool { true }
    var isBookmark: Bool { true }

    func performAction(with owner: SidebarTabListItemOwner?) {}
}

final class SidebarDiffableSnapshotTests: XCTestCase {
    func testSidebarSnapshotUsesStableItemIDs() {
        let child = SnapshotSidebarItem(id: "child")
        let parent = SnapshotSidebarItem(id: "parent", children: [child])

        let snapshot = SidebarDiffableSnapshotBuilder(rootItems: [parent]).makeSnapshot()

        XCTAssertEqual(snapshot.rootIDs, [AnyHashable("parent")])
        XCTAssertEqual(snapshot.childIDs(of: AnyHashable("parent")), [AnyHashable("child")])
        XCTAssertTrue(snapshot.item(for: AnyHashable("parent")) === parent)
        XCTAssertTrue(snapshot.item(for: AnyHashable("child")) === child)
    }

    func testSidebarSnapshotFiltersHiddenItem() {
        let hidden = SnapshotSidebarItem(id: "hidden")
        let visible = SnapshotSidebarItem(id: "visible")
        let parent = SnapshotSidebarItem(id: "parent", children: [hidden, visible])

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [parent],
            hiddenItemID: AnyHashable("hidden")
        ).makeSnapshot()

        XCTAssertEqual(snapshot.childIDs(of: AnyHashable("parent")), [AnyHashable("visible")])
        XCTAssertNil(snapshot.item(for: AnyHashable("hidden")))
    }

    func testSidebarSnapshotInsertsVirtualItemAtRoot() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let virtual = SnapshotSidebarItem(id: "virtual")

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [first, second],
            virtualInsertion: .init(item: virtual, parentID: nil, index: 1)
        ).makeSnapshot()

        XCTAssertEqual(snapshot.rootIDs, [AnyHashable("first"), AnyHashable("virtual"), AnyHashable("second")])
        XCTAssertTrue(snapshot.item(for: AnyHashable("virtual")) === virtual)
    }

    func testSidebarSnapshotInsertsVirtualItemInParent() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let virtual = SnapshotSidebarItem(id: "virtual")
        let parent = SnapshotSidebarItem(id: "parent", children: [first, second])

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [parent],
            virtualInsertion: .init(item: virtual, parentID: AnyHashable("parent"), index: 1)
        ).makeSnapshot()

        XCTAssertEqual(
            snapshot.childIDs(of: AnyHashable("parent")),
            [AnyHashable("first"), AnyHashable("virtual"), AnyHashable("second")]
        )
    }

    func testSidebarSnapshotHidesRealItemAndInsertsVirtualReplacement() {
        let real = SnapshotSidebarItem(id: "real")
        let sibling = SnapshotSidebarItem(id: "sibling")
        let virtual = SnapshotSidebarItem(id: "virtual")
        let parent = SnapshotSidebarItem(id: "parent", children: [real, sibling])

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [parent],
            virtualInsertion: .init(item: virtual, parentID: AnyHashable("parent"), index: 0),
            hiddenItemID: AnyHashable("real")
        ).makeSnapshot()

        XCTAssertEqual(
            snapshot.childIDs(of: AnyHashable("parent")),
            [AnyHashable("virtual"), AnyHashable("sibling")]
        )
        XCTAssertNil(snapshot.item(for: AnyHashable("real")))
        XCTAssertTrue(snapshot.item(for: AnyHashable("virtual")) === virtual)
    }

    func testSidebarSnapshotTreatsNonExpandableItemsAsLeaves() {
        let member = SnapshotSidebarItem(id: "member")
        let group = SnapshotSidebarItem(
            id: "group",
            children: [member],
            isExpandable: false,
            itemType: .tabGroup
        )

        let snapshot = SidebarDiffableSnapshotBuilder(rootItems: [group]).makeSnapshot()

        XCTAssertEqual(snapshot.rootIDs, [AnyHashable("group")])
        XCTAssertEqual(snapshot.childIDs(of: AnyHashable("group")), [])
        XCTAssertTrue(snapshot.item(for: AnyHashable("group")) === group)
        XCTAssertNil(snapshot.item(for: AnyHashable("member")))
    }

    func testStructureComparisonUsesCapturedChildrenWhenItemsMutateInPlace() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let parent = SnapshotSidebarItem(
            id: "parent",
            children: [first],
            isExpandable: true
        )
        let accepted = SidebarDiffableSnapshotBuilder(rootItems: [parent]).makeSnapshot()

        parent.childrenItems = [second]
        let updated = SidebarDiffableSnapshotBuilder(rootItems: [parent]).makeSnapshot()

        XCTAssertTrue(
            SidebarTabListViewController.hasOutlineStructureChanges(
                from: accepted,
                to: updated
            )
        )
    }

    func testStructureComparisonIgnoresMemberChangesInsideNonExpandableGroup() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let group = SnapshotSidebarItem(
            id: "group",
            children: [first],
            isExpandable: false,
            itemType: .tabGroup
        )
        let accepted = SidebarDiffableSnapshotBuilder(rootItems: [group]).makeSnapshot()

        group.childrenItems = [second]
        let updated = SidebarDiffableSnapshotBuilder(rootItems: [group]).makeSnapshot()

        XCTAssertFalse(
            SidebarTabListViewController.hasOutlineStructureChanges(
                from: accepted,
                to: updated
            )
        )
    }

    func testTabSectionRootItemsTreatsRepeatedObjectsAsUnchanged() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")

        XCTAssertFalse(
            TabSectionController.rootItemsChanged(
                from: [first, second],
                to: [first, second]
            )
        )
    }

    func testTabSectionRootItemsTreatsSameIDReplacementAsChanged() {
        let oldItem = SnapshotSidebarItem(id: "item")
        let replacement = SnapshotSidebarItem(id: "item")

        XCTAssertTrue(
            TabSectionController.rootItemsChanged(
                from: [oldItem],
                to: [replacement]
            )
        )
    }

    func testTabSectionRootItemsTreatsReorderAsChanged() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")

        XCTAssertTrue(
            TabSectionController.rootItemsChanged(
                from: [first, second],
                to: [second, first]
            )
        )
    }

    func testTabSectionRootItemsTreatsInsertAsChanged() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")

        XCTAssertTrue(
            TabSectionController.rootItemsChanged(
                from: [first],
                to: [first, second]
            )
        )
    }
}

@MainActor
final class SidebarTabSectionFastPathTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testNoOpTabSectionUpdateRefreshesSelectionAndVisibleBookmarks() throws {
        let state = try makeState()
        let bookmarkGuid = "fast-path-bookmark"
        state.localStore.createBookmark(
            url: "https://bookmark.example",
            title: "Bookmark",
            profileId: state.profileId,
            parentId: nil,
            guid: bookmarkGuid,
            spaceId: state.spaceId
        )
        guard waitUntil({
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }
        let bookmark = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: bookmarkGuid))
        let tab = seedActiveTab(in: state, guid: 101)
        let (controller, outlineView) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        guard waitUntil({
            outlineView.row(forItem: bookmark) >= 0
                && outlineView.row(forItem: tab) >= 0
                && state.visibleBookmarkTabs.map(\.guid) == [bookmarkGuid]
        }) else { return }
        waitForMainQueueUpdates()

        outlineView.deselectAll(nil)
        state.visibleBookmarkTabs = []

        controller.tabSectionDidUpdate(with: TabSectionChange(
            rootItemsChanged: false,
            affectedGroupTokens: [],
            affectedSplitIds: []
        ))

        XCTAssertEqual(
            outlineView.selectedRowIndexes,
            IndexSet(integer: outlineView.row(forItem: tab))
        )
        guard waitUntil({
            state.visibleBookmarkTabs.map(\.guid) == [bookmarkGuid]
        }) else { return }
    }

    func testSameIDReplacementUsesFullDiffablePath() throws {
        let state = try makeState()
        let oldTab = seedActiveTab(in: state, guid: 201)
        let (controller, outlineView) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        guard waitUntil({
            outlineView.row(forItem: oldTab) >= 0
        }) else { return }

        let replacement = Tab(
            guid: oldTab.guid,
            url: "https://replacement.example",
            isActive: true,
            index: 0,
            title: "Replacement"
        )
        state.tabs = [replacement]
        state.updateNormalTabs()

        guard waitUntil({
            (0..<outlineView.numberOfRows).contains { row in
                (outlineView.item(atRow: row) as? Tab) === replacement
            }
        }) else { return }
        XCTAssertFalse((0..<outlineView.numberOfRows).contains { row in
            (outlineView.item(atRow: row) as? Tab) === oldTab
        })
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory
        )
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func seedActiveTab(in state: BrowserState, guid: Int) -> Tab {
        let tab = Tab(
            guid: guid,
            url: "https://tab.example",
            isActive: true,
            index: 0,
            title: "Tab"
        )
        state.tabs = [tab]
        state.updateNormalTabs()
        state.focuseTab(tab)
        return tab
    }

    private func makeActiveSidebar(
        for state: BrowserState
    ) throws -> (SidebarTabListViewController, SideBarOutlineView) {
        let controller = SidebarTabListViewController(state: state)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        controller.setActive(true)
        controller.view.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? NSScrollView }.first
        )
        let outlineView = try XCTUnwrap(scrollView.documentView as? SideBarOutlineView)
        return (controller, outlineView)
    }

    private func waitForMainQueueUpdates() {
        let updatesFinished = expectation(description: "Main queue updates finished")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                updatesFinished.fulfill()
            }
        }
        wait(for: [updatesFinished], timeout: 1)
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
        return false
    }
}
