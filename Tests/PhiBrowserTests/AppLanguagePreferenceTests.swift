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
            .korean: "ko",
        ]

        XCTAssertEqual(SupportedAppLanguage.allCases.count, expectedIdentifiers.count)
        for language in SupportedAppLanguage.allCases {
            XCTAssertEqual(
                language.bundleLocalizationIdentifier,
                expectedIdentifiers[language]
            )
        }
    }

    func testLanguagePickerUsesFixedAlphabeticalOrder() {
        XCTAssertEqual(
            SupportedAppLanguage.pickerOrder,
            [
                .simplifiedChinese,
                .traditionalChinese,
                .dutch,
                .english,
                .french,
                .german,
                .japanese,
                .korean,
                .spanish,
            ]
        )
        XCTAssertEqual(
            Set(SupportedAppLanguage.pickerOrder),
            Set(SupportedAppLanguage.allCases)
        )
    }

    func testLanguagePickerTitleCasesFrenchAndSpanishAutonyms() {
        XCTAssertEqual(SupportedAppLanguage.french.displayName, "Français")
        XCTAssertEqual(SupportedAppLanguage.spanish.displayName, "Español")
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

    func testLaunchReconciliationPreservesLatestSystemPerAppLanguage() {
        defaults.set(["fr"], forKey: "AppleLanguages")
        PhiPreferences.GeneralSettings.saveAppLanguagePreference(
            .language(.simplifiedChinese),
            to: defaults,
            applicationDomainName: defaultsSuiteName
        )

        // Simulate macOS System Settings changing Phi's app-specific language
        // while Phi's explicit preference remains Simplified Chinese.
        defaults.set(["ja"], forKey: "AppleLanguages")

        XCTAssertTrue(
            PhiPreferences.GeneralSettings.reconcileAppLanguagePreferenceBeforeLaunch(
                from: defaults,
                applicationDomainName: defaultsSuiteName
            )
        )
        XCTAssertEqual(persistentAppleLanguages, ["zh_CN"])

        PhiPreferences.GeneralSettings.saveAppLanguagePreference(
            .system,
            to: defaults,
            applicationDomainName: defaultsSuiteName
        )
        XCTAssertEqual(persistentAppleLanguages, ["ja"])
    }

    func testSwitchingExplicitLanguagesKeepsSystemPerAppLanguageBackup() {
        defaults.set(["ja"], forKey: "AppleLanguages")
        PhiPreferences.GeneralSettings.saveAppLanguagePreference(
            .language(.simplifiedChinese),
            to: defaults,
            applicationDomainName: defaultsSuiteName
        )

        PhiPreferences.GeneralSettings.saveAppLanguagePreference(
            .language(.french),
            to: defaults,
            applicationDomainName: defaultsSuiteName
        )
        XCTAssertEqual(persistentAppleLanguages, ["fr"])

        PhiPreferences.GeneralSettings.saveAppLanguagePreference(
            .system,
            to: defaults,
            applicationDomainName: defaultsSuiteName
        )
        XCTAssertEqual(persistentAppleLanguages, ["ja"])
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

    func testExplicitPreferenceResolvesToCanonicalLanguage() {
        XCTAssertEqual(
            PhiPreferences.GeneralSettings.resolvedAppLanguage(
                for: .language(.simplifiedChinese),
                from: defaults,
                applicationDomainName: defaultsSuiteName,
                systemPreferredLanguages: ["fr"]
            ),
            .simplifiedChinese
        )
    }

    func testSystemPreferenceResolvesAppSpecificLanguage() {
        defaults.set(["zh-Hans"], forKey: "AppleLanguages")

        XCTAssertEqual(
            PhiPreferences.GeneralSettings.resolvedAppLanguage(
                for: .system,
                from: defaults,
                applicationDomainName: defaultsSuiteName,
                systemPreferredLanguages: ["fr"]
            ),
            .simplifiedChinese
        )
    }

    func testSystemPreferenceFallsBackToSupportedSystemLanguage() {
        XCTAssertEqual(
            PhiPreferences.GeneralSettings.resolvedAppLanguage(
                for: .system,
                from: defaults,
                applicationDomainName: defaultsSuiteName,
                systemPreferredLanguages: ["pt-BR", "es-MX"]
            ),
            .spanish
        )
    }

    func testActiveProcessLanguageUsesBundleLocalizationIdentifiers() {
        XCTAssertEqual(
            PhiPreferences.GeneralSettings.activeProcessAppLanguage(
                preferredLocalizations: ["zh_CN"]
            ),
            .simplifiedChinese
        )
        XCTAssertEqual(
            PhiPreferences.GeneralSettings.activeProcessAppLanguage(
                preferredLocalizations: ["es"]
            ),
            .spanish
        )
    }

    func testLanguageChangePropertiesContainOnlyFromAndTo() {
        let properties = AppLanguageAnalytics.changeProperties(
            from: .system,
            to: .language(.japanese)
        )

        XCTAssertEqual(properties, ["from": "system", "to": "ja"])
        XCTAssertNil(properties["source"])
    }

    private var persistentAppleLanguages: [String]? {
        defaults.persistentDomain(forName: defaultsSuiteName)?["AppleLanguages"] as? [String]
    }
}
