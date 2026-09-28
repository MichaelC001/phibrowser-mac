// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class SpaceSwipeTrackerTests: XCTestCase {
    private func sample(_ tracker: SpaceSwipeTracker, _ x: CGFloat, _ y: CGFloat = 0,
                        phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = [],
                        time: TimeInterval = 1) -> SpaceSwipeTracker.Outcome {
        tracker.handle(deltaX: x, deltaY: y, phase: phase, momentum: momentum, timestamp: time)
    }

    func testReportsDistanceBeforeTheOldTriggerThreshold() {
        let tracker = SpaceSwipeTracker()
        guard case let .update(distance, _, began) = sample(tracker, -8, phase: .began) else {
            return XCTFail("Expected immediate drag progress")
        }
        XCTAssertEqual(distance, -8)
        XCTAssertTrue(began)
        guard case let .update(next, _, beganAgain) = sample(tracker, -12, time: 1.02) else {
            return XCTFail("Expected continuous progress")
        }
        XCTAssertEqual(next, -20)
        XCTAssertFalse(beganAgain)
    }

    func testReversingFingersReducesAndReversesDistance() {
        let tracker = SpaceSwipeTracker()
        _ = sample(tracker, -80, phase: .began)
        guard case let .update(distance, velocity, _) = sample(tracker, 50, time: 1.1) else {
            return XCTFail("Expected reversible progress")
        }
        XCTAssertEqual(distance, -30)
        XCTAssertGreaterThan(velocity, 0)
        guard case let .update(reversed, _, _) = sample(tracker, 50, time: 1.2) else {
            return XCTFail("Expected reversal through the origin")
        }
        XCTAssertEqual(reversed, 20)
    }

    func testVerticalGestureKeepsScrollingDespiteLaterHorizontalDrift() {
        let tracker = SpaceSwipeTracker()
        guard case .passthrough = sample(tracker, 0.1, 0.5, phase: .began) else { return XCTFail() }
        guard case .passthrough = sample(tracker, 100, 0, time: 1.1) else { return XCTFail() }
        XCTAssertFalse(tracker.consumesHorizontalGesture)
    }

    func testMouseWheelDoesNotSwitchSpaces() {
        guard case .passthrough = sample(SpaceSwipeTracker(), -100, phase: []) else { return XCTFail() }
    }

    func testEndAndMomentumCannotCommitTwice() {
        let tracker = SpaceSwipeTracker()
        _ = sample(tracker, -80, phase: .began)
        guard case let .end(distance, _, cancelled) = sample(tracker, 0, phase: .ended, time: 1.02) else {
            return XCTFail("Expected a single release")
        }
        XCTAssertEqual(distance, -80)
        XCTAssertFalse(cancelled)
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            guard case .consumed = sample(tracker, -100, phase: [], momentum: phase, time: 1.1) else {
                return XCTFail("Momentum must not start another switch")
            }
        }
    }

    func testCombinedFingerEndAndMomentumBeginStillEndsTheSwipe() {
        let tracker = SpaceSwipeTracker()
        _ = sample(tracker, -80, phase: .began)
        guard case .end = sample(tracker, 0, phase: .ended, momentum: .began, time: 1.02) else {
            return XCTFail("A combined boundary must not strand a preview")
        }
    }

    func testCancelledGestureCannotBecomeARelease() {
        let tracker = SpaceSwipeTracker()
        _ = sample(tracker, -80, phase: .began)
        guard case let .end(_, _, cancelled) = sample(tracker, 0, phase: .cancelled) else { return XCTFail() }
        XCTAssertTrue(cancelled)
        guard case .consumed = sample(tracker, 0, phase: .ended) else { return XCTFail() }
    }

    func testPauseBeforeReleaseDiscardsStaleFlickVelocity() {
        let tracker = SpaceSwipeTracker()
        _ = sample(tracker, -10, phase: .began)
        _ = sample(tracker, -20, time: 1.01)
        guard case let .end(_, velocity, _) = sample(tracker, 0, phase: .ended, time: 1.3) else { return XCTFail() }
        XCTAssertEqual(velocity, 0)
    }

    func testNewGestureResetsDistanceAndDirection() {
        let tracker = SpaceSwipeTracker()
        _ = sample(tracker, -80, phase: .began)
        _ = sample(tracker, 0, phase: .ended)
        guard case let .update(distance, _, began) = sample(tracker, 5, phase: .began, time: 2) else { return XCTFail() }
        XCTAssertEqual(distance, 5)
        XCTAssertTrue(began)
        tracker.reset()
        XCTAssertFalse(tracker.consumesHorizontalGesture)
    }

    func testReleaseDecisionUsesDistanceVelocityAndReversal() {
        XCTAssertFalse(SpaceSwipeTracker.shouldComplete(distance: -80, velocity: 0, width: 300))
        XCTAssertTrue(SpaceSwipeTracker.shouldComplete(distance: -110, velocity: 0, width: 300))
        XCTAssertTrue(SpaceSwipeTracker.shouldComplete(distance: -20, velocity: -800, width: 300))
        XCTAssertFalse(SpaceSwipeTracker.shouldComplete(distance: -5, velocity: -800, width: 300))
        XCTAssertFalse(SpaceSwipeTracker.shouldComplete(distance: -160, velocity: 400, width: 300))
        XCTAssertFalse(SpaceSwipeTracker.shouldComplete(distance: 100, velocity: 800, width: 0))
    }

    func testSettleDurationDependsOnRemainingDistance() {
        let near = SpaceSwipeTracker.settlingDuration(progress: 0.9, completes: true, velocity: 0, width: 300)
        let far = SpaceSwipeTracker.settlingDuration(progress: 0.2, completes: true, velocity: 0, width: 300)
        XCTAssertLessThan(near, far)
        XCTAssertGreaterThanOrEqual(near, 0.08)
        XCTAssertLessThanOrEqual(far, 0.24)
    }
}
