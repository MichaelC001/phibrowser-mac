// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// URL policy for the native bookmark-manager renderer.
///
/// `phi://bookmarks` is normalized by `URLProcessor` before Chromium creates
/// the tab, so presentation follows the associated tab's canonical
/// `chrome://bookmarks` URL. Paths, queries, and fragments remain Chromium-owned
/// navigation state inside the same internal page.
enum BookmarkManagerRoute {
    static func matches(_ rawURLString: String?) -> Bool {
        guard let rawURLString = rawURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURLString.isEmpty,
              let components = URLComponents(string: rawURLString),
              components.scheme?.lowercased() == "chrome",
              components.host?.lowercased() == "bookmarks",
              components.user == nil,
              components.password == nil,
              components.port == nil else {
            return false
        }
        return true
    }
}
