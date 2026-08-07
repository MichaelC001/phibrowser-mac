// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class TitlebarTransparentViewTests: XCTestCase {
    private final class TestTitlebarAwareView: NSView, TitlebarAwareHitTestable {
        var consumesHit = false
        var receivedPoint: NSPoint?

        func shouldConsumeHitTest(at point: NSPoint) -> Bool {
            receivedPoint = point
            return consumesHit
        }
    }

    private struct Fixture {
        let window: NSWindow
        let root: TitlebarTransparentView
        let child: TestTitlebarAwareView
        let localPoint: NSPoint
        let hitTestPoint: NSPoint
    }

    private func makeFixture() -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let contentView = window.contentView!
        let root = TitlebarTransparentView(
            frame: NSRect(
                x: 40,
                y: 20,
                width: contentView.bounds.width - 80,
                height: contentView.bounds.height - 20
            )
        )
        let child = TestTitlebarAwareView(frame: root.bounds)
        root.addSubview(child)
        contentView.addSubview(root)

        let localPoint = NSPoint(
            x: root.bounds.minX + 20,
            y: root.bounds.maxY - 4
        )
        return Fixture(
            window: window,
            root: root,
            child: child,
            localPoint: localPoint,
            hitTestPoint: root.convert(localPoint, to: root.superview)
        )
    }

    func testNonConsumingTitlebarGapPassesToWindowFrame() throws {
        let fixture = makeFixture()
        fixture.child.consumesHit = false

        let hitView = fixture.root.hitTest(fixture.hitTestPoint)
        let receivedPoint = try XCTUnwrap(fixture.child.receivedPoint)

        XCTAssertNil(hitView)
        XCTAssertEqual(
            receivedPoint.x,
            fixture.localPoint.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            receivedPoint.y,
            fixture.localPoint.y,
            accuracy: 0.001
        )
    }

    func testConsumingTitlebarViewKeepsOriginalHit() {
        let fixture = makeFixture()
        fixture.child.consumesHit = true

        let hitView = fixture.root.hitTest(fixture.hitTestPoint)

        XCTAssertTrue(hitView === fixture.child)
    }

    func testPlainWebContentViewInTitlebarKeepsOriginalHit() {
        let fixture = makeFixture()
        fixture.child.removeFromSuperview()
        let webContentView = NSView(frame: fixture.root.bounds)
        fixture.root.addSubview(webContentView)

        let hitView = fixture.root.hitTest(fixture.hitTestPoint)

        XCTAssertTrue(hitView === webContentView)
    }

    func testPointBelowTitlebarKeepsOriginalHit() {
        let fixture = makeFixture()
        fixture.child.consumesHit = false
        let localPoint = NSPoint(
            x: fixture.root.bounds.midX,
            y: fixture.root.bounds.midY
        )
        let hitTestPoint = fixture.root.convert(
            localPoint,
            to: fixture.root.superview
        )

        let hitView = fixture.root.hitTest(hitTestPoint)

        XCTAssertTrue(hitView === fixture.child)
        XCTAssertNil(fixture.child.receivedPoint)
    }
}
