// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class BookmarkManagerRouteTests: XCTestCase {
    func testMatchesNormalizedBookmarkManagerURLs() {
        XCTAssertTrue(BookmarkManagerRoute.matches("chrome://bookmarks"))
        XCTAssertTrue(BookmarkManagerRoute.matches("chrome://bookmarks/"))
        XCTAssertTrue(BookmarkManagerRoute.matches("CHROME://BOOKMARKS/?id=work#selected"))
        XCTAssertTrue(BookmarkManagerRoute.matches("chrome://bookmarks/folder/123"))
    }

    func testRequiresURLProcessorNormalization() {
        XCTAssertFalse(BookmarkManagerRoute.matches("phi://bookmarks"))
        XCTAssertTrue(
            BookmarkManagerRoute.matches(
                URLProcessor.processUserInput("phi://bookmarks")
            )
        )
    }

    func testRejectsLookalikeAndExternalURLs() {
        XCTAssertFalse(BookmarkManagerRoute.matches("https://bookmarks/"))
        XCTAssertFalse(BookmarkManagerRoute.matches("chrome://bookmarks.example/"))
        XCTAssertFalse(BookmarkManagerRoute.matches("chrome://history/"))
        XCTAssertFalse(BookmarkManagerRoute.matches("chrome://user@bookmarks/"))
        XCTAssertFalse(BookmarkManagerRoute.matches("chrome://bookmarks:123/"))
    }

    func testRejectsMissingAndMalformedURLs() {
        XCTAssertFalse(BookmarkManagerRoute.matches(nil))
        XCTAssertFalse(BookmarkManagerRoute.matches(""))
        XCTAssertFalse(BookmarkManagerRoute.matches("bookmarks"))
        XCTAssertFalse(BookmarkManagerRoute.matches("://bookmarks"))
    }
}
