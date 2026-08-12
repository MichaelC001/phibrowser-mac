// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BookmarkManagerScopeTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testManagerCapturesBrowserStateScope() throws {
        let state = try makeState(
            accountId: "scope-account",
            profileId: "Profile 1",
            spaceId: "scope-space"
        )

        XCTAssertEqual(
            state.bookmarkManager.scope,
            BookmarkManagementScope(
                accountId: "scope-account",
                profileId: "Profile 1",
                spaceId: "scope-space"
            )
        )
    }

    func testAddFolderAcceptsCallerSuppliedGuid() throws {
        let state = try makeState()
        let folderGuid = "manager-created-folder"

        state.bookmarkManager.addFolder(title: "Managed Folder", guid: folderGuid)

        XCTAssertTrue(waitUntil {
            state.bookmarkManager.bookmark(withGuid: folderGuid)?.title == "Managed Folder"
        })
    }

    func testExplicitBatchSpaceMoveDetachesLiveBookmarkBindings() throws {
        let state = try makeState()
        let targetSpace = SpaceModel(
            spaceId: "batch-target",
            profileId: state.profileId,
            name: "Target",
            colorHex: "#000000",
            iconName: "circle",
            sortOrder: 1
        )
        let context = try XCTUnwrap(state.localStore.getMainContext())
        context.insert(targetSpace)
        try context.save()

        let normalGuid = "live-normal-bookmark"
        let splitGuid = "live-split-bookmark"
        state.localStore.createBookmark(
            url: "https://normal.example",
            title: "Normal",
            profileId: state.profileId,
            parentId: nil,
            guid: normalGuid,
            spaceId: state.spaceId
        )
        state.localStore.createBookmark(
            url: "https://left.example",
            title: "Split",
            profileId: state.profileId,
            parentId: nil,
            guid: splitGuid,
            spaceId: state.spaceId,
            secondaryUrl: "https://right.example"
        )
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: normalGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: splitGuid) != nil
        }) else { return }

        let normalTab = Tab(
            guid: 1,
            url: "https://normal.example",
            isActive: false,
            index: 0
        )
        normalTab.guidInLocalDB = normalGuid
        state.tabs = [
            normalTab,
            Tab(guid: 2, url: "https://left.example", isActive: false, index: 1),
            Tab(guid: 3, url: "https://right.example", isActive: false, index: 2),
        ]
        state.splits = [
            SplitGroup(
                id: "live-split",
                primaryTabId: 2,
                secondaryTabId: 3,
                layout: .vertical,
                ratio: 0.5
            )
        ]
        state.splitBookmarkBindings[splitGuid] = "live-split"

        XCTAssertFalse(state.multiSelection.isActive)
        XCTAssertTrue(
            state.moveBookmarks(
                bookmarkGuids: [normalGuid, splitGuid],
                to: targetSpace
            )
        )
        XCTAssertNil(normalTab.guidInLocalDB)
        XCTAssertNil(state.splitBookmarkBindings[splitGuid])
        XCTAssertTrue(waitUntil {
            Set(
                state.localStore.fetchBookmarks(
                    parentId: nil,
                    profileId: targetSpace.profileId,
                    spaceId: targetSpace.spaceId
                ).map(\.guid)
            ) == [normalGuid, splitGuid]
        })
    }

    private func makeState(
        accountId: String = UUID().uuidString,
        profileId: String = LocalStore.defaultProfileId,
        spaceId: String = LocalStore.defaultSpaceId
    ) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: accountId),
            storeDirectoryURL: directory
        )
        return BrowserState(
            windowId: 17,
            localStore: store,
            profileId: profileId,
            spaceId: spaceId
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
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
