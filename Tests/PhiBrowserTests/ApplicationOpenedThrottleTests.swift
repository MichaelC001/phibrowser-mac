// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ApplicationOpenedThrottleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmitsWhenNeverEmitted() {
        XCTAssertTrue(ApplicationOpenedThrottle.shouldEmit(lastEmission: nil, now: now))
    }

    func testSkipsWhenLastEmissionIsThirtyMinutesOld() {
        XCTAssertFalse(
            ApplicationOpenedThrottle.shouldEmit(lastEmission: now.addingTimeInterval(-1800), now: now)
        )
    }

    func testSkipsTheStartupActivationRightAfterTheLaunchEmission() {
        XCTAssertFalse(
            ApplicationOpenedThrottle.shouldEmit(lastEmission: now.addingTimeInterval(-0.05), now: now)
        )
    }

    func testEmitsWhenLastEmissionIsTwoHoursOld() {
        XCTAssertTrue(
            ApplicationOpenedThrottle.shouldEmit(lastEmission: now.addingTimeInterval(-7200), now: now)
        )
    }

    func testEmitsExactlyAtTheInterval() {
        XCTAssertTrue(
            ApplicationOpenedThrottle.shouldEmit(
                lastEmission: now.addingTimeInterval(-ApplicationOpenedThrottle.minimumInterval),
                now: now
            )
        )
    }

    func testIntervalIsOneHour() {
        XCTAssertEqual(ApplicationOpenedThrottle.minimumInterval, 3600)
    }

    /// The persisted timestamp drives the decision across instances, the way
    /// it must across relaunches; the clock is injected so nothing sleeps.
    func testRecordedEmissionPersistsAndThrottlesAcrossInstances() throws {
        let suite = "ApplicationOpenedThrottleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = now

        let first = ApplicationOpenedThrottle(now: { clock }, defaults: defaults)
        XCTAssertNil(first.lastEmission)
        XCTAssertTrue(first.shouldEmit())
        first.recordEmission()
        XCTAssertEqual(first.lastEmission, now)

        // A "relaunch" 30 minutes later reads the same store and stays quiet.
        clock = now.addingTimeInterval(1800)
        let second = ApplicationOpenedThrottle(now: { clock }, defaults: defaults)
        XCTAssertFalse(second.shouldEmit())

        // Two hours after the emission it is due again.
        clock = now.addingTimeInterval(7200)
        XCTAssertTrue(second.shouldEmit())
    }
}
