// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import XCTest
@testable import Phi

/// State-layer coverage for the extension side panel slot: open/close
/// bookkeeping, the synchronous outgoing-view detach contract, the
/// AI Chat ↔ panel mutex (both directions), and the slot width clamping.
/// Container-layer layout coverage lives in
/// `ExtensionSidePanelContainerLayoutTests` below.
@MainActor
final class BrowserStateExtensionSidePanelTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var originalPhiAIEnabled: Any?

    override func setUpWithError() throws {
        // The AI Chat expand path is gated on the AI preference; pin it on
        // and restore the user's value afterwards.
        let key = PhiPreferences.AISettings.phiAIEnabled.rawValue
        originalPhiAIEnabled = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
    }

    override func tearDownWithError() throws {
        let key = PhiPreferences.AISettings.phiAIEnabled.rawValue
        if let originalPhiAIEnabled {
            UserDefaults.standard.set(originalPhiAIEnabled, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        originalPhiAIEnabled = nil

        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeBrowserState() throws -> BrowserState {
        let directory = try makeTemporaryStoreDirectory()
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    @discardableResult
    private func seed(state: BrowserState, guids: [Int]) -> [Tab] {
        let tabs = guids.map {
            Tab(guid: $0, url: "https://tab\($0).example", isActive: false, index: 0)
        }
        state.tabs = tabs
        state.updateNormalTabs()
        return tabs
    }

    private func makePanel(
        extensionId: String = "test-extension",
        wrapper: ExtensionSidePanelTestWebContentWrapper
    ) -> BrowserState.ExtensionSidePanelState {
        BrowserState.ExtensionSidePanelState(extensionId: extensionId,
                                             displayName: "Test Extension",
                                             iconPNG: nil,
                                             wrapper: wrapper)
    }

    // MARK: - Slot open/close

    func testOpenAndClosePublishPanelState() throws {
        let state = try makeBrowserState()
        let wrapper = ExtensionSidePanelTestWebContentWrapper()

        state.updateExtensionSidePanel(makePanel(wrapper: wrapper))

        XCTAssertEqual(state.extensionSidePanel?.extensionId, "test-extension")
        XCTAssertEqual(state.extensionSidePanel?.displayName, "Test Extension")
        XCTAssertTrue(state.extensionSidePanel?.wrapper === wrapper)

        state.updateExtensionSidePanel(nil)

        XCTAssertNil(state.extensionSidePanel)
    }

    func testCloseDetachesOutgoingNativeViewSynchronously() throws {
        let state = try makeBrowserState()
        let superview = NSView()
        let nativeView = NSView()
        superview.addSubview(nativeView)
        let wrapper = ExtensionSidePanelTestWebContentWrapper()
        wrapper.nativeView = nativeView
        state.updateExtensionSidePanel(makePanel(wrapper: wrapper))

        state.updateExtensionSidePanel(nil)

        XCTAssertNil(nativeView.superview)
    }

    func testClosePublishesBeforeDetachingOutgoingView() throws {
        let state = try makeBrowserState()
        let superview = NSView()
        let nativeView = NSView()
        superview.addSubview(nativeView)
        let wrapper = ExtensionSidePanelTestWebContentWrapper()
        wrapper.nativeView = nativeView
        state.updateExtensionSidePanel(makePanel(wrapper: wrapper))

        // The container's synchronous sink snapshots the closing panel for
        // its slide-out animation, so the close publish must arrive while
        // the outgoing NSView is still in the hierarchy. The backstop
        // detach after the publish keeps the synchronous-detach contract
        // when no sink detaches the view itself.
        var attachedAtClosePublish: Bool?
        let cancellable = state.$extensionSidePanel
            .dropFirst()  // subscription replay of the open panel
            .sink { panel in
                if panel == nil {
                    attachedAtClosePublish = nativeView.superview != nil
                }
            }
        defer { cancellable.cancel() }

        state.updateExtensionSidePanel(nil)

        XCTAssertEqual(attachedAtClosePublish, true)
        XCTAssertNil(nativeView.superview)
    }

    func testContentReplacementDetachesOutgoingNativeView() throws {
        let state = try makeBrowserState()
        let superview = NSView()
        let outgoingView = NSView()
        superview.addSubview(outgoingView)
        let outgoing = ExtensionSidePanelTestWebContentWrapper()
        outgoing.nativeView = outgoingView
        state.updateExtensionSidePanel(makePanel(extensionId: "a", wrapper: outgoing))

        let incoming = ExtensionSidePanelTestWebContentWrapper()
        state.updateExtensionSidePanel(makePanel(extensionId: "b", wrapper: incoming))

        XCTAssertNil(outgoingView.superview)
        XCTAssertEqual(state.extensionSidePanel?.extensionId, "b")
    }

    // MARK: - Mutex: panel open collapses AI Chat

    func testPanelOpenCollapsesAIChatOnAllTabs() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, guids: [100, 200, 300])
        tabs[0].aiChatCollapsed = false
        tabs[2].aiChatCollapsed = false
        state.aiChatCollapsed = false

        state.updateExtensionSidePanel(
            makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper()))

        XCTAssertTrue(tabs.allSatisfy { $0.aiChatCollapsed })
        XCTAssertTrue(state.aiChatCollapsed)
    }

    // MARK: - Mutex: AI Chat expand closes the panel first

    func testAIChatExpandClosesPanelBeforeExpanding() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, guids: [100])
        state.focuseTab(tabs[0])
        state.updateExtensionSidePanel(
            makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper()))
        XCTAssertTrue(tabs[0].aiChatCollapsed)

        var chatWasStillCollapsedAtCloseRequest = false
        var closeRequests = 0
        state.extensionSidePanelCloseRequestOverrideForTesting = { [weak state, weak tab = tabs[0]] in
            closeRequests += 1
            chatWasStillCollapsedAtCloseRequest = tab?.aiChatCollapsed ?? false
            // Simulate Chromium's synchronous close push back over the bridge.
            state?.updateExtensionSidePanel(nil)
        }

        state.toggleAIChat(false)

        XCTAssertEqual(closeRequests, 1)
        XCTAssertTrue(chatWasStillCollapsedAtCloseRequest)
        XCTAssertNil(state.extensionSidePanel)
        XCTAssertFalse(tabs[0].aiChatCollapsed)
    }

    func testMirroredExpandViaSetAIChatCollapsedClosesPanel() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, guids: [100])
        state.updateExtensionSidePanel(
            makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper()))

        var closeRequests = 0
        state.extensionSidePanelCloseRequestOverrideForTesting = { [weak state] in
            closeRequests += 1
            state?.updateExtensionSidePanel(nil)
        }

        state.setAIChatCollapsed(for: tabs[0], collapsed: false)

        XCTAssertEqual(closeRequests, 1)
        XCTAssertNil(state.extensionSidePanel)
        XCTAssertFalse(tabs[0].aiChatCollapsed)
    }

    func testAIChatCollapseLeavesPanelOpen() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, guids: [100])
        state.focuseTab(tabs[0])
        state.updateExtensionSidePanel(
            makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper()))

        var closeRequests = 0
        state.extensionSidePanelCloseRequestOverrideForTesting = { closeRequests += 1 }

        state.toggleAIChat(true)
        state.setAIChatCollapsed(for: tabs[0], collapsed: true)

        XCTAssertEqual(closeRequests, 0)
        XCTAssertNotNil(state.extensionSidePanel)
    }

    // MARK: - Slot width

    func testPanelViewClampsWidth() {
        XCTAssertEqual(ExtensionSidePanelView.clampedWidth(100), ExtensionSidePanelView.minWidth)
        XCTAssertEqual(ExtensionSidePanelView.clampedWidth(9999), ExtensionSidePanelView.maxWidth)
        XCTAssertEqual(ExtensionSidePanelView.clampedWidth(500), 500)

        let panel = ExtensionSidePanelView(initialWidth: 100)
        XCTAssertEqual(panel.preferredWidth, ExtensionSidePanelView.minWidth)

        panel.setPreferredWidth(640)
        XCTAssertEqual(panel.preferredWidth, 640)

        panel.setPreferredWidth(12000)
        XCTAssertEqual(panel.preferredWidth, ExtensionSidePanelView.maxWidth)
    }
}

/// Container-layer coverage for the extension side panel slot: the 4pt
/// page-to-panel gap, the attach/detach end states (slide animations
/// disabled so layout settles synchronously), and the per-window width
/// memory across a close/reopen.
@MainActor
final class ExtensionSidePanelContainerLayoutTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func setUpWithError() throws {
        WebContentContainerViewController.panelSlideAnimationsDisabledForTesting = true
    }

    override func tearDownWithError() throws {
        WebContentContainerViewController.panelSlideAnimationsDisabledForTesting = false
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeContainer() throws -> WebContentContainerViewController {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 8, localStore: store, profileId: "Default")
        let container = WebContentContainerViewController(state: state)
        container.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        return container
    }

    private func makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper)
        -> BrowserState.ExtensionSidePanelState {
        BrowserState.ExtensionSidePanelState(extensionId: "test-extension",
                                             displayName: "Test Extension",
                                             iconPNG: nil,
                                             wrapper: wrapper)
    }

    func testAttachSettlesWithFourPointPageGap() throws {
        let container = try makeContainer()
        let nativeView = NSView()
        let wrapper = ExtensionSidePanelTestWebContentWrapper()
        wrapper.nativeView = nativeView

        container.attachExtensionSidePanel(makePanel(wrapper: wrapper))
        container.view.layoutSubtreeIfNeeded()

        let panelView = try XCTUnwrap(container.extensionSidePanelViewForTesting)
        XCTAssertTrue(nativeView.superview === panelView.contentHostView)
        // Panel pinned edgesSpacing (8pt) off the window edge at its
        // seeded preferred width.
        XCTAssertEqual(panelView.frame.maxX, 1200 - 8, accuracy: 0.5)
        XCTAssertEqual(panelView.frame.width, 360, accuracy: 0.5)
        // The content container overlaps 4pt under the panel; the page
        // card's own 8pt margin inside it nets the AI-Chat-matching 4pt
        // page-to-panel gap.
        XCTAssertEqual(container.splitTabDropContainer.frame.maxX,
                       panelView.frame.minX + 4, accuracy: 0.5)
    }

    func testDetachRestoresFullWidthAndRemembersDraggedWidth() throws {
        let container = try makeContainer()
        let firstNative = NSView()
        let firstWrapper = ExtensionSidePanelTestWebContentWrapper()
        firstWrapper.nativeView = firstNative
        container.attachExtensionSidePanel(makePanel(wrapper: firstWrapper))
        container.view.layoutSubtreeIfNeeded()
        let firstPanel = try XCTUnwrap(container.extensionSidePanelViewForTesting)
        firstPanel.setPreferredWidth(500)

        container.detachExtensionSidePanel()
        container.view.layoutSubtreeIfNeeded()

        XCTAssertNil(container.extensionSidePanelViewForTesting)
        XCTAssertNil(firstPanel.superview)
        XCTAssertEqual(container.splitTabDropContainer.frame.maxX, 1200, accuracy: 0.5)

        let secondNative = NSView()
        let secondWrapper = ExtensionSidePanelTestWebContentWrapper()
        secondWrapper.nativeView = secondNative
        container.attachExtensionSidePanel(makePanel(wrapper: secondWrapper))
        container.view.layoutSubtreeIfNeeded()

        let secondPanel = try XCTUnwrap(container.extensionSidePanelViewForTesting)
        XCTAssertEqual(secondPanel.preferredWidth, 500)
        XCTAssertEqual(secondPanel.frame.width, 500, accuracy: 0.5)
    }
}

/// Minimal `WebContentWrapper` conformance for panel-state tests (same
/// pattern as `BookmarkLayoutTestWebContentWrapper`). `nativeView` is weak,
/// matching the protocol — tests must hold the NSView strongly themselves.
private final class ExtensionSidePanelTestWebContentWrapper: NSObject, WebContentWrapper {
    @objc dynamic weak var nativeView: NSView?
    @objc dynamic var isLoading = false
    @objc dynamic var loadingState = PhiTabLoadingState(rawValue: 0)!
    @objc dynamic var isFocused = false
    @objc dynamic var loadProgress: CGFloat = 1
    @objc dynamic var favIconURL: String?
    @objc dynamic var favIconData: Data?
    @objc dynamic var favIconRevision = 0
    @objc dynamic var canGoBack = false
    @objc dynamic var canGoForward = false
    @objc dynamic var title: String?
    @objc dynamic var urlString: String?
    @objc dynamic var securityInfo: [String: Any]?
    @objc dynamic var isCurrentlyAudible = false
    @objc dynamic var isAudioMuted = false
    @objc dynamic var isCapturingAudio = false
    @objc dynamic var isCapturingVideo = false
    @objc dynamic var isCapturingWindow = false
    @objc dynamic var isCapturingDisplay = false
    @objc dynamic var isCapturingTab = false
    @objc dynamic var isBeingMirrored = false
    @objc dynamic var isSharingScreen = false
    @objc dynamic var isInContentFullscreen = false
    @objc dynamic var isDistillable = false
    @objc dynamic var devToolsTargetId: String?

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

    func close() {}
    func reload() {}
    func reloadBypassingCache() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func navigate(toURL urlString: String) { self.urlString = urlString }
    func setAsActiveTab() {}
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(toWindow targetWindowId: Int64,
                  andAddToGroupTokenHex targetGroupTokenHex: String,
                  beforeTabId anchorTabId: Int64) {}
    func moveSelf(toWindow targetWindowId: Int64,
                  andAddToGroupTokenHex targetGroupTokenHex: String,
                  afterTabId anchorTabId: Int64) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) {}
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}
