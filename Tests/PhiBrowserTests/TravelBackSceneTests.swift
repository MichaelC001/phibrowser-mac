// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import XCTest
@testable import Phi

final class TravelBackSceneTests: XCTestCase {
    private let first = TravelBackPage(url: "https://a.test/page?query=1#section")
    private let second = TravelBackPage(url: "https://b.test/page")

    func testLegacySplitDefaultsWithoutChangingMemberOrder() throws {
        let split = try TravelBackSplit(members: [first, second]).validated(for: second)
        XCTAssertEqual(split.orientation, "vertical")
        XCTAssertEqual(split.ratio, 0.5)
        XCTAssertEqual(split.activeIndex, 1)
        XCTAssertEqual(split.members, [first, second])
    }

    func testFullGeometryRoundTrips() throws {
        let split = TravelBackSplit(members: [first, second], orientation: "horizontal", ratio: 0.35, activeIndex: 1)
        let decoded = try JSONDecoder().decode(TravelBackSplit.self, from: JSONEncoder().encode(split))
        XCTAssertEqual(try decoded.validated(for: second), split)
    }

    func testInvalidOrRestrictedPairsAreRejectedBeforeRestoration() {
        for split in [
            TravelBackSplit(members: [first]),
            TravelBackSplit(members: [first, second, first]),
            TravelBackSplit(members: [first, TravelBackPage(url: "file:///private/file")]),
            TravelBackSplit(members: [first, second], orientation: "diagonal"),
            TravelBackSplit(members: [first, second], ratio: 0),
            TravelBackSplit(members: [first, second], ratio: 1),
            TravelBackSplit(members: [first, second], ratio: .nan),
            TravelBackSplit(members: [first, second], activeIndex: 2)
        ] {
            XCTAssertThrowsError(try split.validated(for: first))
        }
        XCTAssertFalse(TravelBackPage(url: "https://").isReopenable)
        XCTAssertFalse(TravelBackPage(url: "javascript:alert(1)").isReopenable)
    }

    func testExistingMatchingPairIsReusedWithoutMergingSidecars() {
        let split = TravelBackSplit(members: [first, second])
        XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: [first.url, second.url],
                                                 hasAnchor: true, anchorCanJoin: false), .reuse)
    }

    func testDifferentExistingPairIsPreservedByCreatingANewPair() {
        let split = TravelBackSplit(members: [first, second])
        for urls in [[first.url, "https://unrelated.test"], [second.url, first.url]] {
            XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: urls,
                                                     hasAnchor: true, anchorCanJoin: true), .newPair)
        }
    }

    func testCurrentExactURLWinsEvenWhenRecordedTabStillExists() {
        let current = TravelBackTabRef(tabId: 42, windowId: 1, url: first.url)
        let recorded = TravelBackTabRef(tabId: 7, windowId: 2, url: "https://moved.test")
        let scene = TravelBackScene(page: first, tab: .init(tabId: 7))
        XCTAssertEqual(TravelBackTabRef.anchor(for: scene, current: current, openTabs: [recorded, current]), current)
        XCTAssertEqual(TravelBackTabRef.anchor(for: scene, current: nil, openTabs: [recorded, current]), recorded)
    }

    func testOtherSameURLTabsNeverSubstituteForTheRecordedTab() {
        let matching = TravelBackTabRef(tabId: 42, windowId: 1, url: first.url)
        let scene = TravelBackScene(page: first, tab: .init(tabId: 7))
        XCTAssertNil(TravelBackTabRef.anchor(for: scene, current: nil, openTabs: [matching]))
        for suffix in ["?changed=1", "#changed"] {
            let current = TravelBackTabRef(tabId: 42, windowId: 1, url: first.url + suffix)
            XCTAssertNil(TravelBackTabRef.anchor(for: scene, current: current, openTabs: [current]))
        }
    }

    func testSafeStandaloneAnchorCanGainANewPartner() {
        let split = TravelBackSplit(members: [first, second])
        XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: nil,
                                                 hasAnchor: true, anchorCanJoin: true), .completeAnchor)
        XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: nil,
                                                 hasAnchor: true, anchorCanJoin: false), .newPair)
        XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: nil,
                                                 hasAnchor: false, anchorCanJoin: true), .newPair)
    }
}
