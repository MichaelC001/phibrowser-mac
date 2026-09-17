// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// "Open in Phi Chat" succeeded from an AI Chat panel: Chromium names the
/// panel's own tab over the bridge (`collapseAIChatForTabId:windowId:`) and
/// the window's `BrowserState` collapses the content tab hosting that panel -
/// that one only, whatever has focus by then.
@MainActor
final class BrowserStateCollapseAIChatTests: XCTestCase {
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

    /// Seeds content tabs, each with its AI Chat panel expanded and keyed in
    /// `aiChatTabs` by a chat tab whose guid is the content tab's times 100.
    private func seedTabsWithExpandedChats(_ state: BrowserState, guids: [Int]) -> [Tab] {
        let tabs = guids.map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: 0) }
        state.tabs = tabs
        state.updateNormalTabs()
        for tab in tabs {
            tab.aiChatCollapsed = false
            state.aiChatTabs[state.getTabIdentifier(for: tab)] = Tab(
                guid: tab.guid * 100, url: "chrome-extension://x/index.html", isActive: false, index: 0)
        }
        return tabs
    }

    func testCollapsesOnlyThePanelWhoseChatTabWasNamedEvenWhenAnotherTabHasFocus() throws {
        let state = try makeState()
        let tabs = seedTabsWithExpandedChats(state, guids: [1, 2])
        state.focuseTab(tabs[1])
        state.aiChatCollapsed = false

        state.handleCollapseAIChat(chatTabId: 100)

        XCTAssertTrue(tabs[0].aiChatCollapsed)
        XCTAssertFalse(tabs[1].aiChatCollapsed)
        XCTAssertFalse(state.aiChatCollapsed)
    }

    func testLeavesEveryPanelAloneWhenNoChatTabMatches() throws {
        let state = try makeState()
        let tabs = seedTabsWithExpandedChats(state, guids: [1])

        state.handleCollapseAIChat(chatTabId: 300)

        XCTAssertFalse(tabs[0].aiChatCollapsed)
    }
}
