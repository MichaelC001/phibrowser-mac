// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

@MainActor
final class OOBEAnalyticsSession {
    enum Step: String, Hashable {
        case login
        case setName = "set_name"
        case setTheme = "set_theme"
        case layoutSelection = "layout_selection"
        case passwordManager = "password_manager"
        case nextStep = "next_step"
        case guestPrivacy = "guest_privacy"

        var index: Int {
            switch self {
            case .login:
                return 1
            case .setName, .guestPrivacy:
                return 2
            case .setTheme:
                return 3
            case .layoutSelection:
                return 4
            case .passwordManager:
                return 5
            case .nextStep:
                return 6
            }
        }

        var isGuest: Bool {
            self == .guestPrivacy
        }
    }

    enum InterruptionReason: String {
        case windowClosed = "window_closed"
        case appTerminated = "app_terminated"
    }

    typealias Capture = (_ event: String, _ properties: [String: Any]) -> Void

    private let capture: Capture
    private var currentStep: Step?
    private var currentStepStartedAtUptime: TimeInterval?
    private var lastPresentedStep: Step?
    private var totalDuration: TimeInterval = 0
    private var hasEnded = false

    init(capture: @escaping Capture = { event, properties in
        PostHogSDK.shared.capture(event, properties: properties)
    }) {
        self.capture = capture
    }

    func present(
        _ step: Step,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard !hasEnded, currentStep != step else { return }

        pauseCurrentStep(uptime: uptime)
        currentStep = step
        currentStepStartedAtUptime = uptime
        lastPresentedStep = step
        capture("oobe_step_viewed", stepProperties(for: step))
    }

    func completeCurrentStep(
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard !hasEnded,
              let currentStep,
              let startedAt = currentStepStartedAtUptime else {
            return
        }

        let duration = max(0, uptime - startedAt)
        totalDuration += duration
        var properties = stepProperties(for: currentStep)
        properties["duration_seconds"] = duration
        capture("oobe_step_completed", properties)
        self.currentStep = nil
        currentStepStartedAtUptime = nil
    }

    func finish(
        isGuest: Bool,
        stepsCompleted: Int? = nil,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard !hasEnded else { return }

        completeCurrentStep(uptime: uptime)
        capture("oobe_finished", [
            "is_guest": isGuest,
            "steps_completed": stepsCompleted ?? lastPresentedStep?.index ?? 0,
            "total_duration_seconds": totalDuration,
        ])
        end()
    }

    func interrupt(
        reason: InterruptionReason,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard !hasEnded, let lastPresentedStep else { return }

        pauseCurrentStep(uptime: uptime)
        capture("oobe_interrupted", [
            "last_step": lastPresentedStep.rawValue,
            "step_index": lastPresentedStep.index,
            "is_guest": lastPresentedStep.isGuest,
            "total_duration_seconds": totalDuration,
            "reason": reason.rawValue,
        ])
        end()
    }

    func suppressInterruption() {
        guard !hasEnded else { return }
        end()
    }

    private func pauseCurrentStep(uptime: TimeInterval) {
        if let startedAt = currentStepStartedAtUptime {
            totalDuration += max(0, uptime - startedAt)
        }
        currentStep = nil
        currentStepStartedAtUptime = nil
    }

    private func stepProperties(for step: Step) -> [String: Any] {
        [
            "step": step.rawValue,
            "step_index": step.index,
            "is_guest": step.isGuest,
        ]
    }

    private func end() {
        hasEnded = true
        currentStep = nil
        currentStepStartedAtUptime = nil
    }
}
