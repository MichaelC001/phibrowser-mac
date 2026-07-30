// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AppLanguagePreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        let suiteName = "AppLanguagePreferenceTests.\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        super.tearDown()
    }

    func testFreshInstallFollowsSystem() {
        XCTAssertEqual(
            PhiPreferences.GeneralSettings.loadAppLanguagePreference(from: defaults),
            .system
        )
    }

    func testUnknownStoredLanguageFallsBackToSystem() {
        defaults.set(
            "unsupported-language",
            forKey: PhiPreferences.GeneralSettings.appLanguagePreferenceKey
        )

        XCTAssertEqual(
            PhiPreferences.GeneralSettings.loadAppLanguagePreference(from: defaults),
            .system
        )
    }

    func testSaveRoundTripsEverySupportedLanguage() {
        for language in SupportedAppLanguage.allCases {
            let preference = AppLanguagePreference.language(language)
            PhiPreferences.GeneralSettings.saveAppLanguagePreference(
                preference,
                to: defaults,
                applicationDomainName: defaultsSuiteName
            )

            XCTAssertEqual(
                PhiPreferences.GeneralSettings.loadAppLanguagePreference(from: defaults),
                preference
            )
            XCTAssertEqual(
                persistentAppleLanguages,
                [language.bundleLocalizationIdentifier]
            )
        }
    }

    func testSupportedLanguagesUseExpectedBundleLocalizations() {
        let expectedIdentifiers: [SupportedAppLanguage: String] = [
            .english: "en",
            .simplifiedChinese: "zh_CN",
            .traditionalChinese: "zh_TW",
            .japanese: "ja",
            .french: "fr",
            .german: "de",
            .dutch: "nl",
            .spanish: "es",
        ]

        XCTAssertEqual(SupportedAppLanguage.allCases.count, expectedIdentifiers.count)
        for language in SupportedAppLanguage.allCases {
            XCTAssertEqual(
                language.bundleLocalizationIdentifier,
                expectedIdentifiers[language]
            )
        }
    }

    func testExplicitLanguagePreservesAndRestoresSystemPerAppLanguage() {
        defaults.set(["fr"], forKey: "AppleLanguages")

        XCTAssertTrue(
            PhiPreferences.GeneralSettings.saveAppLanguagePreference(
                .language(.simplifiedChinese),
                to: defaults,
                applicationDomainName: defaultsSuiteName
            )
        )
        XCTAssertEqual(persistentAppleLanguages, ["zh_CN"])

        XCTAssertTrue(
            PhiPreferences.GeneralSettings.saveAppLanguagePreference(
                .system,
                to: defaults,
                applicationDomainName: defaultsSuiteName
            )
        )
        XCTAssertEqual(persistentAppleLanguages, ["fr"])
        XCTAssertEqual(
            PhiPreferences.GeneralSettings.loadAppLanguagePreference(from: defaults),
            .system
        )
    }

    func testSystemPreferenceRestoresAbsenceOfPerAppLanguage() {
        PhiPreferences.GeneralSettings.saveAppLanguagePreference(
            .language(.english),
            to: defaults,
            applicationDomainName: defaultsSuiteName
        )
        XCTAssertEqual(persistentAppleLanguages, ["en"])

        PhiPreferences.GeneralSettings.saveAppLanguagePreference(
            .system,
            to: defaults,
            applicationDomainName: defaultsSuiteName
        )
        XCTAssertNil(persistentAppleLanguages)
    }

    func testExistingExplicitPreferenceRepairsMissingAppleLanguages() {
        defaults.set(
            SupportedAppLanguage.simplifiedChinese.rawValue,
            forKey: PhiPreferences.GeneralSettings.appLanguagePreferenceKey
        )

        XCTAssertTrue(
            PhiPreferences.GeneralSettings.saveAppLanguagePreference(
                .language(.simplifiedChinese),
                to: defaults,
                applicationDomainName: defaultsSuiteName
            )
        )
        XCTAssertEqual(persistentAppleLanguages, ["zh_CN"])
    }

    func testSavingConfiguredExplicitPreferenceReportsNoChange() {
        let preference = AppLanguagePreference.language(.simplifiedChinese)
        PhiPreferences.GeneralSettings.saveAppLanguagePreference(
            preference,
            to: defaults,
            applicationDomainName: defaultsSuiteName
        )

        XCTAssertFalse(
            PhiPreferences.GeneralSettings.saveAppLanguagePreference(
                preference,
                to: defaults,
                applicationDomainName: defaultsSuiteName
            )
        )
    }

    private var persistentAppleLanguages: [String]? {
        defaults.persistentDomain(forName: defaultsSuiteName)?["AppleLanguages"] as? [String]
    }
}
