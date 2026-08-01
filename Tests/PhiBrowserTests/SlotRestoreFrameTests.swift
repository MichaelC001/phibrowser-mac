// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The slot restore snapshot remembers where a slot's window sat, so a reopen
/// has a position on hand before Chromium reports the restored window's bounds.
/// The display that frame was saved against may be gone, smaller, or rearranged
/// by then, so it is read back through a clamp — and the same clamp repairs a
/// live slot after a screen-layout change, which is what keeps the two agreeing.
///
/// These pin the clamp's rule down by table. It is deliberately far weaker than
/// AppKit's own constraint: a frame the user dragged half off an edge stays
/// there, and only the states they cannot get out of are corrected.
final class SlotRestoreFrameTests: XCTestCase {
    // A 1440x900 laptop display at the origin, menu bar removed.
    private let primary = SpaceManager.ScreenGeometry(
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 862)
    )
    // A larger display placed to the right of the primary.
    private let secondary = SpaceManager.ScreenGeometry(
        frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)
    )

    // MARK: - Frames that must survive untouched

    func testLeavesAFrameThatStillFitsItsWorkAreaExactlyWhereItIs() {
        let frame = NSRect(x: 200, y: 100, width: 900, height: 600)

        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [primary, secondary]),
            frame
        )
    }

    func testKeepsAFrameStraddlingTwoDisplaysWhereTheUserPutIt() {
        // 100pt on the primary, 700pt on the secondary: the secondary hosts it,
        // and it fits there, so straddling the seam is not a state to repair.
        let frame = NSRect(x: 1340, y: 100, width: 800, height: 600)

        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [primary, secondary]),
            frame
        )
    }

    func testLeavesAScreenSizedFrameAlone() {
        // A frame covering a whole display is a fullscreen frame — macOS
        // resizes those itself, and pulling it into the work area would drag a
        // fullscreen window down by the height of the menu bar.
        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(primary.frame, toScreens: [primary, secondary]),
            primary.frame
        )
    }

    func testReturnsTheFrameUnchangedWhenNoDisplayIsAttached() {
        // Clamshell, or every display asleep. There is nothing to clamp to, and
        // the clamp must still answer with a frame.
        let frame = NSRect(x: 200, y: 100, width: 900, height: 600)

        XCTAssertEqual(SpaceManager.clampedSlotFrame(frame, toScreens: []), frame)
    }

    // MARK: - Frames that have to be brought back

    func testPullsAFrameBackToTheRemainingDisplayWhenItsOwnIsUnplugged() {
        // Saved on the secondary; only the primary is attached now.
        let frame = NSRect(x: 1800, y: 200, width: 900, height: 600)

        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [primary]),
            // Top-left of the surviving work area, at its saved size.
            NSRect(x: 0, y: 262, width: 900, height: 600)
        )
    }

    func testShrinksAFrameTooLargeForTheDisplayItComesBackOn() {
        let smallDisplay = SpaceManager.ScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
            visibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 700)
        )
        let frame = NSRect(x: 50, y: 400, width: 1600, height: 1000)

        // Shrunk to the work area and dropped until its top edge fits. The x
        // origin is deliberately NOT pulled in: 50 + 1280 overhangs the right
        // edge, and an overhang the user can still grab is not a state to
        // repair.
        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [smallDisplay]),
            NSRect(x: 50, y: 0, width: 1280, height: 700)
        )
    }

    func testRehomesAFrameThatLandsOnNoDisplayAtAll() {
        // Off to the left and below everything — no work area to grab.
        let frame = NSRect(x: -3000, y: -2000, width: 800, height: 600)

        XCTAssertEqual(
            SpaceManager.clampedSlotFrame(frame, toScreens: [primary, secondary]),
            // The first listed display is the primary, so a homeless frame
            // always lands there rather than on whichever display sorts first.
            NSRect(x: 0, y: 262, width: 800, height: 600)
        )
    }

    // MARK: - Reading a stored frame back

    func testReadsNoFrameFromASnapshotEntryWrittenBeforeTheFieldExisted() {
        XCTAssertNil(SpaceManager.decodedSlotFrame(nil))
        // And nothing usable from an entry whose value is not even a string.
        XCTAssertNil(SpaceManager.decodedSlotFrame(42))
    }

    func testReadsNoFrameFromAnUnparseableValue() {
        XCTAssertNil(SpaceManager.decodedSlotFrame("not a rect"))
        // A zero rect is what an unreadable string decodes to, and is not a
        // frame any window ever had.
        XCTAssertNil(SpaceManager.decodedSlotFrame(NSStringFromRect(.zero)))
    }

    func testRoundTripsAFrameThroughItsStoredForm() {
        let frame = NSRect(x: 320, y: 148, width: 1180, height: 742)

        XCTAssertEqual(SpaceManager.decodedSlotFrame(NSStringFromRect(frame)), frame)
    }
}
