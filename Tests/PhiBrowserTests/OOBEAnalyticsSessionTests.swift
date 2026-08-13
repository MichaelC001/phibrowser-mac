// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class OOBEAnalyticsSessionTests: XCTestCase {
    private struct Event {
        let name: String
        let properties: [String: Any]
    }

    private final class EventRecorder {
        var events: [Event] = []
    }

    func testStepLifecycleCapturesViewAndCompletion() {
        let recorder = EventRecorder()
        let session = makeSession(recorder: recorder)

        session.present(.login, uptime: 10)
        session.completeCurrentStep(uptime: 13.5)

        XCTAssertEqual(recorder.events.map(\.name), [
            "oobe_step_viewed",
            "oobe_step_completed",
        ])
        XCTAssertEqual(recorder.events[0].properties["step"] as? String, "login")
        XCTAssertEqual(recorder.events[0].properties["step_index"] as? Int, 1)
        XCTAssertEqual(recorder.events[0].properties["is_guest"] as? Bool, false)
        XCTAssertEqual(
            recorder.events[1].properties["duration_seconds"] as? TimeInterval,
            3.5
        )
    }

    func testStepMappingUsesStableOOBENamesAndIndices() {
        let mappings: [(OOBEAnalyticsSession.Step, String, Int, Bool)] = [
            (.login, "login", 1, false),
            (.setName, "set_name", 2, false),
            (.setTheme, "set_theme", 3, false),
            (.layoutSelection, "layout_selection", 4, false),
            (.passwordManager, "password_manager", 5, false),
            (.nextStep, "next_step", 6, false),
            (.guestPrivacy, "guest_privacy", 2, true),
        ]

        for (step, name, index, isGuest) in mappings {
            XCTAssertEqual(step.rawValue, name)
            XCTAssertEqual(step.index, index)
            XCTAssertEqual(step.isGuest, isGuest)
        }
    }

    func testPresentingSameStepTwiceDoesNotDuplicateView() {
        let recorder = EventRecorder()
        let session = makeSession(recorder: recorder)

        session.present(.setTheme, uptime: 10)
        session.present(.setTheme, uptime: 20)

        XCTAssertEqual(recorder.events.map(\.name), ["oobe_step_viewed"])
    }

    func testGuestFinishCompletesCurrentStepAndCapturesSummary() {
        let recorder = EventRecorder()
        let session = makeSession(recorder: recorder)

        session.present(.login, uptime: 10)
        session.completeCurrentStep(uptime: 12)
        session.present(.guestPrivacy, uptime: 12)
        session.finish(isGuest: true, stepsCompleted: 2, uptime: 15)

        XCTAssertEqual(recorder.events.map(\.name), [
            "oobe_step_viewed",
            "oobe_step_completed",
            "oobe_step_viewed",
            "oobe_step_completed",
            "oobe_finished",
        ])
        let summary = recorder.events[4].properties
        XCTAssertEqual(summary["is_guest"] as? Bool, true)
        XCTAssertEqual(summary["steps_completed"] as? Int, 2)
        XCTAssertEqual(
            summary["total_duration_seconds"] as? TimeInterval,
            5
        )
    }

    func testAuthenticatedFinishUsesLastPresentedStepIndex() {
        let recorder = EventRecorder()
        let session = makeSession(recorder: recorder)

        session.present(.nextStep, uptime: 8)
        session.finish(isGuest: false, uptime: 10)

        let summary = recorder.events.last?.properties
        XCTAssertEqual(summary?["steps_completed"] as? Int, 6)
        XCTAssertEqual(summary?["is_guest"] as? Bool, false)
    }

    func testInterruptionCapturesLastStepAndAccumulatedDuration() {
        let recorder = EventRecorder()
        let session = makeSession(recorder: recorder)

        session.present(.login, uptime: 10)
        session.completeCurrentStep(uptime: 12)
        session.present(.setName, uptime: 12)
        session.interrupt(reason: .windowClosed, uptime: 15)

        let interruption = recorder.events.last
        XCTAssertEqual(interruption?.name, "oobe_interrupted")
        XCTAssertEqual(interruption?.properties["last_step"] as? String, "set_name")
        XCTAssertEqual(interruption?.properties["step_index"] as? Int, 2)
        XCTAssertEqual(interruption?.properties["reason"] as? String, "window_closed")
        XCTAssertEqual(
            interruption?.properties["total_duration_seconds"] as? TimeInterval,
            5
        )
    }

    func testSuppressionPreventsInterruptionCapture() {
        let recorder = EventRecorder()
        let session = makeSession(recorder: recorder)

        session.present(.login, uptime: 10)
        session.suppressInterruption()
        session.interrupt(reason: .windowClosed, uptime: 20)

        XCTAssertEqual(recorder.events.map(\.name), ["oobe_step_viewed"])
    }

    private func makeSession(
        recorder: EventRecorder
    ) -> OOBEAnalyticsSession {
        OOBEAnalyticsSession { name, properties in
            recorder.events.append(Event(name: name, properties: properties))
        }
    }
}
