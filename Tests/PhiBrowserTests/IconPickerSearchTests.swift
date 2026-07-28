// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class IconPickerSearchTests: XCTestCase {
    func testPhiIconSearchMatchesNamesCaseInsensitivelyAndIgnoresSeparators() {
        XCTAssertEqual(
            IconPickerSearch.phiIcons(matching: "MAIL").map(\.name),
            ["mail"]
        )
        XCTAssertEqual(
            IconPickerSearch.phiIcons(matching: "color swatch").map(\.name),
            ["color-swatch"]
        )
        XCTAssertEqual(
            IconPickerSearch.phiIcons(matching: "  ").count,
            PhiIconCatalog.all.count
        )
    }

    func testEmojiSearchMatchesNamesSubgroupsGroupsAndSkinVariants() {
        let catalog = EmojiCatalog(
            version: "test",
            date: "2026-07-16",
            source: "unit-test",
            groups: [
                EmojiCatalog.Group(
                    name: "Smileys & Emotion",
                    items: [
                        EmojiItem(
                            id: "1F600",
                            text: "😀",
                            name: "grinning face",
                            subgroup: "face-smiling",
                            skinVariants: []
                        )
                    ]
                ),
                EmojiCatalog.Group(
                    name: "People & Body",
                    items: [
                        EmojiItem(
                            id: "1F44B",
                            text: "👋",
                            name: "waving hand",
                            subgroup: "hand-fingers-open",
                            skinVariants: [
                                EmojiVariant(
                                    id: "1F44B-1F3FD",
                                    text: "👋🏽",
                                    name: "waving hand: medium skin tone"
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(
            IconPickerSearch.emojiItems(in: catalog, matching: "face smiling").map(\.id),
            ["1F600"]
        )
        XCTAssertEqual(
            IconPickerSearch.emojiItems(in: catalog, matching: "medium skin").map(\.id),
            ["1F44B"]
        )
        XCTAssertEqual(
            IconPickerSearch.emojiGroups(in: catalog, matching: "people").map(\.name),
            ["People & Body"]
        )
    }
}

final class EmojiGridLayoutTests: XCTestCase {
    func testGroupedLayoutBuildsStableRowsAndMapsSkinVariants() {
        let variant = EmojiVariant(
            id: "emoji-2-variant",
            text: "variant",
            name: "variant"
        )
        let items = [
            makeItem(id: "emoji-1"),
            makeItem(id: "emoji-2", skinVariants: [variant]),
            makeItem(id: "emoji-3"),
            makeItem(id: "emoji-4"),
            makeItem(id: "emoji-5")
        ]
        let layout = EmojiGridLayout(
            groups: [EmojiCatalog.Group(name: "People", items: items)],
            showsGroups: true,
            columnCount: 2
        )

        XCTAssertEqual(
            layout.rows.map(\.id),
            [
                .header(groupID: "People"),
                .items(groupID: "People", firstItemID: "emoji-1"),
                .items(groupID: "People", firstItemID: "emoji-3"),
                .items(groupID: "People", firstItemID: "emoji-5")
            ]
        )
        XCTAssertEqual(
            layout.rowID(for: "emoji-2"),
            layout.rowID(for: "emoji-2-variant")
        )
    }

    func testUngroupedLayoutFlattensGroupsWithoutHeaderRows() {
        let layout = EmojiGridLayout(
            groups: [
                EmojiCatalog.Group(
                    name: "First",
                    items: [makeItem(id: "emoji-1"), makeItem(id: "emoji-2")]
                ),
                EmojiCatalog.Group(
                    name: "Second",
                    items: [makeItem(id: "emoji-3")]
                )
            ],
            showsGroups: false,
            columnCount: 2
        )

        XCTAssertEqual(
            layout.rows.map(\.id),
            [
                .items(groupID: nil, firstItemID: "emoji-1"),
                .items(groupID: nil, firstItemID: "emoji-3")
            ]
        )
    }

    private func makeItem(id: String,
                          skinVariants: [EmojiVariant] = []) -> EmojiItem {
        EmojiItem(
            id: id,
            text: id,
            name: id,
            subgroup: "test",
            skinVariants: skinVariants
        )
    }
}
