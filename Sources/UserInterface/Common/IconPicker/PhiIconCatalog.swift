// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum PhiIconCatalog {
    struct Icon: Hashable, Identifiable {
        /// The trailing component name from Figma, for example "mail" or "A".
        let name: String
        /// The image-set name used by the asset catalog.
        let assetName: String
        /// The numbered asset name stored by versions released before the
        /// semantic icon catalog.
        let legacyAssetName: String?

        var id: String {
            assetName
        }

        fileprivate init(_ name: String,
                         assetSlug: String? = nil,
                         legacyNumber: Int? = nil) {
            self.name = name
            assetName = "phi-icon-\(assetSlug ?? name)"
            legacyAssetName = legacyNumber.map { "phi-icon-\($0)" }
        }
    }

    /// Current Figma order. Legacy numbers are matched by icon shape rather
    /// than position because the semantic catalog uses a different order.
    static let all: [Icon] = [
        Icon("mail", legacyNumber: 47),
        Icon("color-swatch", legacyNumber: 46),
        Icon("camera", legacyNumber: 45),
        Icon("chat", legacyNumber: 44),
        Icon("bell", legacyNumber: 43),
        Icon("user", legacyNumber: 42),
        Icon("globe-alt", legacyNumber: 41),
        Icon("sun", legacyNumber: 40),
        Icon("sparkles", legacyNumber: 39),
        Icon("credit-card", legacyNumber: 38),
        Icon("ticket", legacyNumber: 37),
        Icon("moon", legacyNumber: 36),
        Icon("briefcase", legacyNumber: 35),
        Icon("archive", legacyNumber: 34),
        Icon("lock-closed", legacyNumber: 33),
        Icon("office-building", legacyNumber: 32),
        Icon("chart-pie", legacyNumber: 31),
        Icon("shield-exclamation", legacyNumber: 30),
        Icon("photograph", legacyNumber: 29),
        Icon("cog", legacyNumber: 28),
        Icon("filter", legacyNumber: 27),
        Icon("qrcode", legacyNumber: 26),
        Icon("clipboard-list", legacyNumber: 25),
        Icon("lightning-bolt", legacyNumber: 24),
        Icon("light-bulb", legacyNumber: 23),
        Icon("view-grid-add", legacyNumber: 22),
        Icon("md-library", legacyNumber: 21),
        Icon("play", legacyNumber: 20),
        Icon("presentation-chart-line", legacyNumber: 19),
        Icon("chip", legacyNumber: 18),
        Icon("cube-transparent", legacyNumber: 17),
        Icon("search-circle", legacyNumber: 16),
        Icon("cloud", legacyNumber: 15),
        Icon("academic-cap", legacyNumber: 14),
        Icon("gift", legacyNumber: 13),
        Icon("truck", legacyNumber: 12),
        Icon("cake", legacyNumber: 11),
        Icon("beaker", legacyNumber: 10),
        Icon("table", legacyNumber: 9),
        Icon("paper-airplane", legacyNumber: 8),
        Icon("device-mobile", legacyNumber: 7),
        Icon("music-note", legacyNumber: 6),
        Icon("film", legacyNumber: 5),
        Icon("database", legacyNumber: 4),
        Icon("server", legacyNumber: 3),
        Icon("identification", legacyNumber: 2),
        Icon("rss", legacyNumber: 1),
        Icon("map", legacyNumber: 48),
        Icon("1", assetSlug: "number-1"),
        Icon("2", assetSlug: "number-2"),
        Icon("3", assetSlug: "number-3"),
        Icon("4", assetSlug: "number-4"),
        Icon("5", assetSlug: "number-5"),
        Icon("6", assetSlug: "number-6"),
        Icon("7", assetSlug: "number-7"),
        Icon("8", assetSlug: "number-8"),
        Icon("9", assetSlug: "number-9"),
        Icon("0", assetSlug: "number-0"),
        Icon("A", assetSlug: "letter-a"),
        Icon("B", assetSlug: "letter-b"),
        Icon("C", assetSlug: "letter-c"),
        Icon("D", assetSlug: "letter-d"),
        Icon("E", assetSlug: "letter-e"),
        Icon("F", assetSlug: "letter-f"),
        Icon("G", assetSlug: "letter-g"),
        Icon("H", assetSlug: "letter-h"),
        Icon("I", assetSlug: "letter-i"),
        Icon("J", assetSlug: "letter-j"),
        Icon("K", assetSlug: "letter-k"),
        Icon("L", assetSlug: "letter-l"),
        Icon("M", assetSlug: "letter-m"),
        Icon("N", assetSlug: "letter-n"),
        Icon("O", assetSlug: "letter-o"),
        Icon("P", assetSlug: "letter-p"),
        Icon("Q", assetSlug: "letter-q"),
        Icon("R", assetSlug: "letter-r"),
        Icon("S", assetSlug: "letter-s"),
        Icon("T", assetSlug: "letter-t"),
        Icon("U", assetSlug: "letter-u"),
        Icon("V", assetSlug: "letter-v"),
        Icon("W", assetSlug: "letter-w"),
        Icon("X", assetSlug: "letter-x"),
        Icon("Y", assetSlug: "letter-y"),
        Icon("Z", assetSlug: "letter-z"),
        Icon("?", assetSlug: "question-mark"),
        Icon("!", assetSlug: "exclamation-mark"),
        Icon("~", assetSlug: "tilde"),
        Icon("`", assetSlug: "backtick")
    ]

    static let allIds: [String] = all.map(\.assetName)

    private static let iconsByName = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )
    private static let iconsByAssetName = Dictionary(
        uniqueKeysWithValues: all.map { ($0.assetName, $0) }
    )
    private static let canonicalIdByLegacyAssetName = Dictionary(
        uniqueKeysWithValues: all.compactMap { icon in
            icon.legacyAssetName.map { ($0, icon.assetName) }
        }
    )

    static func icon(named name: String) -> Icon? {
        iconsByName[name]
    }

    static func icon(forAssetName assetName: String) -> Icon? {
        guard let canonicalId = canonicalId(for: assetName) else { return nil }
        return iconsByAssetName[canonicalId]
    }

    static func canonicalId(for assetName: String) -> String? {
        if iconsByAssetName[assetName] != nil {
            return assetName
        }
        return canonicalIdByLegacyAssetName[assetName]
    }
}
