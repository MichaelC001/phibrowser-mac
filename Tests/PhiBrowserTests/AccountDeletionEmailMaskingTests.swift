// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AccountDeletionEmailMaskingTests: XCTestCase {
    func testMasksLocalPartAndKeepsDomain() {
        XCTAssertEqual(
            AccountDeletionEmailMasking.masked("someone@example.com"),
            "s•••@example.com"
        )
    }

    func testKeepsOnlyTheFirstLocalCharacter() {
        XCTAssertEqual(AccountDeletionEmailMasking.masked("ab@c.d"), "a•••@c.d")
    }

    func testSingleCharacterLocalPartStaysRecognizable() {
        XCTAssertEqual(AccountDeletionEmailMasking.masked("a@b.c"), "a•••@b.c")
    }

    func testEmptyLocalPartMasksWithoutLeadingCharacter() {
        XCTAssertEqual(AccountDeletionEmailMasking.masked("@b.c"), "•••@b.c")
    }

    func testValueWithoutAtSignMasksEntirely() {
        XCTAssertEqual(AccountDeletionEmailMasking.masked("not-an-email"), "•••")
    }

    func testEmptyValueMasksEntirely() {
        XCTAssertEqual(AccountDeletionEmailMasking.masked(""), "•••")
    }
}
