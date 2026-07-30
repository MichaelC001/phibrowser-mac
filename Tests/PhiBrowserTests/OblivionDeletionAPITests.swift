// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class OblivionDeletionAPITests: XCTestCase {
    // MARK: - First step: the two success shapes
    //
    // Discrimination rides the body's `status` field alone: the API document
    // only pins 202 for fresh requests, so any 2xx must route by status.

    func testAcceptedPendingVerificationMapsToVerificationCodeSent() throws {
        let body = Data(
            #"{"status":"pending_verification","request_id":"req-123","expires_at":"2026-07-22T00:10:00Z"}"#.utf8
        )

        for statusCode in [200, 201, 202] {
            XCTAssertEqual(
                try OblivionDeletionAPI.requestOutcome(statusCode: statusCode, body: body),
                .verificationCodeSent(requestID: "req-123"),
                "Wrong outcome for status \(statusCode)"
            )
        }
    }

    func testAcceptedRunningMapsToDeletionAlreadyRunning() throws {
        let body = Data(
            #"{"status":"running","request_id":"req-123","task_id":"task-9"}"#.utf8
        )

        for statusCode in [200, 202] {
            XCTAssertEqual(
                try OblivionDeletionAPI.requestOutcome(statusCode: statusCode, body: body),
                .deletionAlreadyRunning,
                "Wrong outcome for status \(statusCode)"
            )
        }
    }

    func testAcceptedWithUnknownStatusIsUnexpected() {
        let body = Data(#"{"status":"finished","request_id":"req-123"}"#.utf8)

        XCTAssertThrowsError(try OblivionDeletionAPI.requestOutcome(statusCode: 202, body: body)) { error in
            XCTAssertEqual(
                error as? AccountDeletionServiceError,
                .unexpectedResponse(statusCode: 202)
            )
        }
    }

    func testAcceptedPendingVerificationWithoutRequestIDIsUnexpected() {
        let body = Data(#"{"status":"pending_verification"}"#.utf8)

        XCTAssertThrowsError(try OblivionDeletionAPI.requestOutcome(statusCode: 202, body: body)) { error in
            XCTAssertEqual(
                error as? AccountDeletionServiceError,
                .unexpectedResponse(statusCode: 202)
            )
        }
    }

    func testAcceptedWithUnparseableBodyIsUnexpected() {
        let body = Data("not json".utf8)

        XCTAssertThrowsError(try OblivionDeletionAPI.requestOutcome(statusCode: 202, body: body)) { error in
            XCTAssertEqual(
                error as? AccountDeletionServiceError,
                .unexpectedResponse(statusCode: 202)
            )
        }
    }

    // MARK: - First step: error statuses

    func testRequestErrorStatusesMapToDomainErrors() {
        let expectations: [(statusCode: Int, expected: AccountDeletionServiceError)] = [
            (400, .invalidRequest),
            (401, .unauthorized),
            (404, .notFound),
            (410, .expired),
            (429, .rateLimited),
            (500, .serverError(statusCode: 500)),
            (503, .serverError(statusCode: 503)),
            (301, .unexpectedResponse(statusCode: 301)),
        ]

        for (statusCode, expected) in expectations {
            XCTAssertThrowsError(
                try OblivionDeletionAPI.requestOutcome(statusCode: statusCode, body: Data()),
                "Expected \(statusCode) to throw"
            ) { error in
                XCTAssertEqual(
                    error as? AccountDeletionServiceError,
                    expected,
                    "Wrong domain error for status \(statusCode)"
                )
            }
        }
    }

    // MARK: - Second step
    //
    // Like the first step, verify has only documentation backing its 202 —
    // it was never exercised against staging (doing so deletes an account
    // for real) — so any 2xx counts as accepted.

    func testVerifyAnyAcceptedStatusSucceeds() {
        for statusCode in [200, 202, 204] {
            XCTAssertNoThrow(
                try OblivionDeletionAPI.verifyOutcome(statusCode: statusCode),
                "Expected \(statusCode) to count as accepted"
            )
        }
    }

    func testVerifyErrorStatusesMapToDomainErrors() {
        let expectations: [(statusCode: Int, expected: AccountDeletionServiceError)] = [
            (400, .invalidRequest),
            (401, .unauthorized),
            (404, .notFound),
            (410, .expired),
            (429, .rateLimited),
            (502, .serverError(statusCode: 502)),
            (301, .unexpectedResponse(statusCode: 301)),
        ]

        for (statusCode, expected) in expectations {
            XCTAssertThrowsError(
                try OblivionDeletionAPI.verifyOutcome(statusCode: statusCode),
                "Expected \(statusCode) to throw"
            ) { error in
                XCTAssertEqual(
                    error as? AccountDeletionServiceError,
                    expected,
                    "Wrong domain error for status \(statusCode)"
                )
            }
        }
    }
}
