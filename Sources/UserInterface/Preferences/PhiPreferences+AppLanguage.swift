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
    case korean = "ko"

    /// Fixed alphabetical order by English language name for the language picker.
    static let pickerOrder: [SupportedAppLanguage] = [
        .simplifiedChinese,
        .traditionalChinese,
        .japanese,
        .korean,
        .english,
        .french,
        .german,
        .dutch,
        .spanish
    ]

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

    /// Uses each language's own locale so the picker shows stable autonyms,
    /// title-cased for the picker's menu context.
    var displayName: String {
        let locale = Locale(identifier: rawValue)
        let localizedName = locale.localizedString(forIdentifier: rawValue) ?? rawValue
        let firstWordEnd = localizedName.firstIndex(where: \.isWhitespace)
            ?? localizedName.endIndex
        let firstWord = String(localizedName[..<firstWordEnd]).capitalized(with: locale)

        return firstWord + String(localizedName[firstWordEnd...])
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

    /// Resolves the language Sentinel should apply. Explicit selections map
    /// directly, while System Default honors Phi's app-specific AppleLanguages
    /// value before falling back to the system language list.
    static func resolvedAppLanguage(
        for preference: AppLanguagePreference,
        from defaults: UserDefaults = .standard,
        applicationDomainName: String? = nil,
        systemPreferredLanguages: [String] = Locale.preferredLanguages
    ) -> SupportedAppLanguage {
        if case .language(let language) = preference {
            return language
        }

        let preferredLanguages = persistentAppleLanguages(
            from: defaults,
            applicationDomainName: applicationDomainName
        ) ?? systemPreferredLanguages
        let supportedLocalizations = SupportedAppLanguage.allCases.map(
            \.bundleLocalizationIdentifier
        )
        guard let resolvedLocalization = Bundle.preferredLocalizations(
            from: supportedLocalizations,
            forPreferences: preferredLanguages
        ).first else {
            return .english
        }

        return SupportedAppLanguage.allCases.first {
            $0.bundleLocalizationIdentifier == resolvedLocalization
        } ?? .english
    }

    /// The preference applied to the current process. This snapshot remains
    /// unchanged until Phi relaunches, even if the settings view is recreated.
    static let appLanguagePreferenceAtLaunch = loadAppLanguagePreference()

    static func activeProcessAppLanguage(
        preferredLocalizations: [String] = Bundle.main.preferredLocalizations
    ) -> SupportedAppLanguage {
        let supportedLocalizations = SupportedAppLanguage.allCases.map(
            \.bundleLocalizationIdentifier
        )
        let resolvedLocalization = Bundle.preferredLocalizations(
            from: supportedLocalizations,
            forPreferences: preferredLocalizations
        ).first
        return SupportedAppLanguage.allCases.first {
            $0.bundleLocalizationIdentifier == resolvedLocalization
        } ?? .english
    }

    /// Reasserts Phi's explicit language before Chromium or AppKit loads
    /// localized resources. macOS System Settings writes to the same
    /// `AppleLanguages` key, so an app-specific language change can otherwise
    /// replace Phi's explicit selection between launches.
    @discardableResult
    static func reconcileAppLanguagePreferenceBeforeLaunch(
        from defaults: UserDefaults = .standard,
        applicationDomainName: String? = nil
    ) -> Bool {
        saveAppLanguagePreference(
            loadAppLanguagePreference(from: defaults),
            to: defaults,
            applicationDomainName: applicationDomainName
        )
    }

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
        applicationDomainName: String? = nil
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
            let currentAppleLanguages = persistentAppleLanguages(
                from: defaults,
                applicationDomainName: applicationDomainName
            )
            let shouldCaptureSystemAppleLanguages: Bool
            switch previousPreference {
            case .system:
                shouldCaptureSystemAppleLanguages = true
            case .language(let previousLanguage):
                let previousExplicitAppleLanguages = [
                    previousLanguage.bundleLocalizationIdentifier,
                ]
                shouldCaptureSystemAppleLanguages =
                    !defaults.bool(forKey: Self.hasSystemAppleLanguagesBackupKey)
                    || currentAppleLanguages != previousExplicitAppleLanguages
            }

            if shouldCaptureSystemAppleLanguages {
                storeSystemAppleLanguagesBackup(
                    currentAppleLanguages,
                    in: defaults
                )
                didChange = true
            }

            let explicitAppleLanguages = [language.bundleLocalizationIdentifier]
            if currentAppleLanguages != explicitAppleLanguages {
                defaults.set(explicitAppleLanguages, forKey: Self.appleLanguagesKey)
                didChange = true
            }
        }

        if previousPreference != preference {
            defaults.set(preference.storageValue, forKey: Self.appLanguagePreferenceKey)
        }
        return didChange
    }

    private static func storeSystemAppleLanguagesBackup(
        _ languages: [String]?,
        in defaults: UserDefaults
    ) {
        if let languages {
            defaults.set(languages, forKey: Self.systemAppleLanguagesBackupKey)
        } else {
            defaults.removeObject(forKey: Self.systemAppleLanguagesBackupKey)
        }
        defaults.set(true, forKey: Self.hasSystemAppleLanguagesBackupKey)
    }

    private static func currentApplicationValue(forKey key: String) -> Any? {
        CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesCurrentApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    private static func persistentAppleLanguages(
        from defaults: UserDefaults,
        applicationDomainName: String?
    ) -> [String]? {
        guard let applicationDomainName else {
            return currentApplicationValue(forKey: Self.appleLanguagesKey) as? [String]
        }
        return defaults.persistentDomain(forName: applicationDomainName)?[
            Self.appleLanguagesKey
        ] as? [String]
    }
}

/// Objective-C entry point for the pre-Chromium launch sequence in `main.m`.
@objc(AppLanguageBootstrap)
final class AppLanguageBootstrap: NSObject {
    @objc static func reconcileBeforeBundleAccess() {
        PhiPreferences.GeneralSettings.reconcileAppLanguagePreferenceBeforeLaunch()
    }
}
