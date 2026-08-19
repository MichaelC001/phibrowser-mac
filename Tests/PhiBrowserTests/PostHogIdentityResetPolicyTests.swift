// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class PostHogIdentityResetPolicyTests: XCTestCase {
    func testDoesNotResetWhenDistinctIdIsTheAnonymousId() {
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldReset(
                distinctId: "anonymous-id",
                anonymousId: "anonymous-id"
            )
        )
    }

    func testResetsWhenAnAuthenticatedDistinctIdRemains() {
        XCTAssertTrue(
            PostHogIdentityResetPolicy.shouldReset(
                distinctId: "auth0-subject",
                anonymousId: "anonymous-id"
            )
        )
    }

    func testDoesNotResetAnonymousIdentityBeforeFirstIdentify() {
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldResetBeforeIdentifying(
                currentDistinctId: "anonymous-id",
                anonymousId: "anonymous-id",
                nextDistinctId: "auth0|user-a"
            )
        )
    }

    func testResetsAuthenticatedIdentityBeforeSwitchingAccounts() {
        XCTAssertTrue(
            PostHogIdentityResetPolicy.shouldResetBeforeIdentifying(
                currentDistinctId: "auth0|user-a",
                anonymousId: "anonymous-id",
                nextDistinctId: "auth0|user-b"
            )
        )
    }

    func testDoesNotResetAuthenticatedIdentityBeforeReidentifyingSameAccount() {
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldResetBeforeIdentifying(
                currentDistinctId: "auth0|user-a",
                anonymousId: "anonymous-id",
                nextDistinctId: "auth0|user-a"
            )
        )
    }

    func testSyncsMetricsIdentityOnlyAfterAuthenticatedActivation() {
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldSyncAfterMetricsReportingChange(
                enabled: true,
                isAuthenticated: false
            )
        )
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldSyncAfterMetricsReportingChange(
                enabled: false,
                isAuthenticated: true
            )
        )
        XCTAssertTrue(
            PostHogIdentityResetPolicy.shouldSyncAfterMetricsReportingChange(
                enabled: true,
                isAuthenticated: true
            )
        )
    }

    func testReconcilesAnonymousLaunchesWithResidualAuthenticatedIdentity() {
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldReconcileAnonymousLaunchIdentity(
                isGuest: true,
                isMetricsReportingEnabled: true,
                distinctId: "anonymous-id",
                anonymousId: "anonymous-id"
            )
        )
        XCTAssertTrue(
            PostHogIdentityResetPolicy.shouldReconcileAnonymousLaunchIdentity(
                isGuest: true,
                isMetricsReportingEnabled: true,
                distinctId: "auth0|user-a",
                anonymousId: "anonymous-id"
            )
        )
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldReconcileAnonymousLaunchIdentity(
                isGuest: false,
                isMetricsReportingEnabled: true,
                distinctId: "auth0|user-a",
                anonymousId: "anonymous-id"
            )
        )
        XCTAssertTrue(
            PostHogIdentityResetPolicy.shouldReconcileAnonymousLaunchIdentity(
                isGuest: false,
                isMetricsReportingEnabled: false,
                distinctId: "auth0|user-a",
                anonymousId: "anonymous-id"
            )
        )
    }

    func testDiscardsOnlyResidualAuthenticatedAnonymousLaunchLifecycleEvents() {
        XCTAssertTrue(
            PostHogIdentityResetPolicy.shouldDiscardAnonymousLaunchLifecycleEvent(
                eventName: "Application Updated",
                isGuest: true,
                isMetricsReportingEnabled: true,
                distinctId: "auth0|user-a",
                anonymousId: "anonymous-id"
            )
        )
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldDiscardAnonymousLaunchLifecycleEvent(
                eventName: "Application Opened",
                isGuest: true,
                isMetricsReportingEnabled: true,
                distinctId: "auth0|user-a",
                anonymousId: "anonymous-id"
            )
        )
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldDiscardAnonymousLaunchLifecycleEvent(
                eventName: "Application Updated",
                isGuest: true,
                isMetricsReportingEnabled: true,
                distinctId: "anonymous-id",
                anonymousId: "anonymous-id"
            )
        )
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldDiscardAnonymousLaunchLifecycleEvent(
                eventName: "Application Updated",
                isGuest: false,
                isMetricsReportingEnabled: true,
                distinctId: "auth0|user-a",
                anonymousId: "anonymous-id"
            )
        )
        XCTAssertTrue(
            PostHogIdentityResetPolicy.shouldDiscardAnonymousLaunchLifecycleEvent(
                eventName: "Application Installed",
                isGuest: false,
                isMetricsReportingEnabled: false,
                distinctId: "auth0|user-a",
                anonymousId: "anonymous-id"
            )
        )
    }

    func testDoesNotResetBeforePostHogHasBeenConfigured() {
        XCTAssertFalse(
            PostHogIdentityResetPolicy.shouldReset(
                distinctId: "",
                anonymousId: ""
            )
        )
    }
}
