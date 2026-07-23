// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Tests for the Netscape bookmark HTML exporter: document skeleton,
/// escaping, folder nesting, split-bookmark expansion, timestamps, ICON
/// data URIs, the pinned-tab Favorites folder, the export-enablement
/// predicate, and the default export filename. Pure serialization — the
/// menu item and NSSavePanel flow are manual E2E.
final class BookmarkHTMLExporterTests: XCTestCase {

    func testSingleBookmarkProducesNetscapeDocument() {
        let bookmark = Bookmark(guid: "g1",
                                title: "Example",
                                url: "https://example.com/",
                                createdDate: Date(timeIntervalSince1970: 1_720_000_000),
                                updatedDate: Date(timeIntervalSince1970: 1_720_000_100))

        let html = BookmarkHTMLExporter.htmlDocument(for: [bookmark],
                                                     pinnedTabs: [],
                                                     favoritesFolderTitle: "")

        let expected = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><A HREF="https://example.com/" ADD_DATE="1720000000">Example</A>
        </DL><p>

        """
        // The input carries `updatedDate` on purpose: URL entries must NOT
        // emit LAST_MODIFIED (it means "last edit" in the format, while our
        // updatedDate is also bumped by opens; Chrome's exporter omits it on
        // entries too). Folders keep it — see the nesting test.
        XCTAssertEqual(html, expected)
    }

    func testEscapesHTMLSpecialCharactersInTitleAndURL() {
        let bookmark = Bookmark(guid: "g2",
                                title: "A & B <\"quoted\"> 'single'",
                                url: "https://example.com/?a=1&b=2")

        let html = BookmarkHTMLExporter.htmlDocument(for: [bookmark],
                                                     pinnedTabs: [],
                                                     favoritesFolderTitle: "")

        XCTAssertTrue(html.contains(
            "<DT><A HREF=\"https://example.com/?a=1&amp;b=2\">A &amp; B &lt;&quot;quoted&quot;&gt; &#39;single&#39;</A>"))
        XCTAssertFalse(html.contains("a=1&b=2"))
    }

    func testNestedFoldersEmitH3AndIndentedDL() {
        let inner = Bookmark(guid: "g3", title: "Inner", url: "https://inner.example/")
        let emptyFolder = Bookmark(guid: "g4", title: "Empty", isFolder: true)
        let folder = Bookmark(guid: "g5",
                              title: "Work",
                              createdDate: Date(timeIntervalSince1970: 1_720_000_000),
                              updatedDate: Date(timeIntervalSince1970: 1_720_000_100),
                              isFolder: true)
        folder.addChild(inner)
        folder.addChild(emptyFolder)

        let html = BookmarkHTMLExporter.htmlDocument(for: [folder],
                                                     pinnedTabs: [],
                                                     favoritesFolderTitle: "")

        let expected = [
            "    <DT><H3 ADD_DATE=\"1720000000\" LAST_MODIFIED=\"1720000100\">Work</H3>",
            "    <DL><p>",
            "        <DT><A HREF=\"https://inner.example/\">Inner</A>",
            "        <DT><H3>Empty</H3>",
            "        <DL><p>",
            "        </DL><p>",
            "    </DL><p>",
        ].joined(separator: "\n")
        XCTAssertTrue(html.contains(expected))
    }

    func testSplitBookmarkExportsAsTwoAdjacentEntries() {
        let split = Bookmark(guid: "g6",
                             title: "Docs",
                             url: "https://left.example/",
                             secondaryUrl: "https://right.example/",
                             secondaryTitle: "Spec")
        // secondaryTitle is suppressed at creation when both panes share a
        // title — the second entry falls back to the primary title.
        let unnamedSplit = Bookmark(guid: "g7",
                                    title: "Pair",
                                    url: "https://a.example/",
                                    secondaryUrl: "https://b.example/")

        let html = BookmarkHTMLExporter.htmlDocument(for: [split, unnamedSplit],
                                                     pinnedTabs: [],
                                                     favoritesFolderTitle: "")

        let expected = [
            "    <DT><A HREF=\"https://left.example/\">Docs</A>",
            "    <DT><A HREF=\"https://right.example/\">Spec</A>",
            "    <DT><A HREF=\"https://a.example/\">Pair</A>",
            "    <DT><A HREF=\"https://b.example/\">Pair</A>",
        ].joined(separator: "\n")
        XCTAssertTrue(html.contains(expected))
    }

    func testCachedFaviconEmitsIconDataURI() {
        // PNG magic bytes 0x89 0x50 0x4E 0x47 — base64 "iVBORw==".
        let bookmark = Bookmark(guid: "g8",
                                title: "Icon",
                                url: "https://icon.example/",
                                faviconData: Data([0x89, 0x50, 0x4E, 0x47]))

        let html = BookmarkHTMLExporter.htmlDocument(for: [bookmark],
                                                     pinnedTabs: [],
                                                     favoritesFolderTitle: "")

        XCTAssertTrue(html.contains(
            "<DT><A HREF=\"https://icon.example/\" ICON=\"data:image/png;base64,iVBORw==\">Icon</A>"))
    }

    func testPinnedTabsExportAsLeadingFavoritesFolder() {
        let bookmark = Bookmark(guid: "g10", title: "Example", url: "https://example.com/")
        let pin = makePinnedTab(savedURL: "https://pin.example/", title: "Pin")

        let html = BookmarkHTMLExporter.htmlDocument(for: [bookmark],
                                                     pinnedTabs: [pin],
                                                     favoritesFolderTitle: "Favoriten")

        // The Favorites folder is the first top-level item, named from the
        // injected localized string, followed by the bookmark tree unchanged.
        let expected = [
            "<DL><p>",
            "    <DT><H3>Favoriten</H3>",
            "    <DL><p>",
            "        <DT><A HREF=\"https://pin.example/\">Pin</A>",
            "    </DL><p>",
            "    <DT><A HREF=\"https://example.com/\">Example</A>",
            "</DL><p>",
        ].joined(separator: "\n")
        XCTAssertTrue(html.contains(expected))
    }

    func testPinnedEntryExportsSavedStateNotLiveNavigation() {
        // A pinned tab navigated elsewhere: the live URL differs from the
        // saved one; the export must carry the state the pin re-opens to.
        let navigated = makePinnedTab(savedURL: "https://saved.example/",
                                      liveURL: "https://elsewhere.example/",
                                      title: "Saved",
                                      faviconData: Data([0x89, 0x50, 0x4E, 0x47]),
                                      createdDate: Date(timeIntervalSince1970: 1_720_000_000))
        // An unloaded pinned tab has no live wrapper — only record state.
        let unloaded = makePinnedTab(savedURL: "https://unloaded.example/", title: "Unloaded")

        let html = BookmarkHTMLExporter.htmlDocument(for: [],
                                                     pinnedTabs: [navigated, unloaded],
                                                     favoritesFolderTitle: "Favorites")

        // ADD_DATE only when the pin's creation date is known; the cached
        // favicon of a cross-host-navigated tab is presumed drifted, so its
        // entry carries no ICON; never LAST_MODIFIED on entries.
        let expected = [
            "        <DT><A HREF=\"https://saved.example/\" ADD_DATE=\"1720000000\">Saved</A>",
            "        <DT><A HREF=\"https://unloaded.example/\">Unloaded</A>",
        ].joined(separator: "\n")
        XCTAssertTrue(html.contains(expected))
        XCTAssertFalse(html.contains("elsewhere.example"))
        XCTAssertFalse(html.contains("LAST_MODIFIED"))
    }

    func testPinnedFaviconExportedWhenLiveHostMatchesSavedHost() {
        // Within one host (any path; `www.` differences included) the cached
        // favicon still belongs to the pinned site — host-level match
        // granularity — so the ICON stays; a closed/unloaded record mirrors
        // its saved URL and keeps it too.
        let sameHost = makePinnedTab(savedURL: "https://saved.example/",
                                     liveURL: "https://www.saved.example/deep/page",
                                     title: "SameHost",
                                     faviconData: Data([0x89, 0x50, 0x4E, 0x47]))
        let closed = makePinnedTab(savedURL: "https://closed.example/",
                                   title: "Closed",
                                   faviconData: Data([0x89, 0x50, 0x4E, 0x47]))

        let html = BookmarkHTMLExporter.htmlDocument(for: [],
                                                     pinnedTabs: [sameHost, closed],
                                                     favoritesFolderTitle: "Favorites")

        let expected = [
            "        <DT><A HREF=\"https://saved.example/\" ICON=\"data:image/png;base64,iVBORw==\">SameHost</A>",
            "        <DT><A HREF=\"https://closed.example/\" ICON=\"data:image/png;base64,iVBORw==\">Closed</A>",
        ].joined(separator: "\n")
        XCTAssertTrue(html.contains(expected))
    }

    func testPinnedFaviconOmittedWhenLiveURLHostIsUnparseable() {
        // When a host cannot be parsed the drift presumption falls back to
        // full-string comparison, mirroring the favicon pipeline — a pin
        // sitting on about:blank cannot vouch for its cached favicon.
        let unparseable = makePinnedTab(savedURL: "https://saved.example/",
                                        liveURL: "about:blank",
                                        title: "Blank",
                                        faviconData: Data([0x89, 0x50, 0x4E, 0x47]))

        let html = BookmarkHTMLExporter.htmlDocument(for: [],
                                                     pinnedTabs: [unparseable],
                                                     favoritesFolderTitle: "Favorites")

        XCTAssertTrue(html.contains("        <DT><A HREF=\"https://saved.example/\">Blank</A>"))
    }

    func testSplitPinnedPairExportsAsTwoAdjacentPlainEntries() {
        let left = makePinnedTab(savedURL: "https://left.example/",
                                 title: "Left",
                                 guidInLocalDB: "pin-left",
                                 splitPartnerGuid: "pin-right")
        let right = makePinnedTab(savedURL: "https://right.example/",
                                  title: "Right",
                                  guidInLocalDB: "pin-right",
                                  splitPartnerGuid: "pin-left")

        let html = BookmarkHTMLExporter.htmlDocument(for: [],
                                                     pinnedTabs: [left, right],
                                                     favoritesFolderTitle: "Favorites")

        let expected = [
            "        <DT><A HREF=\"https://left.example/\">Left</A>",
            "        <DT><A HREF=\"https://right.example/\">Right</A>",
        ].joined(separator: "\n")
        XCTAssertTrue(html.contains(expected))
        // Exactly one entry per pinned record — nothing on the records may
        // add a duplicate of the partner's entry.
        XCTAssertEqual(html.components(separatedBy: "<DT><A").count - 1, 2)
    }

    func testPinnedTabsWithoutUsableURLAreSkipped() {
        let urlless = makePinnedTab(savedURL: nil, title: "Broken")
        let emptyURL = makePinnedTab(savedURL: "", title: "Blank")
        let good = makePinnedTab(savedURL: "https://ok.example/", title: "OK")

        let html = BookmarkHTMLExporter.htmlDocument(for: [],
                                                     pinnedTabs: [urlless, emptyURL, good],
                                                     favoritesFolderTitle: "Favorites")

        XCTAssertFalse(html.contains("Broken"))
        XCTAssertFalse(html.contains("Blank"))
        XCTAssertTrue(html.contains("<DT><A HREF=\"https://ok.example/\">OK</A>"))

        // When no entry survives, no empty Favorites folder is emitted.
        let allSkipped = BookmarkHTMLExporter.htmlDocument(for: [],
                                                           pinnedTabs: [urlless],
                                                           favoritesFolderTitle: "Favorites")
        XCTAssertFalse(allSkipped.contains("Favorites"))
    }

    func testEmptyPinnedCollectionProducesBookmarkOnlyDocument() {
        let bookmark = Bookmark(guid: "g12",
                                title: "Example",
                                url: "https://example.com/",
                                createdDate: Date(timeIntervalSince1970: 1_720_000_000))

        let html = BookmarkHTMLExporter.htmlDocument(for: [bookmark],
                                                     pinnedTabs: [],
                                                     favoritesFolderTitle: "Favorites")

        // Byte-identical to today's bookmark-only export: no Favorites
        // folder, no trace of the pinned path.
        let expected = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><A HREF="https://example.com/" ADD_DATE="1720000000">Example</A>
        </DL><p>

        """
        XCTAssertEqual(html, expected)
    }

    func testPinnedOnlyExportProducesDocumentWithOnlyFavoritesFolder() {
        let pin = makePinnedTab(savedURL: "https://pin.example/", title: "Pin")

        let html = BookmarkHTMLExporter.htmlDocument(for: [],
                                                     pinnedTabs: [pin],
                                                     favoritesFolderTitle: "Favorites")

        // An empty bookmark tree with pinned tabs still yields a complete,
        // valid Netscape document whose only top-level item is the
        // Favorites folder.
        let expected = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3>Favorites</H3>
            <DL><p>
                <DT><A HREF="https://pin.example/">Pin</A>
            </DL><p>
        </DL><p>

        """
        XCTAssertEqual(html, expected)
    }

    func testHasExportableContentRequiresBookmarksOrPinnedTabs() {
        let bookmark = Bookmark(guid: "g13", title: "Example", url: "https://example.com/")
        let pin = makePinnedTab(savedURL: "https://pin.example/", title: "Pin")

        XCTAssertFalse(BookmarkHTMLExporter.hasExportableContent(bookmarks: [], pinnedTabs: []))
        XCTAssertTrue(BookmarkHTMLExporter.hasExportableContent(bookmarks: [bookmark], pinnedTabs: []))
        XCTAssertTrue(BookmarkHTMLExporter.hasExportableContent(bookmarks: [], pinnedTabs: [pin]))
        XCTAssertTrue(BookmarkHTMLExporter.hasExportableContent(bookmarks: [bookmark], pinnedTabs: [pin]))
    }

    func testDefaultFilenameHasNoSpacesAndSanitizesSpaceName() throws {
        // Built via the current calendar so the date renders as 2026-07-10
        // in whatever timezone the test host runs in.
        let date = try XCTUnwrap(Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 10, hour: 12)))

        XCTAssertEqual(BookmarkHTMLExporter.defaultFilename(spaceName: "Default", date: date),
                       "Phi-Bookmarks-Default-2026-07-10.html")
        XCTAssertEqual(BookmarkHTMLExporter.defaultFilename(spaceName: "My Work: A/B", date: date),
                       "Phi-Bookmarks-My-Work-A-B-2026-07-10.html")
    }

    /// Builds an in-memory pinned-record Tab the way `Tab(with:)` maps a
    /// pinned `TabDataModel` row: the saved URL/title live in `pinnedUrl` /
    /// `storedTitle`, while `url` may drift with live navigation.
    private func makePinnedTab(savedURL: String?,
                               liveURL: String? = nil,
                               title: String,
                               faviconData: Data? = nil,
                               createdDate: Date? = nil,
                               guidInLocalDB: String? = nil,
                               splitPartnerGuid: String? = nil) -> Tab {
        let tab = Tab(guid: -1,
                      url: liveURL ?? savedURL,
                      isActive: false,
                      index: 0,
                      title: title,
                      customGuid: guidInLocalDB,
                      faviconData: faviconData)
        tab.isPinned = true
        tab.storedTitle = title
        tab.pinnedUrl = savedURL
        tab.pinnedCreatedDate = createdDate
        tab.splitPartnerGuid = splitPartnerGuid
        return tab
    }
}
