// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class GuestModeUITests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "GuestModeUITests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        super.tearDown()
    }

    func testFirstGuestEntryDefaultsNewTabsToOmnibox() {
        let didApply = GuestNewTabPreference.applyDefaultIfNeeded(
            isGuest: true,
            defaults: defaults,
            persistentDomainName: defaultsSuiteName
        )

        XCTAssertTrue(didApply)
        XCTAssertFalse(defaults.bool(forKey: GuestNewTabPreference.key))
        XCTAssertNotNil(
            defaults.persistentDomain(forName: defaultsSuiteName)?[GuestNewTabPreference.key]
        )
    }

    func testGuestEntryPreservesExistingNewTabPagePreference() {
        defaults.set(true, forKey: GuestNewTabPreference.key)

        let didApply = GuestNewTabPreference.applyDefaultIfNeeded(
            isGuest: true,
            defaults: defaults,
            persistentDomainName: defaultsSuiteName
        )

        XCTAssertFalse(didApply)
        XCTAssertTrue(defaults.bool(forKey: GuestNewTabPreference.key))
    }

    func testNonGuestEntryDoesNotPersistNewTabPreference() {
        let didApply = GuestNewTabPreference.applyDefaultIfNeeded(
            isGuest: false,
            defaults: defaults,
            persistentDomainName: defaultsSuiteName
        )

        XCTAssertFalse(didApply)
        XCTAssertNil(
            defaults.persistentDomain(forName: defaultsSuiteName)?[GuestNewTabPreference.key]
        )
    }

    func testLoginRequiredPolicyOnlyGatesGuestAISurfacesWhenAIIsEnabled() {
        for surface in [
            LoginRequiredSurface.newTabPage,
            .aiChat
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: true
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: false
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: false,
                    isPhiAIEnabled: true
                )
            )
        }
    }

    func testLoginRequiredPolicyGatesEveryGuestAccountSurface() {
        for surface in [
            LoginRequiredSurface.browserMemory,
            LoginRequiredSurface.connectors,
            .imChannels
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: false
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: false,
                    isPhiAIEnabled: true
                )
            )
        }
    }

    func testBrowserMemoryURLClassificationAcceptsInternalAliasesOnly() {
        for url in [
            "chrome://memory/memory.html",
            "phi://memory/memory.html",
            "phi://MEMORY/dashboard?view=recent"
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.isBrowserMemoryURL(url)
            )
        }

        for url in [
            "https://memory/memory.html",
            "phi://memory-settings/memory.html",
            "phi://conversation/memory.html",
            nil
        ] {
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.isBrowserMemoryURL(url)
            )
        }
    }

    @MainActor
    func testContinueAsGuestInvokesLifecycleCallback() {
        let controller = LoginViewController()
        var callbackCount = 0
        controller.onContinueAsGuest = {
            callbackCount += 1
        }

        controller.continueAsGuestAction()

        XCTAssertEqual(callbackCount, 1)
    }
}
