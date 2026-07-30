// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AccountDeletionErrorCopyTests: XCTestCase {
    /// One representative error per copy class.
    private static let allErrors: [AccountDeletionFlowError] = [
        .service(.invalidRequest),
        .service(.unauthorized),
        .service(.notFound),
        .service(.expired),
        .service(.rateLimited),
        .service(.serverError(statusCode: 500)),
        .service(.unexpectedResponse(statusCode: 200)),
        .network,
    ]

    func testEveryErrorHasCopyInBothContexts() {
        for error in Self.allErrors {
            XCTAssertFalse(
                AccountDeletionErrorCopy.inlineMessage(for: error).isEmpty,
                "Missing inline copy for \(error)"
            )
            XCTAssertFalse(
                AccountDeletionErrorCopy.failureMessage(for: error).isEmpty,
                "Missing failure copy for \(error)"
            )
        }
    }

    func testWrongCodeReadsAsCodeErrorOnlyInline() {
        // In the code-entry dialog a rejected request means a mistyped code;
        // on a failed first step no code was ever entered, so the same error
        // must fall back to the generic copy there.
        XCTAssertNotEqual(
            AccountDeletionErrorCopy.inlineMessage(for: .service(.invalidRequest)),
            AccountDeletionErrorCopy.failureMessage(for: .service(.invalidRequest))
        )
    }

    func testExpiredCopyPointsAtResendInline() {
        XCTAssertTrue(
            AccountDeletionErrorCopy.inlineMessage(for: .service(.expired))
                .contains("Resend Code"),
            "The expired-code copy must guide the user to the resend button"
        )
    }

    func testNotFoundIsIndistinguishableFromOtherGenericFailures() {
        // A not-found response must not be an oracle for whether an account
        // exists: its copy has to read exactly like the other generic
        // failures, in both contexts.
        let inline = AccountDeletionErrorCopy.inlineMessage(for: .service(.notFound))
        XCTAssertEqual(
            inline,
            AccountDeletionErrorCopy.inlineMessage(
                for: .service(.unexpectedResponse(statusCode: 200))
            )
        )
        XCTAssertEqual(
            inline,
            AccountDeletionErrorCopy.failureMessage(for: .service(.notFound))
        )
        XCTAssertEqual(
            AccountDeletionErrorCopy.failureMessage(for: .service(.notFound)),
            AccountDeletionErrorCopy.failureMessage(for: .service(.invalidRequest))
        )
    }

    func testSignedOutCopyGuidesToSignIn() {
        XCTAssertTrue(
            AccountDeletionErrorCopy.failureMessage(for: .service(.unauthorized))
                .localizedCaseInsensitiveContains("sign in"),
            "After a failed renewal the only way forward is signing in again"
        )
    }
}
