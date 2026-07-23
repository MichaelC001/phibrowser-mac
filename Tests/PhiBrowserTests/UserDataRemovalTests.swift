// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class UserDataRemovalTests: XCTestCase {
    private var parentURL: URL!
    private var targets: UserDataRemoval.Targets!

    override func setUpWithError() throws {
        parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserDataRemovalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        targets = UserDataRemoval.Targets(
            dataRootURL: parentURL.appendingPathComponent("com.phibrowser.test.Mac", isDirectory: true),
            cachesURL: parentURL.appendingPathComponent("caches/com.phibrowser.test.Mac", isDirectory: true),
            preferencesPlistURL: parentURL.appendingPathComponent("com.phibrowser.test.Mac.plist"),
            preferencesDomain: "com.phibrowser.test.Mac"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parentURL)
    }

    // MARK: - Targets

    func testCurrentProductTargetsFollowHostBundleIdentifier() throws {
        let bundleId = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let current = UserDataRemoval.Targets.currentProduct

        XCTAssertEqual(current.dataRootURL.lastPathComponent, bundleId)
        XCTAssertEqual(current.cachesURL.lastPathComponent, bundleId)
        XCTAssertEqual(current.preferencesPlistURL.lastPathComponent, "\(bundleId).plist")
        XCTAssertEqual(current.preferencesDomain, bundleId)
    }

    // MARK: - Move aside

    func testMoveAsideRelocatesDirectoriesWithContentIntact() throws {
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "local-state")
        try makeFile(
            at: targets.dataRootURL.appendingPathComponent("Default/Preferences"),
            contents: "profile-prefs"
        )
        try makeFile(
            at: targets.dataRootURL.appendingPathComponent("Phi/users/user-1/defaults/prefs.plist"),
            contents: "mac-side"
        )
        try makeFile(at: targets.cachesURL.appendingPathComponent("Cache/data_0"), contents: "cache-entry")

        let movedAside = UserDataRemoval.moveAsideForDeletion(targets)

        XCTAssertFalse(FileManager.default.fileExists(atPath: targets.dataRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets.cachesURL.path))
        XCTAssertEqual(movedAside.count, 2)

        let movedDataRoot = try XCTUnwrap(
            movedAside.first { $0.lastPathComponent.hasPrefix("com.phibrowser.test.Mac.phi-deleting-") }
        )
        XCTAssertEqual(
            try relativeFilePaths(under: movedDataRoot),
            ["Default/Preferences", "Local State", "Phi/users/user-1/defaults/prefs.plist"]
        )
        XCTAssertEqual(
            try String(contentsOf: movedDataRoot.appendingPathComponent("Local State"), encoding: .utf8),
            "local-state"
        )

        let movedCaches = try XCTUnwrap(movedAside.first { $0 != movedDataRoot })
        XCTAssertEqual(movedCaches.deletingLastPathComponent(), targets.cachesURL.deletingLastPathComponent())
        XCTAssertEqual(try relativeFilePaths(under: movedCaches), ["Cache/data_0"])
    }

    func testMoveAsideWithNothingAtCanonicalPathsReturnsEmpty() {
        XCTAssertEqual(UserDataRemoval.moveAsideForDeletion(targets), [])
    }

    func testRepeatedMoveAsideLeavesEarlierMoveUntouched() throws {
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "local-state")

        let firstMove = UserDataRemoval.moveAsideForDeletion(targets)
        let secondMove = UserDataRemoval.moveAsideForDeletion(targets)

        XCTAssertEqual(firstMove.count, 1)
        XCTAssertEqual(secondMove, [])
        XCTAssertEqual(try relativeFilePaths(under: firstMove[0]), ["Local State"])
    }

    // MARK: - Detached cleaner script

    func testCleanerScriptWaitsForMainProcessAndDeletesMovedThenCanonicalTwice() throws {
        let movedAside = [parentURL.appendingPathComponent("com.phibrowser.test.Mac.phi-deleting-abc")]

        let script = UserDataRemoval.detachedCleanerScript(
            for: targets,
            movedAside: movedAside,
            mainProcessID: 4242
        )

        XCTAssertTrue(script.contains("while /bin/kill -0 4242"))

        let passes = Array(script.components(separatedBy: "/bin/rm -rf --").dropFirst())
        XCTAssertEqual(passes.count, 3)
        XCTAssertTrue(passes[0].contains("'\(movedAside[0].path)'"))
        for pass in passes.dropFirst() {
            XCTAssertTrue(pass.contains("'\(targets.dataRootURL.path)'"))
            XCTAssertTrue(pass.contains("'\(targets.cachesURL.path)'"))
            XCTAssertTrue(pass.contains("'\(targets.preferencesPlistURL.path)'"))
            XCTAssertFalse(pass.contains(movedAside[0].path))
        }
    }

    func testCleanerScriptWithoutMovedAsideDeletesOnlyCanonicalPaths() {
        let script = UserDataRemoval.detachedCleanerScript(
            for: targets,
            movedAside: [],
            mainProcessID: 4242
        )

        let passes = Array(script.components(separatedBy: "/bin/rm -rf --").dropFirst())
        XCTAssertEqual(passes.count, 2)
        for pass in passes {
            XCTAssertTrue(pass.contains("'\(targets.dataRootURL.path)'"))
        }
    }

    func testCleanerScriptSingleQuotesShellMetacharacters() {
        let hostileTargets = UserDataRemoval.Targets(
            dataRootURL: parentURL.appendingPathComponent("dir with spaces; $(rm x)", isDirectory: true),
            cachesURL: parentURL.appendingPathComponent("it's a cache", isDirectory: true),
            preferencesPlistURL: parentURL.appendingPathComponent("prefs.plist"),
            preferencesDomain: "com.phibrowser.test.Mac"
        )

        let script = UserDataRemoval.detachedCleanerScript(
            for: hostileTargets,
            movedAside: [],
            mainProcessID: 1
        )

        XCTAssertTrue(script.contains("'\(parentURL.path)/dir with spaces; $(rm x)'"))
        XCTAssertTrue(script.contains("'\(parentURL.path)/it'\\''s a cache'"))
    }

    // MARK: - Startup fallback sweep

    func testSweepRemovesOnlyMoveAsideLeftovers() throws {
        let leftoverA = parentURL.appendingPathComponent("com.phibrowser.test.Mac.phi-deleting-aaa", isDirectory: true)
        let leftoverB = parentURL.appendingPathComponent("com.phibrowser.test.Mac.phi-deleting-bbb", isDirectory: true)
        let cachesLeftover = targets.cachesURL.deletingLastPathComponent()
            .appendingPathComponent("com.phibrowser.test.Mac.phi-deleting-ccc", isDirectory: true)
        let unrelatedSibling = parentURL.appendingPathComponent("com.phibrowser.other.Mac", isDirectory: true)
        try makeFile(at: leftoverA.appendingPathComponent("Local State"), contents: "stale")
        try makeFile(at: leftoverB.appendingPathComponent("Local State"), contents: "stale")
        try makeFile(at: cachesLeftover.appendingPathComponent("Cache/data_0"), contents: "stale")
        try makeFile(at: unrelatedSibling.appendingPathComponent("keep-me"), contents: "live")
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "live")

        UserDataRemoval.sweepLeftoverMoveAsideDirectories(for: targets)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftoverA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftoverB.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachesLeftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedSibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets.dataRootURL.path))
    }

    func testSweepWithMissingParentDirectoriesDoesNotThrow() {
        let orphanTargets = UserDataRemoval.Targets(
            dataRootURL: parentURL.appendingPathComponent("missing/data-root", isDirectory: true),
            cachesURL: parentURL.appendingPathComponent("missing/caches", isDirectory: true),
            preferencesPlistURL: parentURL.appendingPathComponent("missing/prefs.plist"),
            preferencesDomain: "com.phibrowser.test.Mac"
        )

        UserDataRemoval.sweepLeftoverMoveAsideDirectories(for: orphanTargets)
    }

    // MARK: - Helpers

    private func makeFile(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func relativeFilePaths(under root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = fileURL.standardizedFileURL.path
                .replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
            paths.append(relative)
        }
        return paths.sorted()
    }
}
