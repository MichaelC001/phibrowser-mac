// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SpaceManagerDefaultSpaceProfileBindingTests: XCTestCase {
    func testGuestUsesObservedChromiumProfile() {
        XCTAssertEqual(
            SpaceManager.profileIdForDefaultSpaceCreation(
                isGuest: true,
                isGuestAccountPromotionInProgress: false,
                isBoundToDefaultAccount: true,
                observedNormalWindowProfileId: "Profile 1"
            ),
            "Profile 1"
        )
    }

    func testGuestWaitsUntilAChromiumProfileIsObserved() {
        XCTAssertNil(
            SpaceManager.profileIdForDefaultSpaceCreation(
                isGuest: true,
                isGuestAccountPromotionInProgress: false,
                isBoundToDefaultAccount: true,
                observedNormalWindowProfileId: nil
            )
        )
    }

    func testGuestPromotionDoesNotCreateDefaultSpace() {
        XCTAssertNil(
            SpaceManager.profileIdForDefaultSpaceCreation(
                isGuest: true,
                isGuestAccountPromotionInProgress: true,
                isBoundToDefaultAccount: true,
                observedNormalWindowProfileId: "Profile 1"
            )
        )
    }

    func testGuestBindingDoesNotApplyToNonDefaultAccount() {
        XCTAssertNil(
            SpaceManager.profileIdForDefaultSpaceCreation(
                isGuest: true,
                isGuestAccountPromotionInProgress: false,
                isBoundToDefaultAccount: false,
                observedNormalWindowProfileId: "Profile 1"
            )
        )
    }

    func testSignedInAccessKeepsTheDefaultProfile() {
        XCTAssertEqual(
            SpaceManager.profileIdForDefaultSpaceCreation(
                isGuest: false,
                isGuestAccountPromotionInProgress: false,
                isBoundToDefaultAccount: false,
                observedNormalWindowProfileId: "Profile 1"
            ),
            LocalStore.defaultProfileId
        )
    }
}

@MainActor
final class LocalStoreDefaultSpaceProfileBindingTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testEnsureDefaultSpacePreservesItsExistingProfileOwner() async throws {
        let store = try makeStore()

        store.ensureDefaultSpace(profileId: "Profile 1")
        await flushWrites(in: store)
        store.ensureDefaultSpace(profileId: LocalStore.defaultProfileId)
        await flushWrites(in: store)

        let defaultSpaces = store.getAllSpaces().filter {
            $0.spaceId == LocalStore.defaultSpaceId
        }
        XCTAssertEqual(defaultSpaces.count, 1)
        XCTAssertEqual(defaultSpaces.first?.profileId, "Profile 1")
    }

    func testEnsureDefaultSpaceCreatesDefaultOwnerForEmptyStore() async throws {
        let store = try makeStore()

        XCTAssertTrue(store.getAllSpaces().isEmpty)

        store.ensureDefaultSpace(profileId: LocalStore.defaultProfileId)
        await flushWrites(in: store)

        let defaultSpaces = store.getAllSpaces().filter {
            $0.spaceId == LocalStore.defaultSpaceId
        }
        XCTAssertEqual(defaultSpaces.count, 1)
        XCTAssertEqual(
            defaultSpaces.first?.profileId,
            LocalStore.defaultProfileId
        )
    }

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory
        return LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
    }

    private func flushWrites(in store: LocalStore) async {
        await store.performBackgroundWriteAndWait { _ in }
    }
}
