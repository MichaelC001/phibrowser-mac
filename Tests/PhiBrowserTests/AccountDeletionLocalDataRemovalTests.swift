// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class AccountDeletionLocalDataRemovalTests: XCTestCase {
    // MARK: - Deadline race

    func testAwaitWithDeadlineReportsCompletionWhenTheOperationFinishesInTime() async {
        let finished = await AccountDeletionLocalDataRemoval.awaitWithDeadline(seconds: 5) {}

        XCTAssertTrue(finished)
    }

    func testAwaitWithDeadlineGivesUpOnAStalledOperation() async {
        let finished = await AccountDeletionLocalDataRemoval.awaitWithDeadline(seconds: 0.05) {
            // A callback that never arrives and ignores cancellation — the
            // shape of a stalled WebKit storage sweep. A task-group
            // implementation would hang here (the group drains its
            // children on exit), which is exactly what this test pins.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }

        XCTAssertFalse(finished)
    }

    // MARK: - Sibling channel mapping

    func testSiblingProductBundleIDPairsCanaryWithRelease() {
        XCTAssertEqual(
            AccountDeletionLocalDataRemoval.siblingProductBundleID(for: "com.phibrowser.canary.Mac"),
            "com.phibrowser.Mac"
        )
        XCTAssertEqual(
            AccountDeletionLocalDataRemoval.siblingProductBundleID(for: "com.phibrowser.Mac"),
            "com.phibrowser.canary.Mac"
        )
    }

    func testSiblingProductBundleIDWithoutDotsHasNoSibling() {
        XCTAssertNil(AccountDeletionLocalDataRemoval.siblingProductBundleID(for: "phi"))
    }
}
