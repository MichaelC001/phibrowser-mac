// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

/// `BookmarkManager.didApplyFirstStoreDelivery` is what the sidebar's restore
/// gate waits on before painting a restored window's tab list. These pin the
/// two properties that make it usable as a gate: it always resolves, and when
/// it fires the bookmark-backed tabs are already out of `normalTabs`.
@MainActor
final class BookmarkStoreFirstDeliveryTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var originalLayoutRawValue: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLayoutRawValue = UserDefaults.standard.string(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        // Traditional layout keeps bookmark-backed tabs in the tab list, so
        // the absorption these tests are about only exists outside it.
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
    }

    override func tearDownWithError() throws {
        if let originalLayoutRawValue {
            UserDefaults.standard.set(originalLayoutRawValue,
                                      forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification,
                                        object: UserDefaults.standard)

        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    /// A profile with no bookmarks still resolves the signal. The older
    /// "initial data loaded" notion keyed on the first NON-EMPTY tree, which
    /// never arrives here — a gate built on that would hold forever.
    func testEmptyBookmarkStoreStillResolvesFirstDelivery() throws {
        let state = try makeState(in: try makeStore())
        XCTAssertFalse(state.bookmarkManager.didApplyFirstStoreDelivery)
        XCTAssertTrue(waitUntil {
            state.bookmarkManager.didApplyFirstStoreDelivery
        })
    }

    /// Incognito never subscribes to the store at all, so the signal has to
    /// start satisfied rather than wait on a delivery that cannot come.
    func testIncognitoResolvesFirstDeliveryWithoutSubscribing() throws {
        let store = try makeStore()
        let state = BrowserState(windowId: 9,
                                 localStore: store,
                                 profileId: "Default",
                                 isIncognito: true)
        XCTAssertTrue(state.bookmarkManager.didApplyFirstStoreDelivery)
    }

    /// The ordering contract the gate rests on: at signal time the delivery
    /// has already re-projected `normalTabs`, so a consumer that paints on
    /// the signal shows the post-absorption list instead of the one it
    /// replaces.
    func testFirstDeliveryFiresAfterBookmarkBackedTabLeavesNormalTabs() throws {
        let store = try makeStore()
        let bookmarkGuid = "bookmark-first-delivery"

        // Seed through one window so the row exists before the window under
        // test subscribes — that window's first delivery then carries it.
        let seedState = try makeState(in: store)
        XCTAssertTrue(waitUntil {
            seedState.bookmarkManager.didApplyFirstStoreDelivery
        })
        store.createBookmark(url: "https://bookmark.example",
                             title: "Bookmark",
                             profileId: seedState.profileId,
                             parentId: nil,
                             guid: bookmarkGuid,
                             spaceId: seedState.spaceId)
        XCTAssertTrue(waitUntil {
            seedState.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        })

        let state = try makeState(in: store)
        let tab = Tab(guid: 301,
                      url: "https://bookmark.example",
                      isActive: true,
                      index: 0,
                      title: "Bookmark",
                      customGuid: bookmarkGuid)
        state.tabs = [tab]
        state.updateNormalTabs()

        // Before the delivery the window cannot know this tab is a bookmark,
        // and projects it as an ordinary one. This is the state the gate
        // exists to keep off screen.
        XCTAssertFalse(state.bookmarkManager.didApplyFirstStoreDelivery)
        XCTAssertEqual(state.normalTabs.map(\.guid), [301])

        var normalTabsAtSignal: [Int]?
        let cancellable = state.bookmarkManager.$didApplyFirstStoreDelivery
            .filter { $0 }
            .prefix(1)
            .sink { _ in normalTabsAtSignal = state.normalTabs.map(\.guid) }
        defer { cancellable.cancel() }

        XCTAssertTrue(waitUntil { normalTabsAtSignal != nil })
        XCTAssertEqual(try XCTUnwrap(normalTabsAtSignal), [])
        XCTAssertTrue(try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: bookmarkGuid)).isOpened)
    }

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return LocalStore(account: Account(userID: UUID().uuidString),
                          storeDirectoryURL: directory)
    }

    private func makeState(in store: LocalStore) throws -> BrowserState {
        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        // `bookmarkManager` is lazy; the subscription only starts once it is
        // touched, which is what the window's own init does.
        _ = state.bookmarkManager
        return state
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }
}
