// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelLanguagePreferenceSyncTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testSharedPreferenceUsesCanonicalLanguageIdentifiers() {
        let preference = SharedAppLanguagePreference(
            preference: .language(.simplifiedChinese),
            resolvedLanguage: .simplifiedChinese
        )

        XCTAssertEqual(preference.schemaVersion, 1)
        XCTAssertEqual(preference.selection, "zh-Hans")
        XCTAssertEqual(preference.resolvedLanguage, "zh-Hans")
        XCTAssertEqual(preference.userInfo["Selection"] as? String, "zh-Hans")
        XCTAssertEqual(
            preference.userInfo["ResolvedLanguage"] as? String,
            "zh-Hans"
        )
    }

    func testStoreWritesAndReadsPropertyList() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("language.plist")
        let store = SharedAppLanguagePreferenceStore(fileURL: fileURL)
        let preference = SharedAppLanguagePreference(
            preference: .system,
            resolvedLanguage: .traditionalChinese
        )

        try store.write(preference)

        XCTAssertEqual(try store.read(), preference)

        let data = try Data(contentsOf: fileURL)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(propertyList["SchemaVersion"] as? Int, 1)
        XCTAssertEqual(propertyList["Selection"] as? String, "system")
        XCTAssertEqual(
            propertyList["ResolvedLanguage"] as? String,
            "zh-Hant"
        )
    }

    func testTerminationSyncUpdatesSnapshotWhenResolvedLanguageChanges() throws {
        let defaultsSuiteName = "SentinelLanguagePreferenceSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        defaults.set(
            AppLanguagePreference.systemStorageValue,
            forKey: PhiPreferences.GeneralSettings.appLanguagePreferenceKey
        )
        defaults.set(["fr"], forKey: "AppleLanguages")

        let store = SharedAppLanguagePreferenceStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("language.plist")
        )
        try store.write(
            SharedAppLanguagePreference(
                preference: .system,
                resolvedLanguage: .english
            )
        )

        XCTAssertEqual(
            SentinelLanguagePreferenceSync.synchronizeCurrentPreferenceBeforeTermination(
                store: store,
                defaults: defaults,
                applicationDomainName: defaultsSuiteName,
                systemPreferredLanguages: ["en"]
            ),
            .languageChanged
        )
        XCTAssertEqual(
            try store.read(),
            SharedAppLanguagePreference(
                preference: .system,
                resolvedLanguage: .french
            )
        )
    }

    func testTerminationSyncDoesNotRestartSentinelForSelectionOnlyChange() throws {
        let defaultsSuiteName = "SentinelLanguagePreferenceSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        defaults.set(
            SupportedAppLanguage.french.rawValue,
            forKey: PhiPreferences.GeneralSettings.appLanguagePreferenceKey
        )

        let store = SharedAppLanguagePreferenceStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("language.plist")
        )
        try store.write(
            SharedAppLanguagePreference(
                preference: .system,
                resolvedLanguage: .french
            )
        )

        XCTAssertEqual(
            SentinelLanguagePreferenceSync.synchronizeCurrentPreferenceBeforeTermination(
                store: store,
                defaults: defaults,
                applicationDomainName: defaultsSuiteName,
                systemPreferredLanguages: ["en"]
            ),
            .metadataChanged
        )
        XCTAssertEqual(
            try store.read(),
            SharedAppLanguagePreference(
                preference: .language(.french),
                resolvedLanguage: .french
            )
        )
    }

    func testTerminationSyncReportsUnchangedForMatchingSnapshot() throws {
        let defaultsSuiteName = "SentinelLanguagePreferenceSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        defaults.set(
            SupportedAppLanguage.french.rawValue,
            forKey: PhiPreferences.GeneralSettings.appLanguagePreferenceKey
        )

        let preference = SharedAppLanguagePreference(
            preference: .language(.french),
            resolvedLanguage: .french
        )
        let store = SharedAppLanguagePreferenceStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("language.plist")
        )
        try store.write(preference)

        XCTAssertEqual(
            SentinelLanguagePreferenceSync.synchronizeCurrentPreferenceBeforeTermination(
                store: store,
                defaults: defaults,
                applicationDomainName: defaultsSuiteName,
                systemPreferredLanguages: ["en"]
            ),
            .unchanged
        )
        XCTAssertEqual(try store.read(), preference)
    }

    func testTerminationSyncFailsClosedForCorruptSnapshot() throws {
        let defaultsSuiteName = "SentinelLanguagePreferenceSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let fileURL = temporaryDirectoryURL.appendingPathComponent("language.plist")
        try Data("not a property list".utf8).write(to: fileURL)
        let store = SharedAppLanguagePreferenceStore(fileURL: fileURL)

        XCTAssertEqual(
            SentinelLanguagePreferenceSync.synchronizeCurrentPreferenceBeforeTermination(
                store: store,
                defaults: defaults,
                applicationDomainName: defaultsSuiteName,
                systemPreferredLanguages: ["en"]
            ),
            .failed
        )
    }

    @MainActor
    func testTerminationCoordinatorStopsWatchdogBeforeTerminatingSentinel() {
        var events: [String] = []

        XCTAssertEqual(
            SentinelLanguagePreferenceTerminationCoordinator.prepareForPhiTermination(
                synchronizePreference: {
                    events.append("synchronize")
                    return .languageChanged
                },
                stopSentinelWatchdog: {
                    events.append("stopWatchdog")
                },
                terminateSentinel: {
                    events.append("terminateSentinel")
                }
            ),
            .languageChanged
        )
        XCTAssertEqual(
            events,
            ["synchronize", "stopWatchdog", "terminateSentinel"]
        )
    }

    @MainActor
    func testTerminationCoordinatorDoesNotStopSentinelForOtherResults() {
        let results: [SentinelLanguagePreferenceSync.TerminationSyncResult] = [
            .unchanged,
            .metadataChanged,
            .failed,
        ]

        for result in results {
            var didStopWatchdog = false
            var didTerminateSentinel = false

            XCTAssertEqual(
                SentinelLanguagePreferenceTerminationCoordinator.prepareForPhiTermination(
                    synchronizePreference: { result },
                    stopSentinelWatchdog: {
                        didStopWatchdog = true
                    },
                    terminateSentinel: {
                        didTerminateSentinel = true
                    }
                ),
                result
            )
            XCTAssertFalse(didStopWatchdog)
            XCTAssertFalse(didTerminateSentinel)
        }
    }

    func testChannelSeparatesCanaryAndRelease() {
        let canary = SentinelLanguagePreferenceChannel.make(
            browserBundleIdentifier: "com.phibrowser.canary.Mac"
        )
        XCTAssertEqual(
            canary.filename,
            "app-language-preference-canary.plist"
        )
        XCTAssertEqual(
            canary.notificationName.rawValue,
            "com.phibrowser.canary.appLanguagePreferenceDidChange"
        )

        let release = SentinelLanguagePreferenceChannel.make(
            browserBundleIdentifier: "com.phibrowser.Mac"
        )
        XCTAssertEqual(
            release.filename,
            "app-language-preference.plist"
        )
        XCTAssertEqual(
            release.notificationName.rawValue,
            "com.phibrowser.appLanguagePreferenceDidChange"
        )
    }
}
