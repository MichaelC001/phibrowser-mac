// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelAccountDeletedEventTests: XCTestCase {
    func testBuildsAccountDeletedEventWithAuth0Sub() {
        let event = SentinelAccountDeletedEvent.make(
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            auth0Sub: "auth0|user-1",
            requestID: "request-1"
        )

        XCTAssertEqual(
            SentinelAccountDeletedEvent.notificationName.rawValue,
            "com.phibrowser.sentinel.accountDeleted"
        )
        XCTAssertEqual(event.sentinelBundleID, "com.phibrowser.Sentinel")
        XCTAssertEqual(
            event.userInfo,
            [
                "requestID": "request-1",
                "browserBundleID": "com.phibrowser.Mac",
                "auth0Sub": "auth0|user-1"
            ]
        )
    }

    func testOmitsAuth0SubWhenTokenUnreadable() {
        let event = SentinelAccountDeletedEvent.make(
            sentinelBundleID: "com.phibrowser.canary.Sentinel",
            browserBundleID: "com.phibrowser.canary.Mac",
            auth0Sub: nil,
            requestID: "request-2"
        )

        XCTAssertEqual(
            event.userInfo,
            [
                "requestID": "request-2",
                "browserBundleID": "com.phibrowser.canary.Mac"
            ],
            "A missing sub must be omitted, not sent as an empty string"
        )
    }
}
