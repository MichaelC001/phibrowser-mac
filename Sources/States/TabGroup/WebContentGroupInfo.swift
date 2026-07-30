// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine

/// Window-scoped, observable mirror of a single Chromium tab group.
///
/// Owned by `BrowserState.groups` (keyed by `token`). Plain data: holds no
/// reference to BrowserState or to the Tab list. Membership is **not stored
/// here** — `Tab.groupToken` is the single source of truth, so callers
/// derive the member set via `state.normalTabs.filter { $0.groupToken == token }`
/// and pass the resulting count to `displayTitle(memberCount:)` when they
/// need a rendered title.
final class WebContentGroupInfo: ObservableObject {
    /// Hex string identifying the Chromium `TabGroupId` (see
    /// `TabGroupsProxy::TokenToHexString`). Immutable for the lifetime of
    /// the group.
    let token: String

    /// User-set title. Empty string means "use auto-name" — see
    /// `displayTitle(memberCount:)`.
    @Published var title: String

    @Published var color: GroupColor

    @Published var isCollapsed: Bool

    init(token: String,
         title: String,
         color: GroupColor,
         isCollapsed: Bool) {
        self.token = token
        self.title = title
        self.color = color
        self.isCollapsed = isCollapsed
    }

    /// True iff the user has set an explicit title. When false the
    /// `displayTitle(memberCount:)` auto-name already encodes the count, so
    /// callers showing a separate count badge should hide it.
    var hasUserSetTitle: Bool { !title.isEmpty }

    /// Title shown in the sidebar header. Falls back to "<Color> · N tabs"
    /// when the user hasn't set an explicit title. The count is supplied by
    /// the caller because membership lives on `Tab.groupToken`, not here.
    func displayTitle(memberCount: Int) -> String {
        if !title.isEmpty { return title }
        let format = NSLocalizedString("tabs.tabGroup.summaryWithTabCount", value: "%@ · %d tabs",
            comment: "Tab Groups - auto-generated group title, e.g. 'Blue · 3 tabs'")
        return String(format: format, color.localizedName, memberCount)
    }

    /// Reconciles a per-token cancellable map against the current
    /// `groups` snapshot, dropping subscriptions for vanished tokens
    /// and adding `objectWillChange` sinks for new ones. `onChange` is
    /// invoked on the main queue with the changed token whenever a
    /// surviving group fires.
    ///
    /// Why this lives here: the only events that travel through
    /// `info.objectWillChange` (membership flips via `Tab.groupToken`,
    /// title / color / collapsed mutations) don't republish
    /// `BrowserState.$groups`, so any UI that mirrors group state must
    /// subscribe per-info. Centralizing the subscription bookkeeping
    /// avoids duplicating the same boilerplate at every observer
    /// (currently `TabStrip` and `WebContentContainerViewController`).
    static func reconcileSubscriptions(
        groups: [String: WebContentGroupInfo],
        cancellables: inout [String: AnyCancellable],
        onChange: @escaping (String) -> Void
    ) {
        let liveTokens = Set(groups.keys)
        cancellables = cancellables.filter { liveTokens.contains($0.key) }
        for (token, info) in groups where cancellables[token] == nil {
            cancellables[token] = info.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { _ in onChange(token) }
        }
    }
}
