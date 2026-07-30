// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class PinnedTabDoubleClickTests: XCTestCase {
    func testHoverableViewRoutesSecondClickToDoubleClickAction() throws {
        let view = HoverableView()
        var clickCount = 0
        var doubleClickCount = 0
        var doubleClickModifierFlags: NSEvent.ModifierFlags = []
        view.clickAction = { clickCount += 1 }
        view.doubleClickAction = { event in
            doubleClickCount += 1
            doubleClickModifierFlags = event.modifierFlags
        }

        view.mouseUp(with: try makeMouseEvent(at: .zero, clickCount: 1))
        view.mouseUp(with: try makeMouseEvent(
            at: .zero,
            clickCount: 2,
            modifierFlags: [.command]
        ))

        XCTAssertEqual(clickCount, 1)
        XCTAssertEqual(doubleClickCount, 1)
        XCTAssertTrue(doubleClickModifierFlags.contains(.command))
    }

    func testHoverableViewPreservesSingleClickModifierFlags() throws {
        let view = HoverableView()
        var clickModifierFlags: NSEvent.ModifierFlags = []
        view.clickActionWithModifierFlags = { modifierFlags in
            clickModifierFlags = modifierFlags
        }

        view.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            at: .zero,
            clickCount: 1,
            modifierFlags: [.option]
        ))
        view.mouseUp(with: try makeMouseEvent(at: .zero, clickCount: 1))

        XCTAssertTrue(clickModifierFlags.isPureOptionClick)
    }

    func testSidebarPinnedSplitDoubleClickRoutesToClickedPane() throws {
        let leftTab = Tab(guid: 1, url: "https://left.example", isActive: true, index: 0)
        let rightTab = Tab(guid: 2, url: "https://right.example", isActive: false, index: 1)
        let item = PinnedSplitItem()
        item.view.frame = CGRect(x: 0, y: 0, width: 54, height: 54)
        item.configure(leftTab: leftTab, rightTab: rightTab, themeProvider: ThemeManager.shared)
        let window = makeHostWindow(for: item.view)
        item.view.layoutSubtreeIfNeeded()

        let backgroundView = try XCTUnwrap(item.view.subviews.first as? HoverableView)
        var doubleClickedTab: Tab?
        var doubleClickModifierFlags: NSEvent.ModifierFlags = []
        item.itemDoubleClicked = { tab, modifierFlags in
            doubleClickedTab = tab
            doubleClickModifierFlags = modifierFlags
        }

        backgroundView.mouseUp(with: try makeMouseEvent(
            at: NSPoint(x: backgroundView.bounds.maxX - 1, y: backgroundView.bounds.midY),
            clickCount: 2,
            modifierFlags: [.command],
            windowNumber: window.windowNumber
        ))
        XCTAssertTrue(doubleClickedTab === rightTab)
        XCTAssertTrue(doubleClickModifierFlags.contains(.command))

        backgroundView.mouseUp(with: try makeMouseEvent(
            at: NSPoint(x: backgroundView.bounds.minX + 1, y: backgroundView.bounds.midY),
            clickCount: 2,
            windowNumber: window.windowNumber
        ))
        XCTAssertTrue(doubleClickedTab === leftTab)
    }

    func testHorizontalPinnedSplitDoubleClickRoutesToClickedPane() throws {
        let leftTab = Tab(guid: 1, url: "https://left.example", isActive: true, index: 0)
        let rightTab = Tab(guid: 2, url: "https://right.example", isActive: false, index: 1)
        let view = TabItemView()
        view.frame = CGRect(x: 0, y: 0, width: 64, height: TabStripMetrics.Strip.tabHeight)
        view.configure(with: TabRenderData(
            id: "left",
            title: "Left",
            url: "https://left.example",
            isActive: true,
            isPinned: true,
            isSplitGroupActive: true,
            pinnedSplitPartner: rightTab,
            sourceTab: leftTab
        ))
        let window = makeHostWindow(for: view)

        var selectedPane = ""
        var doubleClickModifierFlags: NSEvent.ModifierFlags = []
        view.onSecondarySelect = { _ in selectedPane = "right-single" }
        view.onDoubleSelect = { modifierFlags in
            selectedPane = "left"
            doubleClickModifierFlags = modifierFlags
        }
        view.onSecondaryDoubleSelect = { modifierFlags in
            selectedPane = "right"
            doubleClickModifierFlags = modifierFlags
        }

        view.mouseUp(with: try makeMouseEvent(
            at: NSPoint(x: view.bounds.maxX - 1, y: view.bounds.midY),
            clickCount: 2,
            modifierFlags: [.command],
            windowNumber: window.windowNumber
        ))
        XCTAssertEqual(selectedPane, "right")
        XCTAssertTrue(doubleClickModifierFlags.contains(.command))

        view.mouseUp(with: try makeMouseEvent(
            at: NSPoint(x: view.bounds.minX + 1, y: view.bounds.midY),
            clickCount: 2,
            windowNumber: window.windowNumber
        ))
        XCTAssertEqual(selectedPane, "left")
    }

    private func makeHostWindow(for view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        return window
    }

    private func makeMouseEvent(
        type: NSEvent.EventType = .leftMouseUp,
        at location: NSPoint,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }
}
