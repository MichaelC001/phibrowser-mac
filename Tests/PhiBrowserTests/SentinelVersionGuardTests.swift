// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelVersionGuardTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var now: Date!
    private var postedSnapshots: [SentinelVersionGuardSnapshot]!
    private var reportedWarnings: [SentinelVersionGuardWarning]!
    private var launchCount: Int!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SentinelVersionGuardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        now = Date(timeIntervalSince1970: 1_778_620_000)
        postedSnapshots = []
        reportedWarnings = []
        launchCount = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        now = nil
        postedSnapshots = nil
        reportedWarnings = nil
        launchCount = nil
        super.tearDown()
    }

    func testStableMatchingVersionsSkipsRestart() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: "1.2.1"
        )

        let decision = guarder.evaluateCurrentState()
        guarder.apply(decision)

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(reportedWarnings.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testStableMismatchRequestsRestart() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: "1.2.0"
        )

        let decision = guarder.evaluateCurrentState()
        guarder.apply(decision)

        XCTAssertEqual(postedSnapshots.count, 1)
        XCTAssertEqual(postedSnapshots.first?.browserVersion, "1.2.1")
        XCTAssertEqual(postedSnapshots.first?.sentinelVersion, "1.2.0")
        XCTAssertEqual(reportedWarnings.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testSameStableMismatchWithinCooldownDoesNotRestartAgain() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: "1.2.0"
        )

        let firstDecision = guarder.evaluateCurrentState()
        guarder.apply(firstDecision)
        now = now.addingTimeInterval(60)
        let secondDecision = guarder.evaluateCurrentState()
        guarder.apply(secondDecision)

        XCTAssertEqual(postedSnapshots.count, 1)
    }

    func testSameStableMismatchAfterCooldownCanRestartAgain() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: "1.2.0"
        )

        guarder.apply(guarder.evaluateCurrentState())
        now = now.addingTimeInterval(11 * 60)
        guarder.apply(guarder.evaluateCurrentState())

        XCTAssertEqual(postedSnapshots.count, 2)
    }

    func testCanaryMismatchSkipsRestart() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.canary.Mac",
            browserVersion: "Canary",
            sentinelVersion: "2026.05.11.bc3653c2"
        )

        guarder.apply(guarder.evaluateCurrentState())

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testDevMismatchSkipsRestart() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.dev.Mac",
            browserVersion: "dev",
            sentinelVersion: "2026.05.13.120000"
        )

        guarder.apply(guarder.evaluateCurrentState())

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testStableSentinelNotRunningLaunchesWithoutRestartRequest() {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: nil
        )

        guarder.apply(guarder.evaluateCurrentState())

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(reportedWarnings.count, 0)
        XCTAssertEqual(launchCount, 1)
    }

    func testDisabledPhiAISkipsSentinelLaunchAndWarning() async {
        let guarder = makeGuard(
            browserBundleID: "com.phibrowser.Mac",
            browserVersion: "1.2.1",
            sentinelVersion: nil,
            shouldRunSentinel: { false }
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(postedSnapshots.count, 0)
        XCTAssertEqual(reportedWarnings.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    /// What the sentinelInfoProvider reports on one sampling call. Index 0 is consumed
    /// by evaluateCurrentState; the confirmation loop starts at index 1. The last
    /// sample repeats for any further calls.
    private enum SentinelSample {
        /// Process not running (runningInfo returns nil).
        case gone
        /// Process alive but runtime-info file not (re)written yet (version == nil).
        case noVersion
        case version(String)
    }

    func testConvergenceStopsOnceSentinelAdoptsExpectedVersion() async {
        // Sentinel reports the old version at evaluation, then the expected version on
        // the first confirmation read: only the initial request should be posted.
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.version("1.2.0"), .version("1.2.1")],
            maxRetries: 3
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(postedSnapshots.count, 1)
        XCTAssertEqual(reportedWarnings.count, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testConvergenceRepostsUntilRetriesExhausted() async {
        // Sentinel never adopts the expected version: the final check reports the
        // mismatch instead of posting another restart that cannot be confirmed.
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.version("1.2.0")],
            maxRetries: 2
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(postedSnapshots.count, 2)
        XCTAssertEqual(
            reportedWarnings,
            [
                .versionMismatch(
                    SentinelVersionGuardSnapshot(
                        browserBundleID: "com.phibrowser.Mac",
                        browserVersion: "1.2.1",
                        sentinelBundleID: "com.phibrowser.Sentinel",
                        sentinelVersion: "1.2.0"
                    )
                )
            ]
        )
        XCTAssertEqual(launchCount, 0)
    }

    func testConvergenceLaunchesSentinelWhenProcessGone() async {
        // Sentinel's process disappears during confirmation (relaunch failed or it
        // exited): the guard must launch it, or nothing brings Sentinel back until
        // the next browser cold launch.
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.version("1.2.0"), .gone],
            maxRetries: 3
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(postedSnapshots.count, 1)
        XCTAssertEqual(launchCount, 1)
    }

    func testConvergenceWaitsThroughMissingVersionThenConverges() async {
        // Mid-relaunch the process is up but the runtime-info file is not rewritten
        // yet (version == nil): the loop must keep waiting through the transient,
        // not bail out, and then observe convergence.
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.version("1.2.0"), .noVersion, .version("1.2.1")],
            maxRetries: 3
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(postedSnapshots.count, 1)
        XCTAssertEqual(launchCount, 0)
    }

    func testConvergenceSucceedsOnLastRetry() async {
        // Convergence lands exactly on the final allowed check — pins the loop bound.
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.version("1.2.0"), .version("1.2.0"), .version("1.2.0"), .version("1.2.1")],
            maxRetries: 3
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        // Initial post + re-posts on the two unconverged checks; converged on the third.
        XCTAssertEqual(postedSnapshots.count, 3)
        XCTAssertEqual(launchCount, 0)
    }

    func testStartupReportsWarningWhenSentinelFailsToLaunch() async {
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.gone],
            maxRetries: 2
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(
            reportedWarnings,
            [
                .notRunning(
                    browserBundleID: "com.phibrowser.Mac",
                    browserVersion: "1.2.1",
                    sentinelBundleID: "com.phibrowser.Sentinel"
                )
            ]
        )
    }

    func testStartupDoesNotReportMissingSentinelAfterPhiAIIsDisabled() async {
        var phiAIEnabled = true
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.gone],
            maxRetries: 2,
            shouldRunSentinel: {
                defer { phiAIEnabled = false }
                return phiAIEnabled
            }
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(reportedWarnings.count, 0)
    }

    func testStartupReportsVersionMismatchAfterSentinelLaunches() async {
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.gone, .noVersion, .version("1.2.0")],
            maxRetries: 2
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(
            reportedWarnings,
            [
                .versionMismatch(
                    SentinelVersionGuardSnapshot(
                        browserBundleID: "com.phibrowser.Mac",
                        browserVersion: "1.2.1",
                        sentinelBundleID: "com.phibrowser.Sentinel",
                        sentinelVersion: "1.2.0"
                    )
                )
            ]
        )
    }

    func testStartupDoesNotReportWarningAfterMatchingSentinelLaunches() async {
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.gone, .noVersion, .version("1.2.1")],
            maxRetries: 2
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(reportedWarnings.count, 0)
    }

    func testStartupDoesNotReportLaunchFailureWhileSentinelVersionIsUnavailable() async {
        let guarder = makeConvergenceGuard(
            browserVersion: "1.2.1",
            samples: [.gone, .noVersion],
            maxRetries: 2
        )

        await guarder.runStartupCheck(delaySeconds: 0)

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(reportedWarnings.count, 0)
    }

    private func makeConvergenceGuard(
        browserVersion: String,
        samples: [SentinelSample],
        maxRetries: Int,
        shouldRunSentinel: @escaping () -> Bool = { true }
    ) -> SentinelVersionGuard {
        var callIndex = 0
        return SentinelVersionGuard(
            userDefaults: defaults,
            now: { self.now },
            shouldRunSentinelProvider: shouldRunSentinel,
            browserBundleIDProvider: { "com.phibrowser.Mac" },
            browserVersionProvider: { browserVersion },
            sentinelInfoProvider: { sentinelBundleID in
                let sample = samples[min(callIndex, samples.count - 1)]
                callIndex += 1
                switch sample {
                case .gone:
                    return nil
                case .noVersion:
                    return SentinelVersionGuard.RunningSentinelInfo(
                        bundleID: sentinelBundleID,
                        version: nil
                    )
                case .version(let version):
                    return SentinelVersionGuard.RunningSentinelInfo(
                        bundleID: sentinelBundleID,
                        version: version
                    )
                }
            },
            restartRequestPoster: { snapshot, _ in
                self.postedSnapshots.append(snapshot)
            },
            sentinelLauncher: {
                self.launchCount += 1
            },
            warningReporter: {
                self.reportedWarnings.append($0)
            },
            logger: { _ in },
            sleep: { _ in },
            launchConfirmationInterval: 0,
            maxLaunchConfirmationChecks: maxRetries,
            confirmInterval: 0,
            maxConfirmationRetries: maxRetries
        )
    }

    private func makeGuard(
        browserBundleID: String,
        browserVersion: String,
        sentinelVersion: String?,
        shouldRunSentinel: @escaping () -> Bool = { true }
    ) -> SentinelVersionGuard {
        SentinelVersionGuard(
            userDefaults: defaults,
            now: { self.now },
            shouldRunSentinelProvider: shouldRunSentinel,
            browserBundleIDProvider: { browserBundleID },
            browserVersionProvider: { browserVersion },
            sentinelInfoProvider: { sentinelBundleID in
                guard let sentinelVersion else { return nil }
                return SentinelVersionGuard.RunningSentinelInfo(
                    bundleID: sentinelBundleID,
                    version: sentinelVersion
                )
            },
            restartRequestPoster: { snapshot, _ in
                self.postedSnapshots.append(snapshot)
            },
            sentinelLauncher: {
                self.launchCount += 1
            },
            warningReporter: {
                self.reportedWarnings.append($0)
            },
            logger: { _ in }
        )
    }
}
