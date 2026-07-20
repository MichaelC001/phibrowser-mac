// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit
@testable import Phi

final class PhiBrowserTests: XCTestCase {
    func testCopyURLShortcutIsCustomizableFromEditShortcuts() {
        XCTAssertEqual(
            Shortcuts.DefaultShortcuts[.PHI_COPY_URL],
            ShortcutsKey(characters: "c", modifiers: [.command, .shift])
        )
        XCTAssertTrue(Shortcuts.Group.edit.commands.contains(.PHI_COPY_URL))
        XCTAssertEqual(CommandWrapper.PHI_COPY_URL.displayName, "Copy URL")
    }

    func testCopyURLShortcutKeycapsMatchMacModifierOrder() {
        let shortcut = ShortcutsKey(characters: "c", modifiers: [.command, .shift])

        XCTAssertEqual(shortcut.keycapTokens, ["⇧", "⌘", "C"])
    }

    func testShortcutKeycapsUseReadableSpecialKeySymbols() {
        let shortcut = ShortcutsKey(
            characters: "\u{F702}",
            modifiers: [.control, .option]
        )

        XCTAssertEqual(shortcut.keycapTokens, ["⌃", "⌥", "←"])
        XCTAssertEqual(shortcut.displayString, "⌥⌃←")
    }

    func testShortcutCaptureNormalizesShiftTabToTabCharacter() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(format: "%c", NSBackTabCharacter),
                charactersIgnoringModifiers: String(format: "%c", NSBackTabCharacter),
                isARepeat: false,
                keyCode: 48
            )
        )

        let keyChord = try XCTUnwrap(KeyChord(fromEvent: event))
        let shortcut = ShortcutsKey(
            characters: keyChord.characters,
            modifiers: keyChord.modifiers
        )

        XCTAssertEqual(keyChord.characters, "\t")
        XCTAssertEqual(keyChord.modifiers, [.control, .shift])
        XCTAssertEqual(shortcut.displayString, "⇧⌃⇥")
    }

    func testThemeSnapshotRoundTripPreservesEditableColorsAndOverlayOpacity() {
        let theme = Theme(id: "theme-snapshot-round-trip", name: "Snapshot")
        theme.setColor(
            light: NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.30, alpha: 0.45),
            dark: NSColor(calibratedRed: 0.70, green: 0.60, blue: 0.50, alpha: 0.85),
            for: .windowOverlayBackground
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.35, alpha: 1.0),
            dark: NSColor(calibratedRed: 0.65, green: 0.55, blue: 0.45, alpha: 1.0),
            for: .windowBackground
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.60, alpha: 1.0),
            dark: NSColor(calibratedRed: 0.60, green: 0.40, blue: 0.20, alpha: 1.0),
            for: .themeColor
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.30, green: 0.50, blue: 0.70, alpha: 1.0),
            dark: NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.30, alpha: 1.0),
            for: .extensionActonColor
        )

        let restoredTheme = theme.makeSnapshot().makeTheme()

        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            equals: theme.color(for: .windowOverlayBackground, appearance: .light)
        )
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            equals: theme.color(for: .windowOverlayBackground, appearance: .dark)
        )
        assertColor(
            restoredTheme.color(for: .windowBackground, appearance: .light),
            equals: theme.color(for: .windowBackground, appearance: .light)
        )
        assertColor(
            restoredTheme.color(for: .themeColor, appearance: .dark),
            equals: theme.color(for: .themeColor, appearance: .dark)
        )
        assertColor(
            restoredTheme.color(for: .extensionActonColor, appearance: .light),
            equals: theme.color(for: .extensionActonColor, appearance: .light)
        )
        XCTAssertEqual(
            restoredTheme.windowOverlayOpacity(for: .light),
            0.45,
            accuracy: 0.001,
            "Theme snapshots should preserve the customized light overlay alpha."
        )
        XCTAssertEqual(
            restoredTheme.windowOverlayOpacity(for: .dark),
            0.85,
            accuracy: 0.001,
            "Theme snapshots should preserve the customized dark overlay alpha."
        )
    }

    func testNormalizedThemeSliderTrackColorKeepsRgbAndForcesFullOpacity() {
        let sourceColor = NSColor(calibratedRed: 0.21, green: 0.42, blue: 0.63, alpha: 0.37)

        let normalizedColor = normalizedThemeSliderTrackColor(from: sourceColor)

        assertColor(
            normalizedColor,
            equals: NSColor(calibratedRed: 0.21, green: 0.42, blue: 0.63, alpha: 1.0)
        )
    }

    @MainActor
    func testBrowserThemeContextPublishesThemeChangesForSameThemeIdentifier() {
        let initialTheme = Theme(id: "browser-context-same-id", name: "Context")
        initialTheme.setColor(
            light: NSColor(hex: 0x445566, alpha: 0.40),
            dark: NSColor(hex: 0x112233, alpha: 0.80),
            for: .windowOverlayBackground
        )

        let context = BrowserThemeContext(
            configuration: BrowserThemeConfiguration(
                currentTheme: initialTheme,
                userAppearanceChoice: .light,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        )

        var observedLightOverlayOpacity: [CGFloat] = []
        let subscription = context.subscribe { theme, appearance in
            observedLightOverlayOpacity.append(theme.windowOverlayOpacity(for: appearance))
        }

        let updatedTheme = initialTheme.makeSnapshot()
            .updatingOverlayOpacity(0.72, for: .light)
            .makeTheme()
        context.setTheme(updatedTheme)

        _ = subscription

        XCTAssertEqual(
            observedLightOverlayOpacity,
            [0.40, 0.72],
            "Replacing a window theme with a new instance that keeps the same theme identifier should still notify subscribers so overlay alpha changes hot-update active UI."
        )
    }

    func testBookmarkMainMenuItemRoutingKeepsChromiumBookmarksItemUntouched() {
        let action = BookmarkMainMenuItemRouting.action(
            title: "Bookmarks",
            tag: 40029
        )

        XCTAssertEqual(
            action,
            .hideSystemItem,
            "The Chromium-owned Bookmarks menu item must stay discoverable by IDC_BOOKMARKS_MENU so AppController should only hide it instead of repurposing it as the native custom Bookmarks menu."
        )
    }

    func testBookmarkMainMenuItemRoutingRecognizesCustomBookmarksItem() {
        let action = BookmarkMainMenuItemRouting.action(
            title: "Bookmarks",
            tag: AppController.bookmarksMenuItemTag
        )

        XCTAssertEqual(
            action,
            .configureCustomItem,
            "The native Phi Bookmarks item should be the only menu item that gets reconfigured and rebuilt."
        )
    }

    func testBookmarkMenuContentBuilderAddsBookmarkThisTabAndRecursiveBookmarks() {
        let rootBookmark = Bookmark(title: "Phi", url: "https://phibrowser.com")
        let folder = Bookmark(folderTitle: "Favorites")
        let childBookmark = Bookmark(title: "Docs", url: "https://docs.phibrowser.com")
        folder.addChild(childBookmark)
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [rootBookmark, folder],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: true,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertEqual(
            menu.items.first?.title,
            NSLocalizedString("Bookmark This Tab...", comment: "Bookmarks menu - Menu item to add or edit a bookmark for the currently focused tab")
        )
        XCTAssertEqual(menu.items.first?.tag, CommandWrapper.IDC_BOOKMARK_THIS_TAB.rawValue)
        XCTAssertEqual(
            menu.items.dropFirst().first?.title,
            NSLocalizedString("Bookmark All Tabs...", comment: "Bookmarks menu - Menu item to add bookmarks for all currently open tabs in the active window")
        )
        XCTAssertEqual(menu.items.dropFirst().first?.tag, CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue)
        XCTAssertTrue(
            menu.items.first?.isEnabled == true,
            "The Bookmarks menu should enable the Bookmark This Tab item when the active window has a focusable tab URL."
        )
        XCTAssertTrue(menu.items.dropFirst(2).first?.isSeparatorItem == true)
        XCTAssertEqual(
            menu.items.dropFirst(3).first?.title,
            NSLocalizedString("Export Bookmarks...", comment: "Bookmarks menu - Menu item to export the current Space's bookmarks to an HTML file")
        )
        XCTAssertTrue(menu.items.dropFirst(4).first?.isSeparatorItem == true)
        XCTAssertEqual(menu.items.dropFirst(5).map(\.title), ["Phi", "Favorites"])
        XCTAssertEqual(menu.items.last?.submenu?.items.map(\.title), ["Docs"])
    }

    func testBookmarkMenuContentBuilderDisablesBookmarkThisTabWithoutFocusedTab() {
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [],
            canBookmarkCurrentTab: false,
            canBookmarkAllTabs: false,
            canExportBookmarks: false,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertFalse(
            menu.items.first?.isEnabled == true,
            "The Bookmarks menu should disable the Bookmark This Tab item when there is no focused tab with a bookmarkable URL."
        )
        XCTAssertFalse(
            menu.items.dropFirst().first?.isEnabled == true,
            "The Bookmarks menu should disable the Bookmark All Tabs item when the active window does not have more than one bookmarkable open tab."
        )
        XCTAssertFalse(
            menu.items.dropFirst(3).first?.isEnabled == true,
            "The Bookmarks menu should disable the Export Bookmarks item when the current Space has no bookmarks to export."
        )
        XCTAssertEqual(menu.items.count, 4)
    }

    func testBookmarkMenuContentBuilderShowsDisabledEmptyItemForEmptyFolders() {
        let emptyFolder = Bookmark(folderTitle: "Empty Folder")
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [emptyFolder],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: true,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        let folderItem = menu.items[5]
        let emptyItem = try? XCTUnwrap(folderItem.submenu?.items.first)

        XCTAssertEqual(folderItem.title, "Empty Folder")
        XCTAssertEqual(
            emptyItem?.title,
            NSLocalizedString("Empty", comment: "Bookmarks menu - Disabled placeholder item shown when a bookmark folder has no child bookmarks")
        )
        XCTAssertFalse(
            emptyItem?.isEnabled == true,
            "Empty bookmark folders should show a disabled placeholder item so the submenu still renders a stable empty state."
        )
    }

    func testBookmarkMenuContentBuilderDisablesBookmarkAllTabsWithoutEnoughTabs() {
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: false,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertEqual(menu.items[1].tag, CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue)
        XCTAssertFalse(
            menu.items[1].isEnabled,
            "Bookmark All Tabs should be disabled unless the active window has more than one bookmarkable open tab."
        )
    }

    @MainActor
    func testAuthManagerStartRenewTimerDoesNotReplaceExistingValidTimer() async throws {
        let authManager = AuthManager()

        authManager.startRenewTimer()
        let firstTimer = try await waitForRenewTimer(in: authManager)

        authManager.startRenewTimer()
        let secondTimer = try await waitForRenewTimer(in: authManager)

        authManager.stopRenewTimer()

        XCTAssertTrue(
            firstTimer === secondTimer,
            "Starting the renew timer while an existing valid timer is already running should keep the original timer instance instead of invalidating and replacing it."
        )
    }

    @MainActor
    func testExtensionPopupAnchorUsesPrimaryScreenHeightForChromiumFlip() {
        let point = NSPoint(x: 240, y: 320)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumPoint = ExtensionPopupAnchor.chromiumScreenPoint(
            from: point,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(chromiumPoint.x, 240)
        XCTAssertEqual(
            chromiumPoint.y,
            580,
            "Extension popup anchors must flip against the primary display height so Swift matches Chromium's global screen coordinates."
        )
    }

    @MainActor
    func testExtensionPopupAnchorPreservesLegitimateNegativeChromiumY() {
        let point = NSPoint(x: 120, y: 960)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumPoint = ExtensionPopupAnchor.chromiumScreenPoint(
            from: point,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(
            chromiumPoint.y,
            -60,
            "Points above the primary display should remain negative after the AppKit-to-Chromium flip."
        )
    }

    @MainActor
    func testExtensionPopupAnchorRectFlipUsesPrimaryScreenHeight() {
        let appKitRect = NSRect(x: 240, y: 320, width: 100, height: 24)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumRect = ExtensionPopupAnchor.chromiumScreenRect(
            from: appKitRect,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(chromiumRect.origin.x, 240)
        XCTAssertEqual(
            chromiumRect.origin.y,
            556,
            "Anchor rects must flip as y = primary height - maxY so the rect's top edge lands in Chromium's top-left-origin screen space."
        )
        XCTAssertEqual(chromiumRect.size, appKitRect.size)
    }

    @MainActor
    func testExtensionPopupAnchorLegacyPointMatchesPointBasedConversion() {
        let appKitRect = NSRect(x: 240, y: 320, width: 100, height: 24)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let pointFromRect = ExtensionPopupAnchor.legacyAnchorPoint(
            for: ExtensionPopupAnchor.chromiumScreenRect(
                from: appKitRect,
                primaryScreenFrame: primaryFrame
            )
        )
        let pointFromBottomLeft = ExtensionPopupAnchor.chromiumScreenPoint(
            from: NSPoint(x: appKitRect.minX, y: appKitRect.minY),
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(
            pointFromRect,
            pointFromBottomLeft,
            "The old-framework fallback must reproduce the icon's visual bottom-left corner exactly as the point-based path did."
        )
    }

    func testAuthFailureTraceBufferKeepsMostRecentEntries() {
        let baseDate = Date(timeIntervalSince1970: 1_713_600_000)
        var tick: TimeInterval = 0
        let buffer = AuthFailureTraceBuffer(
            capacity: 2,
            dateProvider: {
                defer { tick += 1 }
                return baseDate.addingTimeInterval(tick)
            }
        )

        buffer.record("launch-recovery", details: ["result": "skipped"])
        buffer.record("credentials", details: ["result": "loaded"])
        buffer.record("renew", details: ["result": "failed"])

        let rendered = buffer.renderedTrace()

        XCTAssertFalse(
            rendered.contains("launch-recovery"),
            "The oldest auth trace entry should be discarded once the buffer reaches capacity."
        )
        XCTAssertTrue(rendered.contains("credentials"))
        XCTAssertTrue(rendered.contains("renew"))
    }

    func testAuthFailureTraceBufferRendersCallSiteAndSortedDetails() {
        let buffer = AuthFailureTraceBuffer(
            capacity: 4,
            dateProvider: { Date(timeIntervalSince1970: 1_713_600_100) }
        )

        buffer.record(
            "transition-logout",
            details: [
                "operation": "renew credentials",
                "reason": "invalid_refresh_token"
            ],
            fileID: "Phi/AuthManager.swift",
            function: "logCredentialsFailure(_:operation:)",
            line: 321
        )

        let rendered = buffer.renderedTrace()

        XCTAssertTrue(rendered.contains("transition-logout"))
        XCTAssertTrue(rendered.contains("operation=renew credentials"))
        XCTAssertTrue(rendered.contains("reason=invalid_refresh_token"))
        XCTAssertTrue(rendered.contains("Phi/AuthManager.swift:321"))
        XCTAssertTrue(rendered.contains("logCredentialsFailure(_:operation:)"))
    }

    func testAuthFailureTraceBufferEmitsCallStackWhenProvided() {
        let buffer = AuthFailureTraceBuffer(
            capacity: 2,
            dateProvider: { Date(timeIntervalSince1970: 1_713_600_200) }
        )

        buffer.record(
            "transition-to-logged-out",
            details: ["reason": "invalid_refresh_token"],
            callStackSymbols: ["0  Phi  AuthManager.renew", "1  Phi  AuthManager.run"]
        )

        let rendered = buffer.renderedTrace()
        XCTAssertTrue(
            rendered.contains("stack:"),
            "Trace lines for forced-logout transitions must include the captured call stack so refresh-token reuse incidents can be correlated to the triggering caller."
        )
        XCTAssertTrue(rendered.contains("Phi  AuthManager.renew"))
    }

    func testLoginWindowGateKeepsOnboardingVisibleUntilAccountPhaseIsDone() {
        XCTAssertTrue(
            LoginWindowGate.shouldShowLoginWindow(
                hasRecoverableSession: true,
                accountPhase: .setName
            ),
            "A recoverable session should not bypass account-scoped onboarding before the phase reaches done."
        )
        XCTAssertFalse(
            LoginWindowGate.shouldShowLoginWindow(
                hasRecoverableSession: true,
                accountPhase: .done
            ),
            "A completed account-scoped onboarding phase should allow cold-open URLs to continue into Chromium."
        )
        XCTAssertTrue(
            LoginWindowGate.shouldShowLoginWindow(
                hasRecoverableSession: false,
                accountPhase: .done
            ),
            "Without a recoverable auth session, Phi should still present login."
        )
    }

    func testOmniBoxSearchCoordinatorSuppressesOnlyTheNextAutomaticSearchAfterPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "https://phibrowser.com", minInputLength: 1)

        XCTAssertFalse(
            coordinator.shouldPerformAutomaticSearch(for: "https://phibrowser.com", minInputLength: 1),
            "Prefilling the current tab URL should not immediately trigger a duplicate automatic search."
        )
        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "https://phibrowser.com/path", minInputLength: 1),
            "Only the next automatic search should be suppressed so later edits still update suggestions."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsResponsesMatchingTheLatestQuery() {
        let coordinator = OmniBoxSearchCoordinator()

        _ = coordinator.beginRequest(query: "phi", source: .inputChange)
        _ = coordinator.beginRequest(query: "phibrowser", source: .openPrefill)

        XCTAssertFalse(
            coordinator.shouldAcceptResponse(forQuery: "phi"),
            "Stale suggestion responses should be ignored once a newer query has been issued."
        )
        XCTAssertTrue(
            coordinator.shouldAcceptResponse(forQuery: "phibrowser"),
            "Responses matching the latest query should be applied to the UI."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsStreamedResponsesForTheSameQuery() {
        let coordinator = OmniBoxSearchCoordinator()

        _ = coordinator.beginRequest(query: "phi", source: .inputChange)

        XCTAssertTrue(coordinator.shouldAcceptResponse(forQuery: "phi"))
        // Chromium streams multiple updates per request as providers respond, every
        // subsequent emission for the same query must still be applied.
        XCTAssertTrue(coordinator.shouldAcceptResponse(forQuery: "phi"))
    }

    func testOmniBoxSearchCoordinatorDoesNotArmSuppressionForEmptyPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "", minInputLength: 1)

        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "g", minInputLength: 1),
            "An empty prefill should not consume the user's first real search edit."
        )
    }

    func testOmniBoxTraceSessionFormatsReadableElapsedLogMessages() {
        var ticks: [UInt64] = [1_000_000_000, 1_125_000_000]
        let session = OmniBoxTraceSession(
            trigger: "address-bar",
            timeProvider: { ticks.removeFirst() }
        )

        let message = session.message(for: "request-start", details: "queryLength=12")

        XCTAssertTrue(message.contains("[OmniboxTrace]"))
        XCTAssertTrue(message.contains("trigger=address-bar"))
        XCTAssertTrue(message.contains("stage=request-start"))
        XCTAssertTrue(message.contains("elapsed=125.0ms"))
        XCTAssertTrue(message.contains("queryLength=12"))
    }

    func testHoverableButtonNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let button = HoverableButtonNSView(
            config: HoverableButtonConfig(title: "Test", displayMode: .titleOnly),
            action: {}
        )
        var didInvokeSecondaryAction = false
        button.secondaryAction = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        button.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Pinned extension buttons should route right clicks through their secondary action."
        )
    }

    func testHoverableViewInvokesSecondaryClickActionOnRightMouseDown() throws {
        let view = HoverableView()
        var didInvokeSecondaryClick = false
        view.secondaryClickAction = {
            didInvokeSecondaryClick = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryClick,
            "Sidebar pinned extension items should route right clicks through their secondary click action."
        )
    }

    func testSecondaryClickPassthroughNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickPassthroughNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover extension items should route right clicks through the shared secondary click passthrough."
        )
    }

    func testSecondaryClickContainerNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickContainerNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover grid items should handle right clicks through their dedicated AppKit container."
        )
    }

    @MainActor
    private func waitForRenewTimer(
        in authManager: AuthManager,
        timeout: TimeInterval = 1
    ) async throws -> Timer {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let timer = renewTimer(in: authManager), timer.isValid {
                return timer
            }
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTFail("Expected renew timer to become available before timeout.")
        throw NSError(domain: "PhiBrowserTests", code: 1)
    }

    private func renewTimer(in authManager: AuthManager) -> Timer? {
        Mirror(reflecting: authManager).descendant("renewTimer") as? Timer
    }

    private func assertColor(
        _ actual: NSColor,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualColor = actual.usingColorSpace(.extendedSRGB) ?? actual
        let expectedColor = expected.usingColorSpace(.extendedSRGB) ?? expected

        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}

private final class BookmarkMenuTestTarget: NSObject {
    @objc func menuAction(_ sender: Any?) {}
}
