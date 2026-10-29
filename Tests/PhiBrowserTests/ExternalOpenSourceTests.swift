// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Pins which steps of the external-open path each source takes
/// (`ExternalOpenSource.steps`). Links from other applications and the Phi
/// Chat app's links share one path in `AppController`; what the rule cannot
/// reach, that `handleExternalOpen` and the held-URL flush consult it, rests
/// on the call sites.
final class ExternalOpenSourceTests: XCTestCase {
    func testASystemOpenTakesEveryStepButActivation() {
        // macOS has already activated Phi before it hands the link over,
        // unless that link was opened in the background.
        XCTAssertEqual(
            ExternalOpenSource.system.steps,
            ExternalOpenSource.Steps(resumesBrowserAuthentication: true,
                                     handlesDeeplinks: true,
                                     restoresWhenWindowless: true,
                                     activatesPhi: false))
    }

    func testAPhiChatLinkIsNeverASignInCallback() {
        // Page content chooses the link: it must not complete a sign-in.
        XCTAssertFalse(ExternalOpenSource.phiChat.steps.resumesBrowserAuthentication)
    }

    func testAPhiChatLinkIsNeverADeeplink() {
        // Page content chooses the link: it must not drive Phi's own actions.
        XCTAssertFalse(ExternalOpenSource.phiChat.steps.handlesDeeplinks)
    }

    func testAPhiChatLinkLandsAfterTheWindowlessRestore() {
        // The defect: with every window closed it opened in a bare window and
        // the closed windows never came back.
        XCTAssertTrue(ExternalOpenSource.phiChat.steps.restoresWhenWindowless)
    }

    func testAPhiChatLinkActivatesPhiFirst() {
        // The defect: Phi stayed inactive, so Chromium opened the link by the
        // profile of a window used before, not the one in front, and Phi
        // stayed behind Phi Chat.
        XCTAssertTrue(ExternalOpenSource.phiChat.steps.activatesPhi)
    }
}
