// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import SwiftData
@testable import Phi

@MainActor
final class LaunchDataDirectoryTests: XCTestCase {
    private var accountsToClose: [Account] = []

    override func tearDown() async throws {
        for account in accountsToClose {
            try await account.localStorage.closeForAccountDirectoryRemoval()
        }
        for directory in Set(accountsToClose.map(\.userDataStorage)) {
            try? FileManager.default.removeItem(at: directory)
        }
        accountsToClose.removeAll()
    }

    private func resolve(_ arguments: [String] = [], environment: [String: String] = [:],
                         launch: String = "launch-one") -> String? {
        FileSystemUtils.resolveLaunchUserDataDirectory(
            arguments: ["Phi"] + arguments, environment: environment,
            temporaryDirectory: "/tmp", launchIdentifier: launch)
    }

    func testOrdinaryLaunchKeepsExistingStorageLocation() {
        XCTAssertNil(resolve())
        XCTAssertNil(resolve(environment: ["XCTestConfigurationFilePath": ""]))
    }

    func testExplicitProfileUsesSameDirectoryAcrossRestarts() {
        let arguments = ["--user-data-dir=/tmp/Phi isolated profile"]
        XCTAssertEqual(resolve(arguments, launch: "one"), "/tmp/Phi isolated profile")
        XCTAssertEqual(resolve(arguments, launch: "two"), resolve(arguments, launch: "one"))
    }

    func testSeparatedSwitchAndLastOverrideWin() {
        XCTAssertEqual(resolve(["--user-data-dir", "/tmp/first", "--user-data-dir=/tmp/second"]),
                       "/tmp/second")
        XCTAssertEqual(resolve(["--user-data-dir=/tmp/first", "--user-data-dir", "/tmp/second"]),
                       "/tmp/second")
    }

    func testArgumentsAfterTerminatorDoNotRedirectStorage() {
        XCTAssertNil(resolve(["--", "--user-data-dir=/tmp/ignored"]))
    }

    func testTestHostsAutomaticallyGetUniqueDirectories() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath"] {
            XCTAssertEqual(resolve(environment: [key: "/tmp/tests"]), "/tmp/PhiTests-launch-one")
            XCTAssertNotEqual(resolve(environment: [key: "/tmp/tests"], launch: "one"),
                              resolve(environment: [key: "/tmp/tests"], launch: "two"))
        }
        XCTAssertEqual(resolve(["-uitest", "1"]), "/tmp/PhiTests-launch-one")
    }

    func testExplicitProfileTakesPrecedenceInTestHosts() {
        XCTAssertEqual(resolve(["--user-data-dir=/tmp/chosen", "-uitest", "1"],
                               environment: ["XCTestBundlePath": "/tmp/tests"]), "/tmp/chosen")
    }

    func testEmptyTestOverrideCannotFallBackToRealData() {
        XCTAssertEqual(resolve(["--user-data-dir="], environment: ["XCTestBundlePath": "/tmp/tests"]),
                       "/tmp/PhiTests-launch-one")
        XCTAssertEqual(resolve(["--user-data-dir", "-uitest", "1"]), "/tmp/PhiTests-launch-one")
    }

    func testHostRoutesAccountSnapshotWritesAndColdStartReadsToIsolatedRoot() throws {
        // This assertion runs in the actual app host, after its startup. A
        // pure resolver test alone would miss a launch that never uses it.
        let root = try XCTUnwrap(FileSystemUtils.launchUserDataDirectory)
        let canonicalRoot = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask)[0]
            .appendingPathComponent(FileSystemUtils.bundleId).standardizedFileURL.path
        XCTAssertNotEqual(URL(fileURLWithPath: root).standardizedFileURL.path, canonicalRoot)
        guard root != canonicalRoot else { return }
        XCTAssertEqual(FileSystemUtils.applicationSupportDirctory(), root)

        let account = Account(userID: "launch-isolation-\(UUID().uuidString)")
        let expectedDirectory = URL(fileURLWithPath: root)
            .appendingPathComponent("Phi/users/\(account.userID)")
        XCTAssertEqual(account.userDataStorage.standardizedFileURL, expectedDirectory.standardizedFileURL)
        defer { try? FileManager.default.removeItem(at: account.userDataStorage) }

        let snapshot: [[String: Any]] = [[
            "activeSpaceId": "first", "isLandingEntry": true,
            "windowMap": ["101": "first", "102": "second"]
        ]]
        XCTAssertTrue(account.userDefaults.set(snapshot, forKey: .slotsRestoreSnapshot))
        let restored = try XCTUnwrap(AccountUserDefaults.storedObject(
            forKey: .slotsRestoreSnapshot, ofAccountWithUserID: account.userID) as? [[String: Any]])
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?["windowMap"] as? [String: String],
                       ["101": "first", "102": "second"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: AccountUserDefaults.storeURL(for: account).path))
    }

    func testReopenedAccountRestoresTwoSpacesIntoOneWindowSlot() async throws {
        _ = try XCTUnwrap(FileSystemUtils.launchUserDataDirectory)
        let account = Account(userID: "launch-restore-\(UUID().uuidString)")
        accountsToClose.append(account)
        let context = try XCTUnwrap(account.localStorage.getMainContext())
        for (index, id) in ["first", "second"].enumerated() {
            context.insert(SpaceModel(spaceId: id, profileId: "Default", name: id,
                                      colorHex: "#123456", iconName: "circle", sortOrder: index))
        }
        try context.save()
        XCTAssertTrue(account.userDefaults.set([[
            "activeSpaceId": "first", "isLandingEntry": true,
            "windowMap": ["101": "first", "102": "second"]
        ]], forKey: .slotsRestoreSnapshot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: account.userDataStorage
            .appendingPathComponent("localDB/LocalStore.sqlite").path))
        try await account.localStorage.closeForAccountDirectoryRemoval()
        accountsToClose.removeAll()

        // Use new Account/LocalStore/AccountUserDefaults instances so both the
        // Space list and the window mapping must come back from disk.
        let reopened = Account(userID: account.userID)
        accountsToClose.append(reopened)
        let reopenedContext = try XCTUnwrap(reopened.localStorage.getMainContext())
        XCTAssertEqual(Set(try reopenedContext.fetch(FetchDescriptor<SpaceModel>()).map(\.spaceId)),
                       ["first", "second"])
        let previousBoundAccount = UserDefaults.standard.object(forKey: SpaceManager.lastBoundAccountUserIDKey)
        defer { UserDefaults.standard.set(previousBoundAccount, forKey: SpaceManager.lastBoundAccountUserIDKey) }
        let manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: reopened)
        defer {
            manager.markTerminating()
            manager.discardSpacePrewarm()
        }
        let first = try XCTUnwrap(manager.claimRestoredWindow(
            forRestoredFromWindowId: 101, profileId: "Default", arrivingWindowId: 201))
        let second = try XCTUnwrap(manager.claimRestoredWindow(
            forRestoredFromWindowId: 102, profileId: "Default", arrivingWindowId: 202))
        XCTAssertTrue(first.slot === second.slot, "Restored backing windows must share one visible window slot")
        XCTAssertEqual(first.spaceId, "first")
        XCTAssertEqual(second.spaceId, "second")
        XCTAssertEqual(manager.slots.count, 1)
    }
}
