// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class FirstTimeActionTrackerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FirstTimeActionTrackerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEachActionCapturesOnlyOnce() {
        var capturedActions: [String] = []
        let capture: FirstTimeActionTracker.Capture = { _, properties in
            capturedActions.append(properties["action"] as? String ?? "")
        }

        FirstTimeActionTracker.capture(
            .spaceCreated,
            defaults: defaults,
            now: Date(timeIntervalSince1970: 110),
            installDate: { Date(timeIntervalSince1970: 100) },
            postHogCapture: capture
        )
        FirstTimeActionTracker.capture(
            .spaceCreated,
            defaults: defaults,
            now: Date(timeIntervalSince1970: 120),
            installDate: { Date(timeIntervalSince1970: 100) },
            postHogCapture: capture
        )
        FirstTimeActionTracker.capture(
            .memoryOpened,
            defaults: defaults,
            now: Date(timeIntervalSince1970: 130),
            installDate: { Date(timeIntervalSince1970: 100) },
            postHogCapture: capture
        )

        XCTAssertEqual(capturedActions, ["space_created", "memory_opened"])
        XCTAssertEqual(
            defaults.stringArray(
                forKey: FirstTimeActionTracker.recordedActionsDefaultsKey
            ),
            ["memory_opened", "space_created"]
        )
    }

    func testUnavailableInstallDateDoesNotCaptureOrRecord() {
        var captureCount = 0

        FirstTimeActionTracker.capture(
            .agentTask,
            defaults: defaults,
            installDate: { nil },
            postHogCapture: { _, _ in captureCount += 1 }
        )

        XCTAssertEqual(captureCount, 0)
        XCTAssertNil(
            defaults.stringArray(
                forKey: FirstTimeActionTracker.recordedActionsDefaultsKey
            )
        )
    }

    func testNegativeElapsedTimeClampsToZero() {
        var capturedProperties: [String: Any] = [:]

        FirstTimeActionTracker.capture(
            .connectorConnected,
            defaults: defaults,
            now: Date(timeIntervalSince1970: 90),
            installDate: { Date(timeIntervalSince1970: 100) },
            postHogCapture: { _, properties in
                capturedProperties = properties
            }
        )

        XCTAssertEqual(
            capturedProperties["seconds_since_install"] as? Int,
            0
        )
    }
}
