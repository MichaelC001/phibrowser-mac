// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

private enum PinnedTabSnapshotTestSection: Hashable {
    case tabs
}

@MainActor
final class PinnedTabSnapshotIdentityTests: XCTestCase {
    func testSnapshotItemKeepsCapturedIdentityWhenDatabaseGuidIsRebound() {
        let tab = Tab(
            url: "https://example.com",
            isActive: false,
            index: 0,
            customGuid: "profile-guid"
        )
        let profileItem = PinnedTabViewController.PinnedTabSnapshotItem(tab: tab)
        let identifiers = Set([profileItem])

        tab.guidInLocalDB = "app-guid"

        XCTAssertEqual(profileItem.identifier, "profile-guid")
        XCTAssertTrue(identifiers.contains(profileItem))
        XCTAssertTrue(profileItem.tab === tab)

        let appItem = PinnedTabViewController.PinnedTabSnapshotItem(tab: tab)
        XCTAssertEqual(appItem.identifier, "app-guid")
        XCTAssertNotEqual(profileItem, appItem)
    }

    func testDiffableSnapshotAppliesReboundTabsInReversedOrder() {
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        collectionView.collectionViewLayout = NSCollectionViewFlowLayout()
        let dataSource = NSCollectionViewDiffableDataSource<
            PinnedTabSnapshotTestSection,
            PinnedTabViewController.PinnedTabSnapshotItem
        >(collectionView: collectionView) { _, _, _ in
            NSCollectionViewItem()
        }

        let firstTab = makeTab(guid: "profile-a", index: 0)
        let secondTab = makeTab(guid: "profile-b", index: 1)
        var initialSnapshot = NSDiffableDataSourceSnapshot<
            PinnedTabSnapshotTestSection,
            PinnedTabViewController.PinnedTabSnapshotItem
        >()
        initialSnapshot.appendSections([.tabs])
        initialSnapshot.appendItems([
            PinnedTabViewController.PinnedTabSnapshotItem(tab: firstTab),
            PinnedTabViewController.PinnedTabSnapshotItem(tab: secondTab),
        ])
        dataSource.apply(initialSnapshot, animatingDifferences: false)

        firstTab.guidInLocalDB = "app-a"
        secondTab.guidInLocalDB = "app-b"
        var appSnapshot = NSDiffableDataSourceSnapshot<
            PinnedTabSnapshotTestSection,
            PinnedTabViewController.PinnedTabSnapshotItem
        >()
        appSnapshot.appendSections([.tabs])
        appSnapshot.appendItems([
            PinnedTabViewController.PinnedTabSnapshotItem(tab: secondTab),
            PinnedTabViewController.PinnedTabSnapshotItem(tab: firstTab),
        ])
        dataSource.apply(appSnapshot, animatingDifferences: true)

        XCTAssertEqual(
            dataSource.snapshot().itemIdentifiers.map(\.identifier),
            ["app-b", "app-a"]
        )
    }

    private func makeTab(guid: String, index: Int) -> Tab {
        Tab(
            url: "https://example.com/\(index)",
            isActive: false,
            index: index,
            customGuid: guid
        )
    }
}
