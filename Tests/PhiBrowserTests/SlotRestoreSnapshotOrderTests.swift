// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Snapshot order — saved slot order, then previous-session window id — is the
/// only ordering the restore paths may use to choose among a snapshot's windows.
/// These pin it down for the pick a slot repair makes when its active Space
/// cannot be surfaced and one of the Spaces that did come back must take over.
final class SlotRestoreSnapshotOrderTests: XCTestCase {
    func testPicksTheEarlierEntryWhenBothHoldPresentSpaces() {
        // The first entry's window id is the higher one, so entry order has to
        // win over window id for this to pick the first entry's Space.
        let picked = SpaceManager.firstPresentSpaceInSnapshotOrder(
            windowMaps: [[70: "space-in-first-entry"], [12: "space-in-second-entry"]],
            presentSpaceIds: ["space-in-first-entry", "space-in-second-entry"]
        )

        XCTAssertEqual(picked, "space-in-first-entry")
    }

    func testPicksTheLowestWindowIdWithinAnEntryRegardlessOfSpaceIdOrder() {
        // The spaceIds sort the opposite way from their window ids, so a pick
        // that leaned on the ids' own order (or on dictionary iteration) would
        // return the other one.
        let picked = SpaceManager.firstPresentSpaceInSnapshotOrder(
            windowMaps: [[909_193_484: "aaa-space", 909_193_479: "zzz-space"]],
            presentSpaceIds: ["aaa-space", "zzz-space"]
        )

        XCTAssertEqual(picked, "zzz-space")
    }

    func testSkipsSnapshotWindowsWhoseSpaceIsAbsent() {
        let picked = SpaceManager.firstPresentSpaceInSnapshotOrder(
            windowMaps: [[1: "emptied-space", 2: "restored-space"]],
            presentSpaceIds: ["restored-space"]
        )

        XCTAssertEqual(picked, "restored-space")
    }

    func testReturnsNilWhenTheSnapshotNamesNoPresentSpace() {
        XCTAssertNil(SpaceManager.firstPresentSpaceInSnapshotOrder(
            windowMaps: [[1: "emptied-space"]],
            presentSpaceIds: ["window-opened-this-session"]
        ))
        XCTAssertNil(SpaceManager.firstPresentSpaceInSnapshotOrder(
            windowMaps: [],
            presentSpaceIds: ["restored-space"]
        ))
    }
}
