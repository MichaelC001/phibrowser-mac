// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#if DEBUG

import XCTest
@testable import Phi

@MainActor
final class AccountDeletionFakeResponsesTests: XCTestCase {

    // MARK: - First-step mapping

    func testRequestOutcomeSendsCodeForVerificationScenarios() throws {
        for scenario: AccountDeletionFakeScenario in [.success, .wrongCode, .codeExpired] {
            XCTAssertEqual(
                try AccountDeletionFakeResponses.requestOutcome(for: scenario),
                .verificationCodeSent(requestID: AccountDeletionFakeResponses.requestID),
                "\(scenario) must hand out a verification code"
            )
        }
    }

    func testRequestOutcomeReportsDeletionAlreadyRunning() throws {
        XCTAssertEqual(
            try AccountDeletionFakeResponses.requestOutcome(for: .deletionAlreadyRunning),
            .deletionAlreadyRunning
        )
    }

    func testRequestOutcomeRateLimitedThrows() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.requestOutcome(for: .rateLimited)
        ) { error in
            XCTAssertEqual(error as? AccountDeletionServiceError, .rateLimited)
        }
    }

    func testRequestOutcomeServerErrorThrows() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.requestOutcome(for: .serverError)
        ) { error in
            XCTAssertEqual(error as? AccountDeletionServiceError, .serverError(statusCode: 500))
        }
    }

    func testRequestOutcomeTokenExpiredThrows() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.requestOutcome(for: .tokenExpired)
        ) { error in
            XCTAssertEqual(error as? AccountDeletionServiceError, .unauthorized)
        }
    }

    func testRequestOutcomeNotFoundThrows() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.requestOutcome(for: .notFound)
        ) { error in
            XCTAssertEqual(error as? AccountDeletionServiceError, .notFound)
        }
    }

    func testRequestOutcomeNetworkFailureThrowsTransportError() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.requestOutcome(for: .networkFailure)
        ) { error in
            XCTAssertNil(
                error as? AccountDeletionServiceError,
                "A network failure is a transport error, not a service response"
            )
        }
    }

    // MARK: - Verification mapping

    func testVerifySuccessAcceptsAnyCode() {
        XCTAssertNoThrow(
            try AccountDeletionFakeResponses.verifyOutcome(for: .success, code: "000000")
        )
    }

    func testVerifyWrongCodeRejectsEverythingButTheAcceptedCode() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.verifyOutcome(for: .wrongCode, code: "111111")
        ) { error in
            XCTAssertEqual(error as? AccountDeletionServiceError, .invalidRequest)
        }
        XCTAssertNoThrow(
            try AccountDeletionFakeResponses.verifyOutcome(
                for: .wrongCode,
                code: AccountDeletionFakeResponses.acceptedCode
            )
        )
    }

    func testVerifyCodeExpiredThrows() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.verifyOutcome(
                for: .codeExpired,
                code: AccountDeletionFakeResponses.acceptedCode
            )
        ) { error in
            XCTAssertEqual(error as? AccountDeletionServiceError, .expired)
        }
    }

    func testVerifyTokenExpiredThrows() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.verifyOutcome(
                for: .tokenExpired,
                code: AccountDeletionFakeResponses.acceptedCode
            )
        ) { error in
            XCTAssertEqual(error as? AccountDeletionServiceError, .unauthorized)
        }
    }

    func testVerifyNetworkFailureThrowsTransportError() {
        XCTAssertThrowsError(
            try AccountDeletionFakeResponses.verifyOutcome(
                for: .networkFailure,
                code: AccountDeletionFakeResponses.acceptedCode
            )
        ) { error in
            XCTAssertNil(
                error as? AccountDeletionServiceError,
                "A network failure is a transport error, not a service response"
            )
        }
    }

    // MARK: - Credential renewal

    func testPlayRenewCredentialsPretendsSuccess() {
        XCTAssertTrue(
            AccountDeletionFakeResponses.playRenewCredentials(.tokenExpired),
            "Fake renewal reports success so the coordinator's one retry plays out"
        )
    }

    // MARK: - Seam wiring

    /// A default-constructed coordinator must route through the active fake
    /// scenario: landing on the fake request ID proves the injection seam's
    /// default closures consulted the fakes instead of the real client.
    func testDefaultCoordinatorPlaysActiveScenarioWithoutNetwork() async {
        let previousScenario = AccountDeletionFakeResponses.scenario
        let previousDelay = AccountDeletionFakeResponses.responseDelay
        AccountDeletionFakeResponses.scenario = .wrongCode
        AccountDeletionFakeResponses.responseDelay = .zero
        defer {
            AccountDeletionFakeResponses.scenario = previousScenario
            AccountDeletionFakeResponses.responseDelay = previousDelay
        }

        let coordinator = AccountDeletionCoordinator()

        await coordinator.start()
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(
                requestID: AccountDeletionFakeResponses.requestID,
                error: nil
            )
        )

        await coordinator.submitCode("999999")
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(
                requestID: AccountDeletionFakeResponses.requestID,
                error: .service(.invalidRequest)
            )
        )

        await coordinator.submitCode(AccountDeletionFakeResponses.acceptedCode)
        XCTAssertEqual(coordinator.state, .requestSubmitted)
    }

    /// The token-expired scenario must play through the coordinator's real
    /// default closures — including the faked credential renewal — and land
    /// on the sign-in guidance after the one retry, without ever touching
    /// the real Auth0 session.
    func testDefaultCoordinatorPlaysTokenExpiredThroughRenewalSeam() async {
        let previousScenario = AccountDeletionFakeResponses.scenario
        let previousDelay = AccountDeletionFakeResponses.responseDelay
        AccountDeletionFakeResponses.scenario = .tokenExpired
        AccountDeletionFakeResponses.responseDelay = .zero
        defer {
            AccountDeletionFakeResponses.scenario = previousScenario
            AccountDeletionFakeResponses.responseDelay = previousDelay
        }

        let coordinator = AccountDeletionCoordinator()

        await coordinator.start()

        XCTAssertEqual(coordinator.state, .failed(.service(.unauthorized)))
    }
}

#endif
