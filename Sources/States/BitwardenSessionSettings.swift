// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// When the unlocked Bitwarden session ends. `rawValue` is the wire string the
/// helper parses (`BitwardenService` forwards it verbatim), so do not rename.
enum BitwardenSessionTimeout: String, CaseIterable, Identifiable {
    case oneHour
    case fourHours
    case onSystemLock
    case onBrowserRestart
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneHour: return NSLocalizedString("settings.developer.passwordManager.session.duration.oneHour", value: "1 hour", comment: "Bitwarden session timeout - 1 hour")
        case .fourHours: return NSLocalizedString("settings.developer.passwordManager.session.duration.fourHours", value: "4 hours", comment: "Bitwarden session timeout - 4 hours")
        case .onSystemLock: return NSLocalizedString("settings.developer.passwordManager.session.duration.untilSystemLock", value: "On system lock", comment: "Bitwarden session timeout - on system lock")
        case .onBrowserRestart: return NSLocalizedString("settings.developer.passwordManager.session.duration.untilBrowserRestart", value: "On browser restart", comment: "Bitwarden session timeout - on browser restart")
        case .never: return NSLocalizedString("settings.developer.passwordManager.session.duration.never", value: "Never", comment: "Bitwarden session timeout - never")
        }
    }

    static let storageKey = "bitwarden.sessionTimeout"
    static let defaultValue: BitwardenSessionTimeout = .onBrowserRestart

    static var current: BitwardenSessionTimeout {
        UserDefaults.standard.string(forKey: storageKey).flatMap(BitwardenSessionTimeout.init) ?? defaultValue
    }
}

/// What ending the session does.
enum BitwardenTimeoutAction: String, CaseIterable, Identifiable {
    case lock
    case logOut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lock: return NSLocalizedString("settings.developer.passwordManager.session.timeoutAction.lock", value: "Lock", comment: "Bitwarden timeout action - lock")
        case .logOut: return NSLocalizedString("settings.developer.passwordManager.session.timeoutAction.logout", value: "Log out", comment: "Bitwarden timeout action - log out")
        }
    }

    static let storageKey = "bitwarden.timeoutAction"
    static let defaultValue: BitwardenTimeoutAction = .lock

    static var current: BitwardenTimeoutAction {
        UserDefaults.standard.string(forKey: storageKey).flatMap(BitwardenTimeoutAction.init) ?? defaultValue
    }
}
