// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Languages whose native Phi UI is ready to be selected explicitly.
/// Keep this list aligned with the localizations shipped in Localizable.xcstrings.
enum SupportedAppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case french = "fr"
    case german = "de"
    case dutch = "nl"
    case spanish = "es"

    var id: String { rawValue }

    /// The localization identifier emitted into the outer app bundle.
    ///
    /// Chromium's macOS resource bundles retain legacy region-based Chinese
    /// identifiers, while Apple language preferences use script identifiers.
    var bundleLocalizationIdentifier: String {
        switch self {
        case .simplifiedChinese:
            return "zh_CN"
        case .traditionalChinese:
            return "zh_TW"
        default:
            return rawValue
        }
    }

    /// Uses each language's own locale so the picker shows stable autonyms.
    var displayName: String {
        Locale(identifier: rawValue).localizedString(forIdentifier: rawValue) ?? rawValue
    }
}

/// The app-level selection is separate from the supported language list because
/// following macOS is a preference mode, not a localization shipped by Phi.
enum AppLanguagePreference: Hashable, Identifiable {
    case system
    case language(SupportedAppLanguage)

    static let systemStorageValue = "system"

    init(storageValue: String?) {
        guard let storageValue,
              storageValue != Self.systemStorageValue,
              let language = SupportedAppLanguage(rawValue: storageValue) else {
            self = .system
            return
        }
        self = .language(language)
    }

    var id: String { storageValue }

    var storageValue: String {
        switch self {
        case .system:
            return Self.systemStorageValue
        case .language(let language):
            return language.rawValue
        }
    }
}

extension PhiPreferences.GeneralSettings {
    static let appLanguagePreferenceKey = "appLanguagePreference"
    private static let appleLanguagesKey = "AppleLanguages"
    private static let systemAppleLanguagesBackupKey = "systemAppleLanguagesBeforePhiOverride"
    private static let hasSystemAppleLanguagesBackupKey = "hasSystemAppleLanguagesBeforePhiOverride"

    static func loadAppLanguagePreference(
        from defaults: UserDefaults = .standard
    ) -> AppLanguagePreference {
        AppLanguagePreference(
            storageValue: defaults.string(forKey: Self.appLanguagePreferenceKey)
        )
    }

    /// The preference applied to the current process. This snapshot remains
    /// unchanged until Phi relaunches, even if the settings view is recreated.
    static let appLanguagePreferenceAtLaunch = loadAppLanguagePreference()

    /// Persists the language before the app quits so Foundation can select
    /// the matching localization during the next process launch.
    ///
    /// The existing app-specific AppleLanguages value belongs to macOS
    /// System Settings, so preserve it while Phi's explicit override is
    /// active and restore it when the user returns to System Default.
    @discardableResult
    static func saveAppLanguagePreference(
        _ preference: AppLanguagePreference,
        to defaults: UserDefaults = .standard,
        applicationDomainName: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        let previousPreference = loadAppLanguagePreference(from: defaults)
        var didChange = previousPreference != preference

        switch preference {
        case .system:
            if defaults.bool(forKey: Self.hasSystemAppleLanguagesBackupKey) {
                let backup = defaults.stringArray(
                    forKey: Self.systemAppleLanguagesBackupKey
                )
                if persistentAppleLanguages(
                    from: defaults,
                    applicationDomainName: applicationDomainName
                ) != backup {
                    if let backup {
                        defaults.set(backup, forKey: Self.appleLanguagesKey)
                    } else {
                        defaults.removeObject(forKey: Self.appleLanguagesKey)
                    }
                    didChange = true
                }
                defaults.removeObject(forKey: Self.systemAppleLanguagesBackupKey)
                defaults.removeObject(forKey: Self.hasSystemAppleLanguagesBackupKey)
            }

        case .language(let language):
            if !defaults.bool(forKey: Self.hasSystemAppleLanguagesBackupKey) {
                if let systemAppleLanguages = persistentAppleLanguages(
                    from: defaults,
                    applicationDomainName: applicationDomainName
                ) {
                    defaults.set(
                        systemAppleLanguages,
                        forKey: Self.systemAppleLanguagesBackupKey
                    )
                } else {
                    defaults.removeObject(forKey: Self.systemAppleLanguagesBackupKey)
                }
                defaults.set(true, forKey: Self.hasSystemAppleLanguagesBackupKey)
                didChange = true
            }

            let explicitAppleLanguages = [language.bundleLocalizationIdentifier]
            if persistentAppleLanguages(
                from: defaults,
                applicationDomainName: applicationDomainName
            ) != explicitAppleLanguages {
                defaults.set(explicitAppleLanguages, forKey: Self.appleLanguagesKey)
                didChange = true
            }
        }

        if previousPreference != preference {
            defaults.set(preference.storageValue, forKey: Self.appLanguagePreferenceKey)
        }
        return didChange
    }

    private static func persistentAppleLanguages(
        from defaults: UserDefaults,
        applicationDomainName: String?
    ) -> [String]? {
        guard let applicationDomainName else { return nil }
        return defaults.persistentDomain(forName: applicationDomainName)?[
            Self.appleLanguagesKey
        ] as? [String]
    }
}
