// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

/// Identifies one bookmark collection without retaining its browser window.
///
/// Bookmarks are stored per account, profile, and Space. Keeping those values
/// together prevents a long-lived management view from silently following a
/// different key window, while still allowing a future scope picker to replace
/// the complete value explicitly.
struct BookmarkManagementScope: Hashable {
    let accountId: String
    let profileId: String
    let spaceId: String

    init(accountId: String, profileId: String, spaceId: String) {
        self.accountId = accountId
        self.profileId = profileId
        self.spaceId = spaceId
    }

    init(browserState: BrowserState) {
        self.init(
            accountId: browserState.localStore.account.userID,
            profileId: browserState.profileId,
            spaceId: browserState.spaceId
        )
    }
}
