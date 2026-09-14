// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation

/// Durable, reopenable data only. Live tab IDs are optional session hints.
struct TravelBackPage: Codable, Equatable {
    let url: String
    var title: String? = nil
    var favicon: String? = nil

    var isReopenable: Bool {
        guard url.utf8.count <= 16384, let parsed = URL(string: url),
              let host = parsed.host, !host.isEmpty else { return false }
        return parsed.scheme == "http" || parsed.scheme == "https"
    }
}

struct TravelBackSplit: Codable, Equatable {
    let members: [TravelBackPage]
    var orientation: String? = nil
    var ratio: Double? = nil
    var activeIndex: Int? = nil

    func validated(for page: TravelBackPage) throws -> TravelBackSplit {
        guard members.count == 2, members.allSatisfy(\.isReopenable),
              orientation == nil || ["vertical", "horizontal"].contains(orientation!),
              ratio == nil || (ratio!.isFinite && ratio! > 0 && ratio! < 1),
              activeIndex == nil || (0...1).contains(activeIndex!) else {
            throw TravelBackFailure.invalidSnapshot
        }
        return TravelBackSplit(
            members: members, orientation: orientation ?? "vertical", ratio: ratio ?? 0.5,
            activeIndex: activeIndex ?? members.firstIndex(where: { $0.url == page.url }) ?? 0
        )
    }
}

struct TravelBackScene: Codable {
    struct TabRef: Codable { let tabId: Int }
    struct WindowRef: Codable { let windowId: Int }
    struct Layout: Codable { let splitView: TravelBackSplit? }
    var page: TravelBackPage? = nil
    var tab: TabRef? = nil
    var window: WindowRef? = nil
    var profileId: String? = nil
    var layout: Layout? = nil
    /// Live capture-only membership, omitted by the persisted client schema.
    var relatedTabIds: [Int]? = nil
}

enum TravelBackFailure: String, Error {
    case unauthorizedSender = "unauthorized_sender"
    case invalidSnapshot = "invalid_snapshot"
    case unavailable = "unavailable"
    case targetChanged = "target_changed"
    case busy = "busy"
    case timedOut = "timed_out"
}

struct TravelBackTabRef: Equatable {
    let tabId: Int
    let windowId: Int
    let url: String

    static func anchor(for scene: TravelBackScene, current: TravelBackTabRef?,
                       openTabs: [TravelBackTabRef]) -> TravelBackTabRef? {
        if let current, current.url == scene.page?.url { return current }
        guard let recordedId = scene.tab?.tabId else { return nil }
        return openTabs.first { $0.tabId == recordedId }
    }
}

/// Pure conflict policy; never searches other tabs by URL or dismantles a split.
enum TravelBackSplitPlan: Equatable {
    case reuse
    case completeAnchor
    case newPair

    static func choose(recorded: TravelBackSplit, existingURLs: [String]?,
                       hasAnchor: Bool, anchorCanJoin: Bool) -> Self {
        if let existingURLs {
            return existingURLs == recorded.members.map(\.url) ? .reuse : .newPair
        }
        return hasAnchor && anchorCanJoin ? .completeAnchor : .newPair
    }
}
