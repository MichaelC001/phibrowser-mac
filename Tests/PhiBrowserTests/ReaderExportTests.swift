// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Tests for the two things in the export path that are logic rather than
/// plumbing: turning an article title into a usable filename, and deciding
/// which images an exported document needs to carry.
final class ReaderExportTests: XCTestCase {

    // MARK: - File names

    @MainActor
    private func name(_ title: String) -> String {
        ReaderExportService.suggestedFileName(title: title, extension: "html")
    }

    @MainActor
    func testKeepsAnOrdinaryTitle() {
        XCTAssertEqual(name("One week of bugs"), "One week of bugs.html")
    }

    @MainActor
    func testReplacesPathSeparatorsRatherThanDeletingThem() {
        // Deleting would run the words together: "TCP/IP" must not become
        // "TCPIP", and a slash would otherwise be read as a directory.
        XCTAssertEqual(name("TCP/IP illustrated"), "TCP IP illustrated.html")
        XCTAssertEqual(name("a:b?c*d|e\"f<g>h"), "a b c d e f g h.html")
    }

    @MainActor
    func testCollapsesTheWhitespaceThatLeaves() {
        XCTAssertEqual(name("Rate  limiting //  and you"), "Rate limiting and you.html")
    }

    @MainActor
    func testFallsBackWhenATitleLeavesNothingUsable() {
        XCTAssertEqual(name("   "), "Article.html")
        XCTAssertEqual(name("///"), "Article.html")
    }

    @MainActor
    func testNeverProducesAHiddenFile() {
        XCTAssertFalse(name(".bashrc explained").hasPrefix("."))
    }

    @MainActor
    func testCapsTheLengthInBytesNotCharacters() {
        // The filesystem limit counts bytes, so a CJK title reaches it in a
        // third of the characters an ASCII one would.
        let cjk = String(repeating: "科技爱好者周刊", count: 40)
        let produced = name(cjk)
        XCTAssertLessThanOrEqual(produced.utf8.count, 130)
        XCTAssertTrue(produced.hasSuffix(".html"))
    }

    // MARK: - Which images get carried

    func testFindsEachDistinctRemoteImage() {
        let html = """
        <img src="https://a.example/one.png">
        <p>text</p><img src="http://b.example/two.jpg" alt="x">
        <img src="https://a.example/one.png">
        """
        XCTAssertEqual(ReaderImageInliner.imageSources(in: html),
                       ["https://a.example/one.png", "http://b.example/two.jpg"])
    }

    func testIgnoresImagesThatAreAlreadySelfContained() {
        let html = "<img src=\"data:image/png;base64,AAAA\">"
        XCTAssertTrue(ReaderImageInliner.imageSources(in: html).isEmpty)
    }

    func testIgnoresSourcesItCannotFetch() {
        let html = "<img src=\"/relative.png\"><img src=\"file:///tmp/x.png\">"
        XCTAssertTrue(ReaderImageInliner.imageSources(in: html).isEmpty)
    }

    func testStillFindsTheSourceOfADeferredImage() {
        // Extraction marks every image `loading="lazy"` so the reader fetches
        // only what is on screen. An export has the opposite job — every image
        // has to be inlined for the file to open offline — so this must keep
        // finding them, whichever side of `src` the attribute lands on.
        let html = """
        <img src="https://a.example/one.png" loading="lazy">
        <img loading="lazy" src="https://b.example/two.jpg">
        """
        XCTAssertEqual(ReaderImageInliner.imageSources(in: html),
                       ["https://a.example/one.png", "https://b.example/two.jpg"])
    }

    func testDoesNotMistakeOtherAttributesForAnImageSource() {
        let html = "<a href=\"https://example.com/page\">link</a>"
            + "<video src=\"https://example.com/clip.mp4\"></video>"
        XCTAssertTrue(ReaderImageInliner.imageSources(in: html).isEmpty)
    }

    // MARK: - Document assembly

    @MainActor
    func testLeavesImagesAloneWhenNotInlining() async {
        // The agent API asks for the document without inlining, to avoid
        // carrying megabytes of base64 over the message channel. If that flag
        // stopped being honoured the call would silently start refetching
        // every image in the article.
        let article = ReaderArticle(
            title: "Title", byline: nil, siteName: nil, lang: "en",
            contentHTML: "<p>body</p><img src=\"https://a.example/one.png\">",
            sourceURL: "https://a.example/post", rung: "rule", coverage: 0.5)
        let data = await ReaderExportService.makeArticleDocument(
            article: article,
            style: ReaderStyle(fontSize: 18, width: .normal,
                               theme: .light, typeface: .serif,
                               lineHeight: .normal, letterSpacing: .normal,
                               showsImages: true, highlightsLinks: true),
            appearanceIsDark: false,
            inlineImages: false)
        let document = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(document.contains("src=\"https://a.example/one.png\""))
        XCTAssertFalse(document.contains("src=\"data:"))
    }
}
