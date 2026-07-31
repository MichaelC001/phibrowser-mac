// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SentinelLanguagePreferenceChannel: Equatable {
    let filename: String
    let notificationName: Notification.Name

    static let current = make(
        browserBundleIdentifier: Bundle.main.bundleIdentifier
    )

    static func make(browserBundleIdentifier: String?) -> Self {
        if browserBundleIdentifier?.lowercased().contains("canary") == true {
            return Self(
                filename: "app-language-preference-canary.plist",
                notificationName: Notification.Name(
                    "com.phibrowser.canary.appLanguagePreferenceDidChange"
                )
            )
        }

        return Self(
            filename: "app-language-preference.plist",
            notificationName: Notification.Name(
                "com.phibrowser.appLanguagePreferenceDidChange"
            )
        )
    }
}

/// The language contract shared between Phi and Sentinel.
///
/// `selection` preserves whether the user follows macOS, while
/// `resolvedLanguage` gives Sentinel the canonical language to apply without
/// trying to resolve Phi's per-app language preference in Sentinel's process.
struct SharedAppLanguagePreference: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let selection: String
    let resolvedLanguage: String

    init(
        preference: AppLanguagePreference,
        resolvedLanguage: SupportedAppLanguage
    ) {
        schemaVersion = Self.currentSchemaVersion
        selection = preference.storageValue
        self.resolvedLanguage = resolvedLanguage.rawValue
    }

    var userInfo: [String: Any] {
        [
            CodingKeys.schemaVersion.rawValue: schemaVersion,
            CodingKeys.selection.rawValue: selection,
            CodingKeys.resolvedLanguage.rawValue: resolvedLanguage,
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "SchemaVersion"
        case selection = "Selection"
        case resolvedLanguage = "ResolvedLanguage"
    }
}

final class SharedAppLanguagePreferenceStore {
    static let appGroupIdentifier = "group.com.phibrowser.shared"

    static let shared = SharedAppLanguagePreferenceStore(fileURL: sharedFileURL)

    private static let sharedFileURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )?.appendingPathComponent(SentinelLanguagePreferenceChannel.current.filename)

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func write(_ preference: SharedAppLanguagePreference) throws {
        guard let fileURL else {
            throw SharedAppLanguagePreferenceStoreError.appGroupUnavailable
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(preference)
        try data.write(to: fileURL, options: .atomic)
    }

    func read() throws -> SharedAppLanguagePreference {
        guard let fileURL else {
            throw SharedAppLanguagePreferenceStoreError.appGroupUnavailable
        }

        let data = try Data(contentsOf: fileURL)
        return try PropertyListDecoder().decode(
            SharedAppLanguagePreference.self,
            from: data
        )
    }
}

private enum SharedAppLanguagePreferenceStoreError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "App Group '\(SharedAppLanguagePreferenceStore.appGroupIdentifier)' is unavailable"
    }
}

enum SentinelLanguagePreferenceSync {
    /// Keeps a durable snapshot for Sentinel without emitting a change event.
    /// This is used during Phi startup so Sentinel can recover missed events.
    static func persistCurrentPreference() {
        synchronize(
            PhiPreferences.GeneralSettings.loadAppLanguagePreference(),
            notifySentinel: false
        )
    }

    /// Writes the new value and notifies the matching Sentinel channel. The
    /// notification carries the same payload so either transport can recover
    /// independently if the other is unavailable.
    static func publish(_ preference: AppLanguagePreference) {
        synchronize(preference, notifySentinel: true)
    }

    private static func synchronize(
        _ preference: AppLanguagePreference,
        notifySentinel: Bool
    ) {
        let resolvedLanguage = PhiPreferences.GeneralSettings.resolvedAppLanguage(
            for: preference
        )
        let sharedPreference = SharedAppLanguagePreference(
            preference: preference,
            resolvedLanguage: resolvedLanguage
        )

        do {
            try SharedAppLanguagePreferenceStore.shared.write(sharedPreference)
        } catch {
            AppLogError(
                "Failed to persist shared app language preference: \(error.localizedDescription)"
            )
        }

        guard notifySentinel else { return }

        DistributedNotificationCenter.default().postNotificationName(
            SentinelLanguagePreferenceChannel.current.notificationName,
            object: nil,
            userInfo: sharedPreference.userInfo,
            deliverImmediately: true
        )
    }
}
