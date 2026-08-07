// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Chromium pushes a full-strip tab -> index map on every insert / move /
/// remove (`TabsProxy::UpdateTabIndices` → `tabIndicesUpdated` →
/// `BrowserState.reorderTabs`). The echo is authoritative for tabs the Mac side
/// already holds, and it is what silently corrected restore-order drift for as
/// long as the drift went unnoticed — so the plain path needs coverage of its
/// own. Protected-slot merging (the `nativeOrderProtectedTabIds` branch) and
/// keeping hidden pinned-bound tabs out of the visible list are covered by
/// `BrowserStateHiddenOpenerInsertionTests`.
@MainActor
final class BrowserStateChromiumIndexEchoTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func seedNormalTabs(_ state: BrowserState) {
        state.tabs = [
            Tab(guid: 1, url: "https://a.example", isActive: false, index: 0),
            Tab(guid: 2, url: "https://b.example", isActive: false, index: 1),
            Tab(guid: 3, url: "https://c.example", isActive: false, index: 2),
        ]
        state.updateNormalTabs()
    }

    func testEchoResequencesExistingTabsToStripOrder() throws {
        let state = try makeState()
        seedNormalTabs(state)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3])

        // Chromium now reports the strip as 2, 3, 1.
        state.reorderTabs([2: 0, 3: 1, 1: 2])

        XCTAssertEqual(state.normalTabs.map(\.guid), [2, 3, 1])
    }

    func testEchoIgnoresTabsThatHaveNotArrivedYet() throws {
        // kInserted fires UpdateTabIndices before the new tab's own creation
        // event reaches the Mac side, so the map routinely names a tab that is
        // not in `tabs` yet. That must leave the tabs which are alone.
        let state = try makeState()
        seedNormalTabs(state)

        state.reorderTabs([1: 0, 2: 1, 3: 2, 99: 3])

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3])
    }
}
