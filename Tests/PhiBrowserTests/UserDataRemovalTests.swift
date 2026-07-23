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

    func testCleanerPIDFileSitsNextToTheDataRootOutsideAllTargets() {
        XCTAssertEqual(
            targets.cleanerPIDFileURL,
            parentURL.appendingPathComponent("com.phibrowser.test.Mac.phi-deletion-cleaner.pid")
        )
    }

    func testCurrentProductKeepsTimeMachineOutOfTheDebugClear() {
        // Recorded decision: the debug menu's clear keeps the upgrade
        // snapshots — they are the upgrade safety net. Only the account
        // deletion targets them.
        XCTAssertNil(UserDataRemoval.Targets.currentProduct.timeMachineRootURL)
    }

    func testCurrentProductIncludingTimeMachineAddsTheProductTimeMachineRoot() throws {
        let bundleId = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let withTimeMachine = UserDataRemoval.Targets.currentProductIncludingTimeMachine
        let base = UserDataRemoval.Targets.currentProduct

        XCTAssertEqual(withTimeMachine.dataRootURL, base.dataRootURL)
        XCTAssertEqual(withTimeMachine.cachesURL, base.cachesURL)
        XCTAssertEqual(withTimeMachine.preferencesPlistURL, base.preferencesPlistURL)
        XCTAssertEqual(withTimeMachine.preferencesDomain, base.preferencesDomain)
        let timeMachineRootURL = try XCTUnwrap(withTimeMachine.timeMachineRootURL)
        XCTAssertEqual(timeMachineRootURL.lastPathComponent, bundleId)
        XCTAssertEqual(
            timeMachineRootURL.deletingLastPathComponent().lastPathComponent,
            "com.phibrowser.TimeMachine"
        )
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

    func testMoveAsideIncludesTheTimeMachineRootAndSparesTheSiblingChannel() throws {
        let withTimeMachine = targetsIncludingTimeMachine
        let timeMachineRootURL = try XCTUnwrap(withTimeMachine.timeMachineRootURL)
        try makeFile(at: timeMachineRootURL.appendingPathComponent("catalog.json"), contents: "catalog")
        try makeFile(
            at: timeMachineRootURL.appendingPathComponent(
                "Snapshots/11111111-1111-1111-1111-111111111111/manifest.json"
            ),
            contents: "snapshot"
        )
        // A pending restore travels out of the canonical path with the
        // move: the startup recovery gate reads the canonical root, so the
        // atomic rename is what makes "deleted + restore pending"
        // unreachable on the normal path.
        try makeFile(
            at: timeMachineRootURL.appendingPathComponent(
                "Pending/22222222-2222-2222-2222-222222222222/restore-journal.json"
            ),
            contents: "journal"
        )
        let siblingChannelRoot = timeMachineParentURL
            .appendingPathComponent("com.phibrowser.other.Mac", isDirectory: true)
        try makeFile(at: siblingChannelRoot.appendingPathComponent("catalog.json"), contents: "sibling-catalog")
        try makeFile(at: withTimeMachine.dataRootURL.appendingPathComponent("Local State"), contents: "local-state")

        let movedAside = UserDataRemoval.moveAsideForDeletion(withTimeMachine)

        XCTAssertEqual(movedAside.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: timeMachineRootURL.path))
        let movedTimeMachine = try XCTUnwrap(
            movedAside.first {
                $0.deletingLastPathComponent() == timeMachineParentURL
                    && $0.lastPathComponent.hasPrefix("com.phibrowser.test.Mac.phi-deleting-")
            }
        )
        XCTAssertEqual(
            try relativeFilePaths(under: movedTimeMachine),
            [
                "Pending/22222222-2222-2222-2222-222222222222/restore-journal.json",
                "Snapshots/11111111-1111-1111-1111-111111111111/manifest.json",
                "catalog.json",
            ]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: siblingChannelRoot.appendingPathComponent("catalog.json").path)
        )
    }

    func testMoveAsideWithoutTimeMachineTargetLeavesTheTimeMachineRootAlone() throws {
        let timeMachineRootURL = timeMachineParentURL
            .appendingPathComponent("com.phibrowser.test.Mac", isDirectory: true)
        try makeFile(at: timeMachineRootURL.appendingPathComponent("catalog.json"), contents: "catalog")
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "local-state")

        let movedAside = UserDataRemoval.moveAsideForDeletion(targets)

        XCTAssertEqual(movedAside.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: timeMachineRootURL.appendingPathComponent("catalog.json").path)
        )
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

    func testCleanerScriptRecordsItsPIDForTheWholeCleanupLifetime() {
        let pidFilePath = targets.cleanerPIDFileURL.path

        let script = UserDataRemoval.detachedCleanerScript(
            for: targets,
            movedAside: [],
            mainProcessID: 4242
        )

        // The outer shell records the subshell's PID and start time right
        // after backgrounding it (only the outer shell knows that PID) ...
        XCTAssertTrue(script.contains("echo $! > '\(pidFilePath)'"))
        XCTAssertTrue(script.contains("/bin/ps -o lstart= -p $! >> '\(pidFilePath)'"))
        // ... and the subshell's final act removes the file, so its presence
        // spans the whole cleanup — the startup takeover's liveness marker.
        XCTAssertTrue(script.contains("/bin/rm -f -- '\(pidFilePath)' )"))
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

    func testCleanerScriptIncludesTheTimeMachineRootWhenTargeted() throws {
        let withTimeMachine = targetsIncludingTimeMachine
        let timeMachineRootURL = try XCTUnwrap(withTimeMachine.timeMachineRootURL)

        let script = UserDataRemoval.detachedCleanerScript(
            for: withTimeMachine,
            movedAside: [],
            mainProcessID: 4242
        )

        let passes = Array(script.components(separatedBy: "/bin/rm -rf --").dropFirst())
        XCTAssertEqual(passes.count, 2)
        for pass in passes {
            XCTAssertTrue(pass.contains("'\(timeMachineRootURL.path)'"))
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
        try makeFile(at: targets.cleanerPIDFileURL, contents: "4242\nstale")

        UserDataRemoval.sweepLeftoverMoveAsideDirectories(for: targets)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftoverA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftoverB.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachesLeftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedSibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets.dataRootURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targets.cleanerPIDFileURL.path),
            "The PID file is the takeover's marker, not the sweep's to remove"
        )
    }

    func testSweepParksUndeletableLeftoverOutsideTheMarkerNamespace() throws {
        // An unreadable subdirectory makes the recursive delete fail; the
        // sweep must then rename the leftover out of the marker namespace,
        // or every subsequent launch would re-trigger the takeover and
        // delete the fresh canonical profile again.
        let leftover = parentURL.appendingPathComponent(
            "com.phibrowser.test.Mac.phi-deleting-jammed", isDirectory: true
        )
        let lockedSubdir = leftover.appendingPathComponent("locked", isDirectory: true)
        try makeFile(at: lockedSubdir.appendingPathComponent("data"), contents: "x")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: lockedSubdir.path
        )
        addTeardownBlock { [parentURL] in
            // Unlock wherever the directory ended up so teardown can delete it.
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parentURL!.path)) ?? []
            for name in siblings {
                let candidate = parentURL!.appendingPathComponent(name)
                    .appendingPathComponent("locked")
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: candidate.path
                )
            }
        }

        UserDataRemoval.sweepLeftoverMoveAsideDirectories(for: targets)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        let parked = parentURL.appendingPathComponent(
            "com.phibrowser.test.Mac.phi-deletion-stuck-jammed", isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))

        // With the marker gone, a takeover on the next launch is a no-op —
        // the fresh canonical data survives.
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "fresh")
        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: targets)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets.dataRootURL.path))
    }

    func testSweepRemovesTimeMachineLeftoversButNotLiveRootsOrOtherChannels() throws {
        let withTimeMachine = targetsIncludingTimeMachine
        let timeMachineRootURL = try XCTUnwrap(withTimeMachine.timeMachineRootURL)
        let leftover = timeMachineParentURL.appendingPathComponent(
            "com.phibrowser.test.Mac.phi-deleting-aaa", isDirectory: true
        )
        // Another channel's leftover belongs to that channel's cleaner and
        // takeover — this product must not touch it.
        let otherChannelLeftover = timeMachineParentURL.appendingPathComponent(
            "com.phibrowser.other.Mac.phi-deleting-bbb", isDirectory: true
        )
        try makeFile(at: leftover.appendingPathComponent("catalog.json"), contents: "stale")
        try makeFile(at: otherChannelLeftover.appendingPathComponent("catalog.json"), contents: "other-channel")
        try makeFile(at: timeMachineRootURL.appendingPathComponent("catalog.json"), contents: "live")

        UserDataRemoval.sweepLeftoverMoveAsideDirectories(for: withTimeMachine)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherChannelLeftover.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: timeMachineRootURL.appendingPathComponent("catalog.json").path)
        )
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

    // MARK: - Cleaner PID file parsing

    func testParseCleanerPIDFileParsesPIDAndStartTime() {
        let record = UserDataRemoval.parseCleanerPIDFile("4242\nWed Jul 22 12:34:56 2026\n")

        XCTAssertEqual(record?.pid, 4242)
        XCTAssertEqual(record?.startedAt, "Wed Jul 22 12:34:56 2026")
    }

    func testParseCleanerPIDFileWithoutStartTimeIsRejected() {
        // Without the start time a recycled PID cannot be told apart from
        // the cleaner, so the record must not authorize a kill.
        XCTAssertNil(UserDataRemoval.parseCleanerPIDFile("4242\n"))
        XCTAssertNil(UserDataRemoval.parseCleanerPIDFile("4242\n   \n"))
    }

    func testParseCleanerPIDFileGarbageIsRejected() {
        XCTAssertNil(UserDataRemoval.parseCleanerPIDFile(""))
        XCTAssertNil(UserDataRemoval.parseCleanerPIDFile("not-a-pid\nWed Jul 22 12:34:56 2026"))
        XCTAssertNil(UserDataRemoval.parseCleanerPIDFile("-1\nWed Jul 22 12:34:56 2026"))
    }

    // MARK: - Startup takeover

    func testTakeOverWithNoMarkersLeavesEverythingAlone() throws {
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "live")
        try makeFile(at: targets.preferencesPlistURL, contents: "live-prefs")

        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: targets)

        XCTAssertTrue(FileManager.default.fileExists(atPath: targets.dataRootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets.preferencesPlistURL.path))
    }

    func testTakeOverSweepsResidueAndLeftoversWhenTheCleanerNeverRan() throws {
        // Rename succeeded but the cleaner never spawned: leftover directory
        // present, no PID file, shutdown rewrites at the canonical paths.
        let leftover = parentURL.appendingPathComponent(
            "com.phibrowser.test.Mac.phi-deleting-abc", isDirectory: true
        )
        try makeFile(at: leftover.appendingPathComponent("Local State"), contents: "old")
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "residue")
        try makeFile(at: targets.cachesURL.appendingPathComponent("Cache/data_0"), contents: "residue")
        try makeFile(at: targets.preferencesPlistURL, contents: "residue-prefs")

        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: targets)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets.dataRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets.cachesURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets.preferencesPlistURL.path))
    }

    func testTakeOverWithStaleCleanerRecordSkipsTheKillAndProceeds() throws {
        // PID 1 is always alive, but its start time cannot match the
        // recorded one — the takeover must treat the record as a recycled
        // PID (never kill it) and still finish the removal.
        try makeFile(
            at: targets.cleanerPIDFileURL,
            contents: "1\nThu Jan  1 00:00:00 1970\n"
        )
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "residue")

        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: targets)

        XCTAssertFalse(FileManager.default.fileExists(atPath: targets.dataRootURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: targets.cleanerPIDFileURL.path),
            "A finished takeover must clear the marker itself"
        )
    }

    func testTakeOverKillsTheLiveCleanerBeforeDeleting() throws {
        let cleaner = Process()
        cleaner.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleaner.arguments = ["-c", "sleep 30"]
        let died = expectation(description: "cleaner stopped")
        cleaner.terminationHandler = { _ in died.fulfill() }
        try cleaner.run()
        defer { if cleaner.isRunning { cleaner.terminate() } }

        let pid = cleaner.processIdentifier
        let startTime = try XCTUnwrap(processStartTime(of: pid))
        try makeFile(at: targets.cleanerPIDFileURL, contents: "\(pid)\n\(startTime)\n")
        try makeFile(at: targets.dataRootURL.appendingPathComponent("Local State"), contents: "residue")

        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: targets)

        wait(for: [died], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets.dataRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets.cleanerPIDFileURL.path))
    }

    // MARK: - Time Machine restore suppression

    func testTakeOverCancelsPendingRestoresButKeepsSnapshotsAndCatalog() throws {
        // The rename-failed corner: markers exist, but the Time Machine
        // root survived at its canonical path with a restore pending. The
        // takeover must cancel the restore — the recovery gate runs right
        // after it and would otherwise resurrect the deleted data — by
        // removing the whole operation directory (a journal-less one would
        // linger invisibly with its downloaded package, since every Time
        // Machine cleanup path is keyed on the journal), while keeping
        // snapshots and catalog, because canonical Time Machine content is
        // also what an interrupted debug-menu clear leaves, and that flow
        // keeps the snapshots.
        let withTimeMachine = targetsIncludingTimeMachine
        let timeMachineRootURL = try XCTUnwrap(withTimeMachine.timeMachineRootURL)
        let dataRootLeftover = parentURL.appendingPathComponent(
            "com.phibrowser.test.Mac.phi-deleting-abc", isDirectory: true
        )
        try makeFile(at: dataRootLeftover.appendingPathComponent("Local State"), contents: "old")
        let operationURL = timeMachineRootURL.appendingPathComponent(
            "Pending/33333333-3333-3333-3333-333333333333", isDirectory: true
        )
        try makeFile(at: operationURL.appendingPathComponent("restore-journal.json"), contents: "journal")
        try makeFile(at: operationURL.appendingPathComponent("package.zip"), contents: "package")
        // A journal-less operation directory is invisible to the recovery
        // gate — there is no restore to cancel, so it is not this hook's
        // to touch.
        let journallessArtifactURL = timeMachineRootURL.appendingPathComponent(
            "Pending/66666666-6666-6666-6666-666666666666/leftover.bin"
        )
        try makeFile(at: journallessArtifactURL, contents: "leftover")
        try makeFile(at: timeMachineRootURL.appendingPathComponent("catalog.json"), contents: "catalog")
        let manifestURL = timeMachineRootURL.appendingPathComponent(
            "Snapshots/44444444-4444-4444-4444-444444444444/manifest.json"
        )
        try makeFile(at: manifestURL, contents: "snapshot")

        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: withTimeMachine)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dataRootLeftover.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: operationURL.path),
            "Cancelling removes the journal and its operation artifacts together"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: journallessArtifactURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: timeMachineRootURL.appendingPathComponent("catalog.json").path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testTakeOverTriggersOnATimeMachineLeftoverAlone() throws {
        // Rename of the Time Machine root succeeded but everything after
        // died: the leftover is a takeover signal like any other, so the
        // canonical residue still gets cleared and the leftover swept.
        let withTimeMachine = targetsIncludingTimeMachine
        let leftover = timeMachineParentURL.appendingPathComponent(
            "com.phibrowser.test.Mac.phi-deleting-abc", isDirectory: true
        )
        try makeFile(at: leftover.appendingPathComponent("catalog.json"), contents: "old")
        try makeFile(at: withTimeMachine.dataRootURL.appendingPathComponent("Local State"), contents: "residue")

        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: withTimeMachine)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: withTimeMachine.dataRootURL.path))
    }

    func testTakeOverWithNoMarkersLeavesPendingRestoresAlone() throws {
        // No takeover signal means a normal launch: a legitimately pending
        // restore must reach the recovery gate untouched.
        let withTimeMachine = targetsIncludingTimeMachine
        let timeMachineRootURL = try XCTUnwrap(withTimeMachine.timeMachineRootURL)
        let journalURL = timeMachineRootURL.appendingPathComponent(
            "Pending/55555555-5555-5555-5555-555555555555/restore-journal.json"
        )
        try makeFile(at: journalURL, contents: "journal")

        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: withTimeMachine)

        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    // MARK: - Helpers

    private var timeMachineParentURL: URL {
        parentURL.appendingPathComponent("com.phibrowser.TimeMachine", isDirectory: true)
    }

    /// `targets` plus a Time Machine root inside the throwaway tree — the
    /// account-deletion shape of the targets.
    private var targetsIncludingTimeMachine: UserDataRemoval.Targets {
        UserDataRemoval.Targets(
            dataRootURL: targets.dataRootURL,
            cachesURL: targets.cachesURL,
            preferencesPlistURL: targets.preferencesPlistURL,
            preferencesDomain: targets.preferencesDomain,
            timeMachineRootURL: timeMachineParentURL
                .appendingPathComponent("com.phibrowser.test.Mac", isDirectory: true)
        )
    }

    private func processStartTime(of pid: Int32) throws -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(pid)]
        let stdout = Pipe()
        ps.standardOutput = stdout
        try ps.run()
        ps.waitUntilExit()
        return String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
