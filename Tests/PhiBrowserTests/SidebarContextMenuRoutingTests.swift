// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class SidebarContextMenuRoutingTests: XCTestCase {
    func testRightMouseDownIsContextMenuTrigger() throws {
        let event = try makeMouseDown(type: .rightMouseDown)

        XCTAssertTrue(ContextMenuEvent.isMouseDown(event))
    }

    func testControlLeftMouseDownIsContextMenuTrigger() throws {
        let event = try makeMouseDown(type: .leftMouseDown, modifiers: [.control])

        XCTAssertTrue(ContextMenuEvent.isMouseDown(event))
    }

    func testUnmodifiedAndCommandLeftMouseDownAreNotContextMenuTriggers() throws {
        let plainEvent = try makeMouseDown(type: .leftMouseDown)
        let commandEvent = try makeMouseDown(type: .leftMouseDown, modifiers: [.command])

        XCTAssertFalse(ContextMenuEvent.isMouseDown(plainEvent))
        XCTAssertFalse(ContextMenuEvent.isMouseDown(commandEvent))
    }

    func testPinnedExtensionControlClickUsesSecondaryActionOnly() throws {
        let view = PinnedExtensionContextView()
        view.handlesControlClick = true
        var primaryClickCount = 0
        var secondaryClickCount = 0
        view.clickAction = { primaryClickCount += 1 }
        view.secondaryClickAction = { secondaryClickCount += 1 }

        view.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            modifiers: [.control]
        ))
        view.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            modifiers: [.control]
        ))

        XCTAssertEqual(primaryClickCount, 0)
        XCTAssertEqual(secondaryClickCount, 1)
    }

    func testPinnedExtensionPlainClickKeepsPrimaryAction() throws {
        let view = PinnedExtensionContextView()
        view.handlesControlClick = true
        var primaryClickCount = 0
        var secondaryClickCount = 0
        view.clickAction = { primaryClickCount += 1 }
        view.secondaryClickAction = { secondaryClickCount += 1 }

        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp))

        XCTAssertEqual(primaryClickCount, 1)
        XCTAssertEqual(secondaryClickCount, 0)
    }

    func testSidebarContextMenuPreservesTextEditingTargets() {
        let outlineView = SideBarOutlineView()
        let textField = NSTextField()
        textField.isEditable = true
        outlineView.addSubview(textField)
        let fieldEditor = NSTextView()
        outlineView.addSubview(fieldEditor)

        XCTAssertTrue(outlineView.contextMenuHitTarget(from: textField) === textField)
        XCTAssertTrue(outlineView.contextMenuHitTarget(from: fieldEditor) === fieldEditor)
    }

    func testSidebarContextMenuCapturesNonEditingTargets() {
        let outlineView = SideBarOutlineView()
        let rowContentView = NSView()
        outlineView.addSubview(rowContentView)

        XCTAssertTrue(outlineView.contextMenuHitTarget(from: rowContentView) === outlineView)
    }

    private func makeMouseDown(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try makeMouseEvent(type: type, modifiers: modifiers)
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }
}
