// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Serializes a Space's bookmark tree — optionally preceded by a Favorites
/// folder carrying the window's visible pinned tabs — into the Netscape
/// bookmark file format (`NETSCAPE-Bookmark-file-1`) understood by Chrome,
/// Firefox, Safari, and Edge. Pure string building — file writing and the
/// save panel live with the menu action in `AppController`.
enum BookmarkHTMLExporter {
    static func htmlDocument(for bookmarks: [Bookmark],
                             pinnedTabs: [Tab],
                             favoritesFolderTitle: String) -> String {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file.",
            "     It will be read and overwritten.",
            "     DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        appendFavoritesFolder(for: pinnedTabs, title: favoritesFolderTitle, into: &lines)
        for bookmark in bookmarks {
            appendNode(bookmark, depth: 1, into: &lines)
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The export-enablement predicate, defined per spec as: bookmark tree
    /// non-empty OR visible pinned collection non-empty. The single
    /// definition shared by menu validation, the action entry point, and
    /// the save-panel confirmation re-read, so the three can never drift.
    /// Pinned records count even when none has a usable URL — that
    /// degenerate export is a valid, item-less document.
    static func hasExportableContent(bookmarks: [Bookmark], pinnedTabs: [Tab]) -> Bool {
        !bookmarks.isEmpty || !pinnedTabs.isEmpty
    }

    /// Renders the visible pinned collection as one Favorites folder, first
    /// in the top-level list — mirroring the sidebar, where pinned tabs sit
    /// above bookmarks. Entries carry the saved state a pin re-opens to,
    /// never live navigation state; pinned tabs with no usable URL are
    /// skipped, and the folder is omitted when no entry survives.
    private static func appendFavoritesFolder(for pinnedTabs: [Tab],
                                              title: String,
                                              into lines: inout [String]) {
        let entries = pinnedTabs.compactMap(favoritesEntry(for:))
        guard !entries.isEmpty else { return }
        lines.append("    <DT><H3>\(escaped(title))</H3>")
        lines.append("    <DL><p>")
        lines.append(contentsOf: entries)
        lines.append("    </DL><p>")
    }

    /// One `<DT><A>` line for a pinned tab, or nil when both the saved and
    /// live URL are empty. A split pinned pair arrives as two records and so
    /// exports as two adjacent plain entries; the bookmark-provenance
    /// secondary fields on pinned records are never emitted (they would
    /// duplicate the partner's entry).
    private static func favoritesEntry(for tab: Tab) -> String? {
        let savedOrLiveURL = (tab.pinnedUrl?.isEmpty == false) ? tab.pinnedUrl : tab.url
        guard let url = savedOrLiveURL, !url.isEmpty else { return nil }
        let title = tab.storedTitle ?? tab.title
        let favicon = isFaviconPresumedDrifted(for: tab) ? nil : tab.cachedFaviconData
        let attributes = " HREF=\"\(escaped(url))\""
            + addDateAttribute(for: tab.pinnedCreatedDate)
            + iconAttribute(for: favicon)
        return "        <DT><A\(attributes)>\(escaped(title))</A>"
    }

    /// An open pinned tab's cached favicon follows live navigation (it is
    /// cleared and rewritten when the page host changes), so a live URL on a
    /// different host than the saved URL means the cached bytes belong to the
    /// live site, not the pin — such an entry carries no ICON and importers
    /// fetch their own. Closed and unloaded records normally carry
    /// `url == pinnedUrl` and keep their ICON; a record detached with a
    /// stale live `url` trips this only when its favicon truly drifted.
    /// Host normalization mirrors the favicon
    /// pipeline's (lowercased, `www.` stripped, full-string comparison when
    /// a host is unparseable) so the presumption matches how drift happens.
    private static func isFaviconPresumedDrifted(for tab: Tab) -> Bool {
        guard let savedURL = normalizedNonEmptyURLString(tab.pinnedUrl),
              let liveURL = normalizedNonEmptyURLString(tab.url) else { return false }
        guard let savedHost = normalizedFaviconHost(savedURL),
              let liveHost = normalizedFaviconHost(liveURL) else {
            return savedURL != liveURL
        }
        return savedHost != liveHost
    }

    private static func normalizedNonEmptyURLString(_ urlString: String?) -> String? {
        guard let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedFaviconHost(_ urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func appendNode(_ bookmark: Bookmark, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "    ", count: depth)
        if bookmark.isFolder {
            lines.append("\(indent)<DT><H3\(folderDateAttributes(for: bookmark))>\(escaped(bookmark.title))</H3>")
            lines.append("\(indent)<DL><p>")
            for child in bookmark.children {
                appendNode(child, depth: depth + 1, into: &lines)
            }
            lines.append("\(indent)</DL><p>")
            return
        }
        let attributes = " HREF=\"\(escaped(bookmark.url ?? ""))\""
            + addDateAttribute(for: bookmark.createdDate)
            + iconAttribute(for: bookmark.cachedFaviconData)
        lines.append("\(indent)<DT><A\(attributes)>\(escaped(bookmark.title))</A>")
        // A split bookmark carries a second URL the generic format cannot
        // express on one entry — flatten it into an adjacent plain entry.
        // Its title falls back to the primary title (suppressed-duplicate
        // convention at creation), then to the URL itself.
        if let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty {
            let fallback = bookmark.title.isEmpty ? secondaryURL : bookmark.title
            let secondaryTitle = (bookmark.secondaryTitle?.isEmpty == false)
                ? bookmark.secondaryTitle! : fallback
            let secondaryAttributes = " HREF=\"\(escaped(secondaryURL))\"" + addDateAttribute(for: bookmark.createdDate)
            lines.append("\(indent)<DT><A\(secondaryAttributes)>\(escaped(secondaryTitle))</A>")
        }
    }

    private static func addDateAttribute(for created: Date?) -> String {
        guard let created else { return "" }
        return " ADD_DATE=\"\(Int(created.timeIntervalSince1970))\""
    }

    private static func iconAttribute(for favicon: Data?) -> String {
        guard let favicon else { return "" }
        return " ICON=\"data:image/png;base64,\(favicon.base64EncodedString())\""
    }

    /// URL entries carry ADD_DATE only: LAST_MODIFIED means "last edit" in
    /// the format, while `updatedDate` is also bumped by bookmark opens
    /// (LocalStore.updateLastSeen). Chrome's exporter omits it on entries
    /// too. Folder rows are only touched by real edits, so folders keep it.
    private static func folderDateAttributes(for bookmark: Bookmark) -> String {
        var attributes = addDateAttribute(for: bookmark.createdDate)
        if let updated = bookmark.updatedDate {
            attributes += " LAST_MODIFIED=\"\(Int(updated.timeIntervalSince1970))\""
        }
        return attributes
    }

    /// Default export filename: `Phi-Bookmarks-<SpaceName>-<yyyy-MM-dd>.html`,
    /// spaces-free throughout. Whitespace and the filesystem-hostile `/` and
    /// `:` in the Space name become hyphens; runs collapse to one.
    static func defaultFilename(spaceName: String, date: Date) -> String {
        var collapsed = ""
        for character in spaceName {
            let mapped: Character =
                (character == "/" || character == ":" || character.isWhitespace) ? "-" : character
            if mapped == "-", collapsed.hasSuffix("-") { continue }
            collapsed.append(mapped)
        }
        let name = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let segment = name.isEmpty ? "Space" : name

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Phi-Bookmarks-\(segment)-\(formatter.string(from: date)).html"
    }

    /// Escapes text for use in HTML body text and double-quoted attributes.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
