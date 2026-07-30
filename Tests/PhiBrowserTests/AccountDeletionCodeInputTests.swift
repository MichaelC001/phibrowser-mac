// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AccountDeletionCodeInputTests: XCTestCase {
    func testDigitsPassThroughUnchanged() {
        XCTAssertEqual(AccountDeletionCodeInput.sanitized("123456"), "123456")
    }

    func testPartialEntryIsKept() {
        XCTAssertEqual(AccountDeletionCodeInput.sanitized("12"), "12")
    }

    func testNonDigitCharactersAreDropped() {
        XCTAssertEqual(AccountDeletionCodeInput.sanitized("12a!b3"), "123")
    }

    func testPastedCodeWithSpaceSeparatorsIsAccepted() {
        XCTAssertEqual(AccountDeletionCodeInput.sanitized(" 123 456 "), "123456")
    }

    func testPastedCodeWithDashSeparatorsIsAccepted() {
        XCTAssertEqual(AccountDeletionCodeInput.sanitized("123-456"), "123456")
    }

    func testInputIsCappedAtSixDigits() {
        XCTAssertEqual(AccountDeletionCodeInput.sanitized("1234567890"), "123456")
    }

    func testNonASCIIDigitsAreRejected() {
        XCTAssertEqual(AccountDeletionCodeInput.sanitized("１２３４５６"), "")
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(AccountDeletionCodeInput.sanitized(""), "")
    }
}
