// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Mac-side mirror of Chromium's `tab_groups::TabGroupColorId`.
///
/// Raw values match the wire-format strings produced by the Chromium bridge
/// (see `TabGroupsProxy::ColorIdToWireString`). Keep them in sync; an unknown
/// wire string maps to `.grey` at the bridge boundary.
enum GroupColor: String, Codable, CaseIterable {
    case grey
    case blue
    case red
    case yellow
    case green
    case pink
    case purple
    case cyan
    case orange

    /// Human-readable name used by the auto-name fallback (`displayTitle`)
    /// and by color-picker menus.
    var localizedName: String {
        switch self {
        case .grey:
            return NSLocalizedString("tabs.tabGroup.colorName.grey", value: "Grey",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .blue:
            return NSLocalizedString("tabs.tabGroup.colorName.blue", value: "Blue",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .red:
            return NSLocalizedString("tabs.tabGroup.colorName.red", value: "Red",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .yellow:
            return NSLocalizedString("tabs.tabGroup.colorName.yellow", value: "Yellow",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .green:
            return NSLocalizedString("tabs.tabGroup.colorName.green", value: "Green",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .pink:
            return NSLocalizedString("tabs.tabGroup.colorName.pink", value: "Pink",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .purple:
            return NSLocalizedString("tabs.tabGroup.colorName.purple", value: "Purple",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .cyan:
            return NSLocalizedString("tabs.tabGroup.colorName.cyan", value: "Cyan",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        case .orange:
            return NSLocalizedString("tabs.tabGroup.colorName.orange", value: "Orange",
                comment: "Tab Groups - color name shown in auto-named group title and color picker")
        }
    }
}
