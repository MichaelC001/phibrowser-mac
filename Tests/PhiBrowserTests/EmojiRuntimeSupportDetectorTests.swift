// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class EmojiRuntimeSupportDetectorTests: XCTestCase {
    private let detector = EmojiRuntimeSupportDetector()

    func testSupportsKnownSingleCellEmoji() {
        XCTAssertTrue(detector.supportsEmoji("😀"))
        XCTAssertTrue(detector.supportsEmoji("👩‍💻"))
        XCTAssertTrue(detector.supportsEmoji("👩‍❤️‍💋‍👨"))
        XCTAssertTrue(detector.supportsEmoji("🇺🇸"))
        XCTAssertTrue(detector.supportsEmoji("🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"))
    }

    func testRejectsFallbackAndDecomposedEmoji() {
        XCTAssertFalse(detector.supportsEmoji("\u{10FFFD}"))
        XCTAssertFalse(detector.supportsEmoji("😀‍😀"))
        XCTAssertFalse(detector.supportsEmoji("🇦🇦"))
        XCTAssertFalse(detector.supportsEmoji("🇹🇼"))
        XCTAssertFalse(detector.supportsEmoji("🏴\u{E0061}\u{E0061}\u{E007F}"))
    }

    func testSelectionRestoresEmojiFromInjectedCatalog() {
        let catalog = EmojiCatalog(
            version: "test",
            date: "2026-06-29",
            source: "unit-test",
            groups: [
                EmojiCatalog.Group(
                    name: "Smileys",
                    items: [
                        EmojiItem(
                            id: "1F600",
                            text: "😀",
                            name: "grinning face",
                            subgroup: "face-smiling",
                            skinVariants: []
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(
            IconPickerSelection.fromStorageValue("emoji:1F600", emojiCatalog: catalog),
            .emoji(id: "1F600", text: "😀")
        )
        XCTAssertNil(
            IconPickerSelection.fromStorageValue("emoji:1F601", emojiCatalog: catalog)
        )
        XCTAssertEqual(
            IconPickerSelection.fromStorageValue("phi:phi-icon-1", emojiCatalog: catalog),
            .phiIcon(id: "phi-icon-rss")
        )
    }
}
