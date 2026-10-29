// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

@MainActor
final class SpaceCreationOrderTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testInsertsAfterSourceAcrossProfilesAndPersistsTheShift() async throws {
        let store = try makeStore()
        create("a", in: store)
        create("b", in: store)
        create("c", in: store)
        create("new", profileId: "Profile 2", after: "a", in: store)
        await store.performBackgroundWriteAndWait { _ in }

        let spaces = store.getAllSpaces()
        XCTAssertEqual(spaces.map(\.spaceId), ["a", "new", "b", "c"])
        XCTAssertEqual(spaces.map(\.sortOrder), [0, 1, 2, 3])
        XCTAssertEqual(spaces[1].profileId, "Profile 2")
    }

    func testConsecutiveInsertionsUseTheLatestPersistedOrder() async throws {
        let store = try makeStore()
        create("a", in: store)
        create("b", in: store)
        create("first", after: "a", in: store)
        create("second", after: "a", in: store)
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(store.getAllSpaces().map(\.spaceId), ["a", "second", "first", "b"])
        XCTAssertEqual(store.getAllSpaces().map(\.sortOrder), [0, 1, 2, 3])
    }

    func testMissingSourceAndUnspecifiedSourceAppend() async throws {
        let store = try makeStore()
        create("a", in: store)
        create("missing-source", after: "deleted", in: store)
        create("append", in: store)
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(store.getAllSpaces().map(\.spaceId), ["a", "missing-source", "append"])
    }

    func testInsertionPreservesTheOrderWhenExistingSortValuesTie() async throws {
        let store = try makeStore()
        create("a", profileId: "Profile Z", in: store)
        create("b", profileId: "Profile A", in: store)
        create("c", profileId: "Profile Z", in: store)
        try await store.performBackgroundWriteAndWaitThrowing { context in
            for space in try context.fetch(FetchDescriptor<SpaceModel>()) {
                space.sortOrder = 0
            }
        }
        XCTAssertEqual(store.getAllSpaces().map(\.spaceId), ["b", "a", "c"])

        create("new", after: "a", in: store)
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(store.getAllSpaces().map(\.spaceId), ["b", "a", "new", "c"])
        XCTAssertEqual(store.getAllSpaces().map(\.sortOrder), [0, 1, 2, 3])
    }

    private func create(_ id: String, profileId: String = "Default",
                        after source: String? = nil, in store: LocalStore) {
        store.createSpace(profileId: profileId, name: id, colorHex: "#3A6FF8",
                          iconName: "star", spaceId: id, afterSpaceId: source)
    }

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        return LocalStore(account: Account(userID: UUID().uuidString),
                          storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
    }
}
