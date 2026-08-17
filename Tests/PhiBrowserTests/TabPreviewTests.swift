// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class TabPreviewTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testInactiveNormalTabUsesCachedThumbnail() throws {
        let state = try makeBrowserState()
        let tab = makeTab(guid: 10, title: "Background", url: "https://background.example")
        state.tabs = [tab]
        state.normalTabs = [tab]
        var requestedIDs: [Int64] = []
        let thumbnail = makeImageData()
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return thumbnail
        }

        let content = try XCTUnwrap(resolver.resolve(.tab(tab), in: state))

        XCTAssertEqual(content.id, .tab("10"))
        XCTAssertEqual(content.title, "Background")
        XCTAssertEqual(content.url, "https://background.example")
        XCTAssertEqual(requestedIDs, [10])
    }

    func testFocusedTabIsIneligible() throws {
        let state = try makeBrowserState()
        let tab = makeTab(guid: 10, title: "Foreground", url: "https://foreground.example")
        state.tabs = [tab]
        state.normalTabs = [tab]
        state.focusingTab = tab
        let resolver = TabPreviewContentResolver { _ in
            XCTFail("Focused tabs must not request thumbnails.")
            return nil
        }

        XCTAssertFalse(resolver.isEligible(.tab(tab), in: state))
        XCTAssertNil(resolver.resolve(.tab(tab), in: state))
    }

    func testDetachedNormalTabIsIneligible() throws {
        let state = try makeBrowserState()
        let staleTab = makeTab(
            guid: 10,
            title: "Detached",
            url: "https://detached.example"
        )
        let resolver = TabPreviewContentResolver { _ in
            XCTFail("A tab detached from the window must not request a thumbnail.")
            return nil
        }

        XCTAssertFalse(resolver.isEligible(.tab(staleTab), in: state))
        XCTAssertNil(resolver.resolve(.tab(staleTab), in: state))
    }

    func testInactivePaneInLiveSplitIsIneligible() throws {
        let state = try makeBrowserState()
        let first = makeTab(guid: 10, title: "First", url: "https://first.example")
        let second = makeTab(guid: 11, title: "Second", url: "https://second.example")
        state.tabs = [first, second]
        state.normalTabs = [first, second]
        state.splits = [
            SplitGroup(
                id: "split-10-11",
                primaryTabId: 10,
                secondaryTabId: 11,
                layout: .vertical,
                ratio: 0.5
            ),
        ]
        state.focusingTab = first
        let resolver = TabPreviewContentResolver { _ in
            XCTFail("Split tabs must not request thumbnails.")
            return nil
        }

        XCTAssertFalse(resolver.isEligible(.tab(second), in: state))
    }

    func testClosedPinnedTabUsesPlaceholderWithoutInvalidThumbnailRequest() throws {
        let state = try makeBrowserState()
        let pinned = makeTab(
            guid: -1,
            title: "Pinned",
            url: "https://pinned.example",
            persistentID: "pinned-1"
        )
        pinned.isPinned = true
        pinned.isOpenned = false
        state.pinnedTabs = [pinned]
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return nil
        }

        let content = try XCTUnwrap(resolver.resolve(.tab(pinned), in: state))

        XCTAssertEqual(content.id, .tab("pinned-1"))
        XCTAssertEqual(content.title, "Pinned")
        XCTAssertTrue(requestedIDs.isEmpty)
    }

    func testOpenedPinnedRecordUsesLiveTabMetadataAndThumbnail() throws {
        let state = try makeBrowserState()
        let record = makeTab(
            guid: -1,
            title: "Saved title",
            url: "https://saved.example",
            persistentID: "pinned-1"
        )
        record.isPinned = true
        let live = makeTab(
            guid: 22,
            title: "Current title",
            url: "https://current.example",
            persistentID: "pinned-1"
        )
        state.tabs = [live]
        state.pinnedTabs = [record]
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }

        let content = try XCTUnwrap(resolver.resolve(.tab(record), in: state))

        XCTAssertEqual(content.title, "Current title")
        XCTAssertEqual(content.url, "https://current.example")
        XCTAssertEqual(requestedIDs, [22])
    }

    func testPinnedRecordRejectsStaleNumericBinding() throws {
        let state = try makeBrowserState()
        let record = makeTab(
            guid: 22,
            title: "Saved title",
            url: "https://saved.example",
            persistentID: "pinned-1"
        )
        record.isPinned = true
        let unrelated = makeTab(
            guid: 22,
            title: "Unrelated title",
            url: "https://unrelated.example",
            persistentID: "pinned-2"
        )
        state.tabs = [unrelated]
        state.pinnedTabs = [record]
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }

        let content = try XCTUnwrap(resolver.resolve(.tab(record), in: state))

        XCTAssertEqual(content.title, "Saved title")
        XCTAssertEqual(content.url, "https://saved.example")
        XCTAssertTrue(requestedIDs.isEmpty)
        guard case .placeholder = content.imageSource else {
            return XCTFail("A stale pinned binding must use the persisted placeholder.")
        }
    }

    func testPinnedImageCacheChangesAcrossOpenCloseAndRebind() throws {
        let state = try makeBrowserState()
        let record = makeTab(
            guid: -1,
            title: "Saved title",
            url: "https://saved.example",
            persistentID: "pinned-1"
        )
        record.isPinned = true
        record.isOpenned = false
        state.pinnedTabs = [record]
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }

        let closed = try XCTUnwrap(resolver.resolve(.tab(record), in: state))
        guard case .placeholder = closed.imageSource else {
            return XCTFail("A closed pin must start with a placeholder.")
        }

        let firstLive = makeTab(
            guid: 22,
            title: "First live page",
            url: "https://first.example",
            persistentID: "pinned-1"
        )
        record.isOpenned = true
        state.tabs = [firstLive]
        let opened = try XCTUnwrap(
            resolver.resolve(.tab(record), in: state, reusing: closed)
        )
        XCTAssertEqual(opened.imageSource, .thumbnail(tabID: 22))

        let reboundLive = makeTab(
            guid: 23,
            title: "Rebound live page",
            url: "https://rebound.example",
            persistentID: "pinned-1"
        )
        state.tabs = [reboundLive]
        let rebound = try XCTUnwrap(
            resolver.resolve(.tab(record), in: state, reusing: opened)
        )
        XCTAssertEqual(rebound.imageSource, .thumbnail(tabID: 23))

        record.isOpenned = false
        state.tabs = []
        let closedAgain = try XCTUnwrap(
            resolver.resolve(.tab(record), in: state, reusing: rebound)
        )
        guard case .placeholder = closedAgain.imageSource else {
            return XCTFail("Closing a live pin must replace its thumbnail.")
        }
        XCTAssertEqual(requestedIDs, [22, 23])
    }

    func testPersistedPinnedSplitIsIneligibleWithReversePartnerLink() throws {
        let state = try makeBrowserState()
        let left = makeTab(
            guid: -1,
            title: "Left",
            url: "https://left.example",
            persistentID: "left"
        )
        let right = makeTab(
            guid: -1,
            title: "Right",
            url: "https://right.example",
            persistentID: "right"
        )
        left.isPinned = true
        right.isPinned = true
        right.splitPartnerGuid = "left"
        state.pinnedTabs = [left, right]
        let resolver = TabPreviewContentResolver { _ in nil }

        XCTAssertFalse(resolver.isEligible(.tab(left), in: state))
        XCTAssertFalse(resolver.isEligible(.tab(right), in: state))
    }

    func testOpenedBookmarkUsesLiveTabAndClosedBookmarkUsesPlaceholder() throws {
        let state = try makeBrowserState()
        let live = makeTab(
            guid: 42,
            title: "Current page",
            url: "https://current.example",
            persistentID: "bookmark-open"
        )
        state.tabs = [live]
        let open = Bookmark(
            guid: "bookmark-open",
            title: "Saved bookmark",
            url: "https://saved.example"
        )
        open.isOpened = true
        open.chromiumTabGuid = 42
        let closed = Bookmark(
            guid: "bookmark-closed",
            title: "Closed bookmark",
            url: "https://closed.example"
        )
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }

        let openContent = try XCTUnwrap(resolver.resolve(.bookmark(open), in: state))
        let closedContent = try XCTUnwrap(resolver.resolve(.bookmark(closed), in: state))

        XCTAssertEqual(openContent.title, "Current page")
        XCTAssertEqual(openContent.url, "https://current.example")
        XCTAssertEqual(closedContent.title, "Closed bookmark")
        XCTAssertEqual(closedContent.url, "https://closed.example")
        XCTAssertEqual(requestedIDs, [42])
    }

    func testOpenedBookmarkRejectsStaleChromiumBinding() throws {
        let state = try makeBrowserState()
        let unrelated = makeTab(
            guid: 42,
            title: "Unrelated page",
            url: "https://unrelated.example",
            persistentID: "other-bookmark"
        )
        state.tabs = [unrelated]
        let bookmark = Bookmark(
            guid: "expected-bookmark",
            title: "Saved bookmark",
            url: "https://saved.example"
        )
        bookmark.isOpened = true
        bookmark.chromiumTabGuid = 42
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }

        let content = try XCTUnwrap(resolver.resolve(.bookmark(bookmark), in: state))

        XCTAssertEqual(content.title, "Saved bookmark")
        XCTAssertEqual(content.url, "https://saved.example")
        XCTAssertTrue(requestedIDs.isEmpty)
    }

    func testBookmarkImageCacheChangesAcrossOpenAndClose() throws {
        let state = try makeBrowserState()
        let bookmark = Bookmark(
            guid: "bookmark-1",
            title: "Saved bookmark",
            url: "https://saved.example"
        )
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }

        let closed = try XCTUnwrap(resolver.resolve(.bookmark(bookmark), in: state))
        guard case .placeholder = closed.imageSource else {
            return XCTFail("A closed bookmark must start with a placeholder.")
        }

        let live = makeTab(
            guid: 42,
            title: "Live page",
            url: "https://live.example",
            persistentID: bookmark.guid
        )
        bookmark.isOpened = true
        bookmark.chromiumTabGuid = live.guid
        state.tabs = [live]
        let opened = try XCTUnwrap(
            resolver.resolve(.bookmark(bookmark), in: state, reusing: closed)
        )
        XCTAssertEqual(opened.imageSource, .thumbnail(tabID: 42))

        bookmark.isOpened = false
        bookmark.chromiumTabGuid = -1
        state.tabs = []
        let closedAgain = try XCTUnwrap(
            resolver.resolve(.bookmark(bookmark), in: state, reusing: opened)
        )
        guard case .placeholder = closedAgain.imageSource else {
            return XCTFail("Closing a bookmark must replace its thumbnail.")
        }
        XCTAssertEqual(requestedIDs, [42])
    }

    func testLiveMetadataRefreshReusesThumbnail() throws {
        let state = try makeBrowserState()
        let tab = makeTab(guid: 10, title: "First title", url: "https://first.example")
        state.tabs = [tab]
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return self.makeImageData()
        }

        let first = try XCTUnwrap(resolver.resolve(.tab(tab), in: state))
        tab.title = "Updated title"
        tab.url = "https://updated.example"
        let updated = try XCTUnwrap(
            resolver.resolve(.tab(tab), in: state, reusing: first)
        )

        XCTAssertEqual(updated.title, "Updated title")
        XCTAssertEqual(updated.url, "https://updated.example")
        XCTAssertEqual(updated.imageSource, .thumbnail(tabID: 10))
        XCTAssertEqual(requestedIDs, [10])
    }

    func testPlaceholderMetadataRefreshRegeneratesWithoutRetryingThumbnail() throws {
        let state = try makeBrowserState()
        let tab = makeTab(guid: 10, title: "First title", url: "https://first.example")
        state.tabs = [tab]
        var requestedIDs: [Int64] = []
        let resolver = TabPreviewContentResolver { tabID in
            requestedIDs.append(tabID)
            return Data([0x00, 0x01])
        }

        let first = try XCTUnwrap(resolver.resolve(.tab(tab), in: state))
        tab.title = "Updated title"
        let updated = try XCTUnwrap(
            resolver.resolve(.tab(tab), in: state, reusing: first)
        )

        guard case .livePlaceholder(_, let identity) = updated.imageSource else {
            return XCTFail("An invalid thumbnail must fall back to a live placeholder.")
        }
        XCTAssertEqual(identity.title, "Updated title")
        XCTAssertEqual(requestedIDs, [10])
    }

    func testFolderActiveAndSplitBookmarksAreIneligible() throws {
        let state = try makeBrowserState()
        let folder = Bookmark(guid: "folder", title: "Folder", isFolder: true)
        let active = Bookmark(guid: "active", title: "Active", url: "https://active.example")
        active.isActive = true
        let split = Bookmark(
            guid: "split",
            title: "Split",
            url: "https://left.example",
            secondaryUrl: "https://right.example"
        )
        let bound = Bookmark(guid: "bound", title: "Bound", url: "https://bound.example")
        state.splitBookmarkBindings[bound.guid] = "split-id"
        let resolver = TabPreviewContentResolver { _ in nil }

        XCTAssertFalse(resolver.isEligible(.bookmark(folder), in: state))
        XCTAssertFalse(resolver.isEligible(.bookmark(active), in: state))
        XCTAssertFalse(resolver.isEligible(.bookmark(split), in: state))
        XCTAssertFalse(resolver.isEligible(.bookmark(bound), in: state))
    }

    private func makeBrowserState() throws -> BrowserState {
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

    private func makeTab(
        guid: Int,
        title: String,
        url: String,
        persistentID: String? = nil
    ) -> Tab {
        Tab(
            guid: guid,
            url: url,
            isActive: false,
            index: 0,
            title: title,
            customGuid: persistentID,
            windowId: 7
        )
    }

    private func makeImageData() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [:]) else {
            XCTFail("Failed to create test JPEG data.")
            return Data()
        }
        return data
    }
}
