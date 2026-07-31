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
