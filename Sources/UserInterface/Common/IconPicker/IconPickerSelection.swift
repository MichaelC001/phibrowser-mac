// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum IconPickerSelection: Hashable, Identifiable {
    case phiIcon(id: String)
    case emoji(id: String, text: String)

    static let defaultPhiIconId = "phi-icon-rss"
    static let defaultSelection = IconPickerSelection.phiIcon(id: defaultPhiIconId)

    private static let phiIconPrefix = "phi:"
    private static let emojiPrefix = "emoji:"

    var id: String {
        storageValue
    }

    var storageValue: String {
        switch self {
        case .phiIcon(let id):
            return Self.phiIconPrefix + id
        case .emoji(let id, _):
            return Self.emojiPrefix + id
        }
    }

    var isEmoji: Bool {
        if case .emoji = self { return true }
        return false
    }

    static func fromStorageValue(_ value: String,
                                 emojiCatalog: EmojiCatalog? = nil) -> IconPickerSelection? {
        if value.hasPrefix(Self.phiIconPrefix) {
            let storedId = String(value.dropFirst(Self.phiIconPrefix.count))
            guard let canonicalId = PhiIconCatalog.canonicalId(for: storedId) else { return nil }
            return .phiIcon(id: canonicalId)
        }

        if value.hasPrefix(Self.emojiPrefix) {
            let id = String(value.dropFirst(Self.emojiPrefix.count))
            let catalog = emojiCatalog ?? .shared
            guard let text = catalog.text(for: id) else { return nil }
            return .emoji(id: id, text: text)
        }

        return nil
    }
}
