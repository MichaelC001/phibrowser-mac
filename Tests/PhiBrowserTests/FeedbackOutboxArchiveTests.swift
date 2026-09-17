// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Security
import XCTest
@testable import Phi

final class FeedbackOutboxArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedbackOutboxArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    func testBucketArchiveItemsUsesOriginalByteCounts() {
        let halfBucket = UInt64(FeedbackOutbox.zipPlanningBytes / 2)
        let items = [
            archiveItem(path: "PhiLogs/a.log", plannedBytes: halfBucket),
            archiveItem(path: "PhiLogs/b.log", plannedBytes: halfBucket),
            archiveItem(path: "SentinelLogs/c.log", plannedBytes: 1)
        ]

        let buckets = FeedbackOutbox.bucketArchiveItems(items)

        XCTAssertEqual(buckets.map { $0.map(\.archivePath) }, [
            ["PhiLogs/a.log", "PhiLogs/b.log"],
            ["SentinelLogs/c.log"]
        ])
        XCTAssertTrue(buckets.allSatisfy { bucket in
            let total = bucket.reduce(Int64(0)) { $0 + Int64($1.length) }
            return total <= FeedbackOutbox.zipPlanningBytes
        })
    }

    func testCrashSnapshotSurvivesLogRotationAndArchiveRetry() throws {
        let log = root.appendingPathComponent("current.log")
        try Data("before crash".utf8).write(to: log)
        let context = PreviousSessionCrashContext(
            eventID: "crash-event", timestamp: nil,
            logSnapshot: PhiLogging.logSnapshot(paths: [log.path], maxBytes: 1024)
        )
        let jobRoot = try makeJobDirectory()
        let saved = try XCTUnwrap(FeedbackOutbox.savePreviousSessionCrashLog(context, jobRoot: jobRoot))
        try Data("after relaunch".utf8).write(to: log)
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        for _ in 0..<2 {
            let attachments = try FeedbackOutbox.prepareLogZipAttachments(
                jobRoot: jobRoot, preparedDir: preparedDir, chromiumSystemLogs: nil,
                previousSessionCrashLog: saved,
                phiLogsURL: root.appendingPathComponent("missing-phi"),
                sentinelLogsURL: root.appendingPathComponent("missing-sentinel")
            )
            let archive = try XCTUnwrap(attachments.first { $0.filename == "logs.zip" })
            XCTAssertEqual(
                try zipEntryText("PreviousSessionCrash/logs.txt", in: jobRoot.appendingPathComponent(archive.relativePath)),
                "before crash"
            )
            try FileManager.default.removeItem(at: jobRoot.appendingPathComponent(archive.relativePath))
        }
    }

    func testMissingQueuedCrashSnapshotFailsInsteadOfSendingOnlyCurrentLogs() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let missing = FeedbackOutboxSourceAttachment(
            relativePath: "logs/missing.log", filename: "missing.log", mimeType: "text/plain", size: 10
        )
        XCTAssertThrowsError(try FeedbackOutbox.prepareLogZipAttachments(
            jobRoot: jobRoot, preparedDir: preparedDir, chromiumSystemLogs: nil,
            previousSessionCrashLog: missing,
            phiLogsURL: root.appendingPathComponent("missing-phi"),
            sentinelLogsURL: root.appendingPathComponent("missing-sentinel")
        ))
    }

    func testCollectLogArchiveItemsSplitsOversizedLogFiles() throws {
        let logsRoot = root.appendingPathComponent("PhiLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        try Data("small".utf8).write(to: logsRoot.appendingPathComponent("small.log"))

        let largeLog = logsRoot.appendingPathComponent("large.log")
        FileManager.default.createFile(atPath: largeLog.path, contents: nil)
        let handle = try FileHandle(forWritingTo: largeLog)
        try handle.truncate(atOffset: UInt64(FeedbackOutbox.zipPlanningBytes + 1024))
        try handle.close()

        let items = try FeedbackOutbox.collectLogArchiveItems(root: logsRoot, archiveRoot: "PhiLogs")
        let largeParts = items.filter { $0.archivePath.hasPrefix("PhiLogs/large.log.part-") }

        XCTAssertEqual(largeParts.count, 2)
        XCTAssertEqual(largeParts[0].archivePath, "PhiLogs/large.log.part-1")
        XCTAssertEqual(largeParts[0].offset, 0)
        XCTAssertEqual(largeParts[0].length, UInt64(FeedbackOutbox.zipPlanningBytes))
        XCTAssertEqual(largeParts[1].archivePath, "PhiLogs/large.log.part-2")
        XCTAssertEqual(largeParts[1].offset, UInt64(FeedbackOutbox.zipPlanningBytes))
        XCTAssertEqual(largeParts[1].length, 1024)
    }

    func testSelectedAttachmentInfoAcceptsRegularFilesUnderLimit() throws {
        let fileURL = root.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: fileURL)

        let info = try FeedbackOutbox.selectedAttachmentInfo(for: fileURL)

        XCTAssertEqual(info.size, 5)
        XCTAssertFalse(info.isImage)
        XCTAssertEqual(info.mimeType, "text/plain")
    }

    func testSelectedAttachmentInfoRejectsDirectories() throws {
        let directoryURL = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try FeedbackOutbox.selectedAttachmentInfo(for: directoryURL))
    }

    func testSelectedAttachmentInfoRejectsSymlinks() throws {
        let targetURL = root.appendingPathComponent("target.txt")
        let linkURL = root.appendingPathComponent("target-link.txt")
        try Data("hello".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try FeedbackOutbox.selectedAttachmentInfo(for: linkURL))
    }

    func testSelectedAttachmentInfoRejectsFilesOverTenMegabytes() throws {
        let fileURL = root.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(FeedbackOutbox.maxSelectedAttachmentBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try FeedbackOutbox.selectedAttachmentInfo(for: fileURL))
    }

    func testBrowserChannelNameMapsNightlyBuildToCanary() {
        XCTAssertEqual(
            FeedbackOutbox.browserChannelName(isNightlyBuild: true, isDebugBuild: false),
            "canary"
        )
    }

    func testBrowserChannelNamePrefersNightlyOverDebug() {
        XCTAssertEqual(
            FeedbackOutbox.browserChannelName(isNightlyBuild: true, isDebugBuild: true),
            "canary"
        )
    }

    func testBrowserChannelNameMapsDebugBuildToDebug() {
        XCTAssertEqual(
            FeedbackOutbox.browserChannelName(isNightlyBuild: false, isDebugBuild: true),
            "debug"
        )
    }

    func testBrowserChannelNameDefaultsToStable() {
        XCTAssertEqual(
            FeedbackOutbox.browserChannelName(isNightlyBuild: false, isDebugBuild: false),
            "stable"
        )
    }

    func testFeedbackComponentsIncludeRunningSentinelVersion() {
        let components = FeedbackOutbox.feedbackComponents(
            extensionVersions: ["phi-sidecar": "2.0.0"],
            runningSentinelInfo: SentinelHelper.RunningInfo(
                bundleID: "com.phibrowser.Sentinel",
                version: "1.3.3",
                build: "414"
            )
        )

        let sentinel = components.first { $0.id == "com.phibrowser.Sentinel" }
        XCTAssertEqual(sentinel?.name, "Phi Sentinel")
        XCTAssertEqual(sentinel?.type, "component")
        XCTAssertEqual(sentinel?.version, "1.3.3")
        XCTAssertEqual(components.first { $0.id == "phi-sidecar" }?.type, "extension")
    }

    func testFeedbackComponentsSkipSentinelWithoutVersion() {
        let components = FeedbackOutbox.feedbackComponents(
            extensionVersions: ["phi-sidecar": "2.0.0"],
            runningSentinelInfo: SentinelHelper.RunningInfo(
                bundleID: "com.phibrowser.Sentinel",
                version: " ",
                build: "414"
            )
        )

        XCTAssertNil(components.first { $0.id == "com.phibrowser.Sentinel" })
        XCTAssertEqual(components.map(\.id), ["phi-sidecar"])
    }

    func testShouldDiscardFailedJobOnlyAfterFiveLargeRetries() {
        XCTAssertFalse(FeedbackOutbox.shouldDiscardFailedJob(retryCount: 5))
        XCTAssertTrue(FeedbackOutbox.shouldDiscardFailedJob(retryCount: 6))
    }

    func testMakeZipAttachmentsUsesLogsZipForSingleBucket() throws {
        let preparedDir = try makePreparedDirectory()
        let items = [
            archiveItem(path: "PhiLogs/a.log", inlineText: "phi"),
            archiveItem(path: "SentinelLogs/b.log", inlineText: "sentinel")
        ]

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: "logs.zip",
            numberedPrefix: "logs",
            attachmentType: .log,
            required: true
        )

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].filename, "logs.zip")
        XCTAssertEqual(attachments[0].mimeType, "application/zip")
        XCTAssertEqual(attachments[0].attachmentType, .log)
        XCTAssertTrue(attachments[0].required)
        XCTAssertGreaterThan(attachments[0].size, 0)
        XCTAssertLessThanOrEqual(attachments[0].size, FeedbackOutbox.maxAttachmentBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(attachments[0].relativePath).path))
    }

    func testMakeZipAttachmentsIncludesChromiumSystemLogsAtRoot() throws {
        let preparedDir = try makePreparedDirectory()
        let systemLogsText = "chromium system logs\n"
        let systemLogsURL = root.appendingPathComponent("system_logs.txt")
        try Data(systemLogsText.utf8).write(to: systemLogsURL)

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: [
                FeedbackOutbox.chromiumSystemLogsArchiveItem(sourceURL: systemLogsURL),
                archiveItem(path: "PhiLogs/a.log", inlineText: "phi")
            ],
            preparedDir: preparedDir,
            singleFilename: "logs.zip",
            numberedPrefix: "logs",
            attachmentType: .log,
            required: true,
            preferSingleArchiveWhenPossible: true
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs.zip"])
        let zipURL = root.appendingPathComponent(attachments[0].relativePath)
        XCTAssertEqual(try zipEntryText("system_logs.txt", in: zipURL), systemLogsText)
        XCTAssertEqual(try zipEntryText("PhiLogs/a.log", in: zipURL), "phi")
    }

    func testPrepareLogZipAttachmentsUsesTwoPrioritizedArchives() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let logsDir = jobRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let systemLogsURL = logsDir.appendingPathComponent("system_logs.txt")
        try Data("chromium logs".utf8).write(to: systemLogsURL)
        let chromiumSystemLogs = FeedbackOutboxSourceAttachment(
            relativePath: "logs/system_logs.txt",
            filename: "system_logs.txt",
            mimeType: "text/plain",
            size: 13
        )

        let phiLogsURL = root.appendingPathComponent("PhiLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: phiLogsURL, withIntermediateDirectories: true)
        let oldPhiURL = try writeLog("old phi", named: "old.log", in: phiLogsURL, modifiedAt: Date(timeIntervalSince1970: 100))
        let currentPhiURL = try writeLog("current phi", named: "current.log", in: phiLogsURL, modifiedAt: Date(timeIntervalSince1970: 200))

        let sentinelLogsURL = root.appendingPathComponent("SentinelLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: sentinelLogsURL, withIntermediateDirectories: true)
        let olderBootURL = try writeLog("old boot", named: "boot.log", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 100))
        let latestBootURL = try writeLog("latest boot", named: "boot.log.1", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 300))
        let latestRunnerURL = try writeLog("latest runner", named: "runner.log", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 250))
        let oldRunnerURL = try writeLog("old runner", named: "runner.log.1", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 150))
        let latestGatewayURL = try writeLog("latest gateway", named: "ai-gateway.log", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 275))
        let ignoredURL = try writeLog("ignored", named: "extra.log", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 400))

        let attachments = try FeedbackOutbox.prepareLogZipAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            chromiumSystemLogs: chromiumSystemLogs,
            phiLogsURL: phiLogsURL,
            sentinelLogsURL: sentinelLogsURL
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs.zip", "sentinel-logs.zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.attachmentType == .log })
        XCTAssertTrue(attachments.allSatisfy(\.required))
        XCTAssertTrue(attachments.allSatisfy { $0.size <= FeedbackOutbox.maxAttachmentBytes })

        let primaryZipURL = jobRoot.appendingPathComponent(attachments[0].relativePath)
        XCTAssertEqual(try zipEntryText("system_logs.txt", in: primaryZipURL), "chromium logs")
        XCTAssertEqual(try zipEntryText("PhiLogs/current.log", in: primaryZipURL), "current phi")
        XCTAssertFalse(try zipEntryExists("PhiLogs/old.log", in: primaryZipURL))

        let sentinelZipURL = jobRoot.appendingPathComponent(attachments[1].relativePath)
        XCTAssertEqual(try zipEntryText("SentinelLogs/boot.log.1", in: sentinelZipURL), "latest boot")
        XCTAssertEqual(try zipEntryText("SentinelLogs/runner.log", in: sentinelZipURL), "latest runner")
        XCTAssertEqual(try zipEntryText("SentinelLogs/ai-gateway.log", in: sentinelZipURL), "latest gateway")
        XCTAssertFalse(try zipEntryExists("SentinelLogs/boot.log", in: sentinelZipURL))
        XCTAssertFalse(try zipEntryExists("SentinelLogs/runner.log.1", in: sentinelZipURL))
        XCTAssertFalse(try zipEntryExists("SentinelLogs/extra.log", in: sentinelZipURL))

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPhiURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentPhiURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderBootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestBootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestRunnerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRunnerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestGatewayURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignoredURL.path))
    }

    func testPrepareLogZipAttachmentsSkipsZipOverActualSizeLimit() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let phiLogsURL = root.appendingPathComponent("PhiLogs", isDirectory: true)
        let sentinelLogsURL = root.appendingPathComponent("SentinelLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: phiLogsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sentinelLogsURL, withIntermediateDirectories: true)

        let largePhiLogURL = phiLogsURL.appendingPathComponent("current.log")
        try randomData(byteCount: Int(FeedbackOutbox.maxAttachmentBytes + 1024 * 1024)).write(to: largePhiLogURL)
        _ = try writeLog("runner", named: "runner.log", in: sentinelLogsURL, modifiedAt: Date())

        let attachments = try FeedbackOutbox.prepareLogZipAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            chromiumSystemLogs: nil,
            phiLogsURL: phiLogsURL,
            sentinelLogsURL: sentinelLogsURL
        )

        XCTAssertEqual(attachments.map(\.filename), ["sentinel-logs.zip"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("logs.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent(attachments[0].relativePath).path))
    }

    func testMakeZipAttachmentsPrefersSingleLogsZipWhenCompressedUnderLimit() throws {
        let preparedDir = try makePreparedDirectory()
        let items = [
            archiveItem(path: "PhiLogs/a.log", plannedBytes: UInt64(FeedbackOutbox.zipPlanningBytes)),
            archiveItem(path: "SentinelLogs/b.log", plannedBytes: 1)
        ]

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: "logs.zip",
            numberedPrefix: "logs",
            attachmentType: .log,
            required: true,
            preferSingleArchiveWhenPossible: true
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs.zip"])
        XCTAssertEqual(attachments[0].attachmentType, .log)
        XCTAssertLessThanOrEqual(attachments[0].size, FeedbackOutbox.maxAttachmentBytes)
    }

    func testMakeZipAttachmentsSplitsLogsWhenSingleZipExceedsLimit() throws {
        let preparedDir = try makePreparedDirectory()
        let first = try randomData(byteCount: 11 * 1024 * 1024)
        let second = try randomData(byteCount: 11 * 1024 * 1024)
        let items = [
            ArchiveItem(
                sourceURL: nil,
                inlineData: first,
                offset: 0,
                length: UInt64(first.count),
                archivePath: "PhiLogs/random-a.log"
            ),
            ArchiveItem(
                sourceURL: nil,
                inlineData: second,
                offset: 0,
                length: UInt64(second.count),
                archivePath: "SentinelLogs/random-b.log"
            )
        ]

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: "logs.zip",
            numberedPrefix: "logs",
            attachmentType: .log,
            required: true,
            preferSingleArchiveWhenPossible: true
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs-1.zip", "logs-2.zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.attachmentType == .log })
        XCTAssertTrue(attachments.allSatisfy { $0.size <= FeedbackOutbox.maxAttachmentBytes })
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("logs.zip").path))
    }

    func testMakeZipAttachmentsNumbersFeedbackFilesAcrossBuckets() throws {
        let preparedDir = try makePreparedDirectory()
        let items = [
            archiveItem(path: "first.bin", plannedBytes: UInt64(FeedbackOutbox.zipPlanningBytes)),
            archiveItem(path: "second.bin", plannedBytes: 1)
        ]

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: nil,
            numberedPrefix: "feedback-files",
            attachmentType: .other,
            required: false
        )

        XCTAssertEqual(attachments.map(\.filename), ["feedback-files-1.zip", "feedback-files-2.zip"])
        XCTAssertEqual(attachments.map { $0.attachmentType.rawValue }, ["other", "other"])
        XCTAssertEqual(attachments.map(\.required), [false, false])
        XCTAssertTrue(attachments.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.relativePath).path) })
    }

    func testPrepareImageAttachmentsKeepsPreviewImagesBeforeImagesZip() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let imagesDir = jobRoot.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let sources = try (1...5).map { index in
            let filename = "image-\(index).png"
            let fileURL = imagesDir.appendingPathComponent(filename)
            let data = Data(filename.utf8)
            try data.write(to: fileURL)
            return FeedbackOutboxSourceAttachment(
                relativePath: "images/\(filename)",
                filename: filename,
                mimeType: "image/png",
                size: Int64(data.count)
            )
        }

        let attachments = try FeedbackOutbox.prepareImageAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            sources: sources,
            preferredSlots: 3,
            maxSlots: 4
        )

        XCTAssertEqual(attachments.map(\.filename), ["image-1.png", "image-2.png", "images.zip"])
        XCTAssertEqual(attachments.map(\.mimeType), ["image/png", "image/png", "application/zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.attachmentType == .screenshot })
        XCTAssertTrue(attachments.allSatisfy(\.required))
        XCTAssertTrue(attachments.allSatisfy { FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent($0.relativePath).path) })
    }

    func testPrepareImageAttachmentsLetsSplitZipUseReservedSlot() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let imagesDir = jobRoot.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let sources = try (1...5).map { index in
            let filename = "image-\(index).png"
            let fileURL = imagesDir.appendingPathComponent(filename)
            let data: Data
            if index <= 2 {
                data = Data(filename.utf8)
            } else {
                data = try randomData(byteCount: 8 * 1024 * 1024)
            }
            try data.write(to: fileURL)
            return FeedbackOutboxSourceAttachment(
                relativePath: "images/\(filename)",
                filename: filename,
                mimeType: "image/png",
                size: Int64(data.count)
            )
        }

        let attachments = try FeedbackOutbox.prepareImageAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            sources: sources,
            preferredSlots: 3,
            maxSlots: 4
        )

        XCTAssertEqual(attachments.map(\.filename), ["image-1.png", "image-2.png", "images-1.zip", "images-2.zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.attachmentType == .screenshot })
        XCTAssertTrue(attachments.allSatisfy(\.required))
        XCTAssertTrue(attachments.allSatisfy { $0.size <= FeedbackOutbox.maxAttachmentBytes })
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("images.zip").path))
    }

    func testPrepareUserFileAttachmentsUsesOthersZip() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let filesDir = jobRoot.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let firstURL = filesDir.appendingPathComponent("first.bin")
        FileManager.default.createFile(atPath: firstURL.path, contents: nil)
        let firstHandle = try FileHandle(forWritingTo: firstURL)
        try firstHandle.truncate(atOffset: UInt64(FeedbackOutbox.zipPlanningBytes))
        try firstHandle.close()

        let secondURL = filesDir.appendingPathComponent("second.bin")
        try Data("x".utf8).write(to: secondURL)

        let sources = [
            FeedbackOutboxSourceAttachment(
                relativePath: "files/first.bin",
                filename: "first.bin",
                mimeType: "application/octet-stream",
                size: FeedbackOutbox.zipPlanningBytes
            ),
            FeedbackOutboxSourceAttachment(
                relativePath: "files/second.bin",
                filename: "second.bin",
                mimeType: "application/octet-stream",
                size: 1
            )
        ]

        let attachments = try FeedbackOutbox.prepareUserFileAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            sources: sources,
            availableSlots: 1
        )

        XCTAssertEqual(attachments.map(\.filename), ["others.zip"])
        XCTAssertEqual(attachments[0].attachmentType, .other)
        XCTAssertFalse(attachments[0].required)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("feedback-files-1.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("feedback-files-2.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent(attachments[0].relativePath).path))
    }

    func testAttachmentsWithinSubmitLimitTrimsOptionalAttachments() throws {
        let required = (0..<4).map { index in
            uploadAttachment(filename: "required-\(index).zip", required: true)
        }
        let optional = (0..<3).map { index in
            uploadAttachment(filename: "optional-\(index).zip", required: false)
        }

        let attachments = try FeedbackOutbox.attachmentsWithinSubmitLimit(required: required, optional: optional)

        XCTAssertEqual(attachments.count, FeedbackOutbox.maxSubmitAttachments)
        XCTAssertEqual(attachments.map(\.filename), [
            "required-0.zip",
            "required-1.zip",
            "required-2.zip",
            "required-3.zip",
            "optional-0.zip"
        ])
    }

    func testOptionalZipOverLimitIsSkippedAfterActualZipSizeCheck() throws {
        let preparedDir = try makePreparedDirectory()
        let data = try randomData(byteCount: Int(FeedbackOutbox.maxAttachmentBytes + 1024 * 1024))
        let item = ArchiveItem(
            sourceURL: nil,
            inlineData: data,
            offset: 0,
            length: UInt64(data.count),
            archivePath: "large-random.bin"
        )

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: [item],
            preparedDir: preparedDir,
            singleFilename: nil,
            numberedPrefix: "feedback-files",
            attachmentType: .other,
            required: false
        )

        XCTAssertTrue(attachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("feedback-files-1.zip").path))
    }

    func testRequiredZipOverLimitIsSkippedAfterActualZipSizeCheck() throws {
        let preparedDir = try makePreparedDirectory()
        let data = try randomData(byteCount: Int(FeedbackOutbox.maxAttachmentBytes + 1024 * 1024))
        let item = ArchiveItem(
            sourceURL: nil,
            inlineData: data,
            offset: 0,
            length: UInt64(data.count),
            archivePath: "large-random.bin"
        )

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: [item],
            preparedDir: preparedDir,
            singleFilename: nil,
            numberedPrefix: "required-files",
            attachmentType: .screenshot,
            required: true
        )

        XCTAssertTrue(attachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("required-files-1.zip").path))
    }

    private func makeJobDirectory() throws -> URL {
        let jobRoot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        return jobRoot
    }

    private func makePreparedDirectory(in parent: URL? = nil) throws -> URL {
        let preparedDir = (parent ?? root).appendingPathComponent("prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: preparedDir, withIntermediateDirectories: true)
        return preparedDir
    }

    private func uploadAttachment(filename: String, required: Bool) -> FeedbackOutboxUploadAttachment {
        FeedbackOutboxUploadAttachment(
            id: UUID().uuidString,
            relativePath: "prepared/\(filename)",
            filename: filename,
            mimeType: "application/zip",
            size: 1,
            attachmentType: required ? .log : .other,
            required: required,
            status: .queued,
            retryCount: 0,
            objectKey: nil
        )
    }

    private func archiveItem(path: String, plannedBytes: UInt64) -> ArchiveItem {
        ArchiveItem(
            sourceURL: nil,
            inlineData: Data("x".utf8),
            offset: 0,
            length: plannedBytes,
            archivePath: path
        )
    }

    private func archiveItem(path: String, inlineText: String) -> ArchiveItem {
        let data = Data(inlineText.utf8)
        return ArchiveItem(
            sourceURL: nil,
            inlineData: data,
            offset: 0,
            length: UInt64(data.count),
            archivePath: path
        )
    }

    private func zipEntryText(_ entry: String, in zipURL: URL) throws -> String {
        let output = Pipe()
        let errorOutput = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipURL.path, entry]
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "FeedbackOutboxArchiveTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func zipEntryExists(_ entry: String, in zipURL: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipURL.path, entry]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @discardableResult
    private func writeLog(_ text: String, named filename: String, in directory: URL, modifiedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private func randomData(byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "FeedbackOutboxArchiveTests", code: Int(status))
        }
        return data
    }
}
