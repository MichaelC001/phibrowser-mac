// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import WebKit
import XCTest
@testable import Phi

/// `WKNavigationAction` has no public initializer, so the delegate contract
/// can only be exercised through a subclass.
private final class StubNavigationAction: WKNavigationAction {
    private let stubbedRequest: URLRequest
    init(url: URL) { stubbedRequest = URLRequest(url: url) }
    override var request: URLRequest { stubbedRequest }
    override var navigationType: WKNavigationType { .linkActivated }
}

/// Tests for the copy controls the reader attaches to code blocks.
///
/// The reader surface runs with JavaScript disabled, so a control is a link
/// with a private scheme that `ReaderViewController` cancels and handles
/// natively. Both halves of that contract are pinned here: the markup the
/// builder emits, and the parsing that turns a click back into an index.
final class ReaderDocumentBuilderTests: XCTestCase {

    private func article(html: String, codeBlocks: [String]) -> ReaderArticle {
        ReaderArticle(title: "Title", byline: nil, siteName: nil, lang: "en",
                      contentHTML: html, sourceURL: "https://example.com/a",
                      rung: "rule", coverage: 0.8, codeBlocks: codeBlocks)
    }

    private func document(_ article: ReaderArticle,
                          style: ReaderStyle = ReaderStyle(fontSize: 19, width: .normal,
                                                           theme: .light, typeface: .serif),
                          appearanceIsDark: Bool = false) -> String {
        ReaderDocumentBuilder.makeDocument(article: article, style: style,
                                           appearanceIsDark: appearanceIsDark)
    }

    private func style(width: ReaderStyle.Width = .normal,
                       theme: ReaderStyle.Theme = .light,
                       typeface: ReaderStyle.Typeface = .serif) -> ReaderStyle {
        ReaderStyle(fontSize: 19, width: width, theme: theme, typeface: typeface)
    }

    // MARK: - Controls

    func testAttachesOneCopyControlPerCodeBlock() {
        let html = "<p>Intro</p>"
            + "<div class=\"phi-code\" data-phi-code=\"0\"><pre class=\"brush: js\"><code>one()</code></pre></div>"
            + "<p>Then</p>"
            + "<div class=\"phi-code\" data-phi-code=\"1\"><pre class=\"brush: js\"><code>two()</code></pre></div>"
        let output = document(article(html: html, codeBlocks: ["one()", "two()"]))

        XCTAssertEqual(output.components(separatedBy: "class=\"phi-copy\"").count - 1, 2)
        XCTAssertTrue(output.contains("href=\"phi-reader://copy/0\""))
        XCTAssertTrue(output.contains("href=\"phi-reader://copy/1\""))
    }

    func testPutsEachControlImmediatelyBeforeItsOwnBlock() {
        let html = "<div class=\"phi-code\" data-phi-code=\"0\"><pre><code>first</code></pre></div>"
            + "<div class=\"phi-code\" data-phi-code=\"1\"><code>second</code></div>"
        let output = document(article(html: html, codeBlocks: ["first", "second"]))

        // Each control sits inside its own wrapper, and the pairs stay in
        // document order, so control 0 precedes the second block entirely.
        let zero = try? XCTUnwrap(output.range(of: "phi-reader://copy/0"))
        let secondBlock = try? XCTUnwrap(output.range(of: "data-phi-code=\"1\""))
        let one = try? XCTUnwrap(output.range(of: "phi-reader://copy/1"))
        guard let zero, let secondBlock, let one else { return XCTFail("missing markup") }
        XCTAssertTrue(zero.upperBound < secondBlock.lowerBound)
        XCTAssertTrue(secondBlock.upperBound < one.lowerBound)
        XCTAssertTrue(output.contains("<code>first</code>"))
    }

    func testPutsTheControlInsideTheBlockWrapper() {
        // The wrapper comes from the extractor, which builds it in a DOM so it
        // is always balanced. The control has to land inside it, because that
        // wrapper is the positioning context that puts it in the corner.
        let html = "<div class=\"phi-code\" data-phi-code=\"0\"><pre class=\"brush: js\"><code>one()</code></pre></div>"
            + "<p>After the code.</p>"
            + "<div class=\"phi-code\" data-phi-code=\"1\"><pre class=\"brush: js\"><code>two()</code></pre></div>"
        let output = document(article(html: html, codeBlocks: ["one()", "two()"]))

        XCTAssertTrue(output.contains(
            "data-phi-code=\"0\"><a class=\"phi-copy\" href=\"phi-reader://copy/0\">"),
            "the control must be the wrapper's first child")
        XCTAssertTrue(output.contains(
            "data-phi-code=\"1\"><a class=\"phi-copy\" href=\"phi-reader://copy/1\">"))
        // The prose between the blocks is untouched.
        XCTAssertTrue(output.contains("<p>After the code.</p>"))
    }

    func testAddsNothingWhenThereAreNoCodeBlocks() {
        let output = document(article(html: "<p>Just prose.</p>", codeBlocks: []))
        // The stylesheet always defines .phi-copy, so the anchor markup is
        // what distinguishes "no controls" from "controls styled but unused".
        XCTAssertFalse(output.contains("class=\"phi-copy\""))
        XCTAssertFalse(output.contains("phi-reader://"))
    }

    func testLeavesAnUnmarkedBlockAlone() {
        // A `<pre>` the extractor did not index — an empty one, or markup from
        // the accessibility path — gets no control rather than a wrong one.
        let html = "<pre><code>unindexed</code></pre>"
        let output = document(article(html: html, codeBlocks: []))
        XCTAssertFalse(output.contains("class=\"phi-copy\""))
    }

    // MARK: - Style options

    func testTheDocumentCarriesEveryVariant() {
        // All of them are present so a change is an attribute write, not a
        // rebuild. If a variant is missing, switching to it does nothing.
        let doc = document(article(html: "<p>x</p>", codeBlocks: []))
        for width in ReaderStyle.Width.allCases {
            XCTAssertTrue(doc.contains("html[data-width=\"\(width.rawValue)\"]"),
                          "no rule for width \(width.rawValue)")
        }
        for typeface in ReaderStyle.Typeface.allCases {
            XCTAssertTrue(doc.contains("html[data-typeface=\"\(typeface.rawValue)\"]"),
                          "no rule for typeface \(typeface.rawValue)")
        }
        for theme in ReaderStyle.Theme.allCases where theme != .matchBrowser {
            XCTAssertTrue(doc.contains("html[data-theme=\"\(theme.rawValue)\"]"),
                          "no palette for theme \(theme.rawValue)")
        }
        XCTAssertTrue(doc.contains("max-width: 32em"))
        // Full width means no column cap at all, not a very large one.
        XCTAssertTrue(doc.contains("max-width: none"))
        XCTAssertTrue(doc.contains("#f6efe1"), "sepia palette missing")
    }

    func testTheRootAttributesSelectTheChosenVariant() {
        let doc = document(article(html: "<p>x</p>", codeBlocks: []),
                           style: style(width: .full, theme: .sepia, typeface: .sans))
        XCTAssertTrue(doc.contains("data-width=\"full\""))
        XCTAssertTrue(doc.contains("data-theme=\"sepia\""))
        XCTAssertTrue(doc.contains("data-typeface=\"sans\""))
    }

    func testMatchBrowserIsResolvedBeforeItReachesTheDocument() {
        // The document is told a real palette, never a preference, which is
        // what lets an appearance change swap it in place.
        let a = article(html: "<p>x</p>", codeBlocks: [])
        XCTAssertTrue(document(a, style: style(theme: .matchBrowser),
                               appearanceIsDark: false).contains("data-theme=\"light\""))
        XCTAssertTrue(document(a, style: style(theme: .matchBrowser),
                               appearanceIsDark: true).contains("data-theme=\"dark\""))
        XCTAssertFalse(document(a, style: style(theme: .matchBrowser),
                                appearanceIsDark: true).contains("data-theme=\"matchBrowser\""))
    }

    func testAFixedBackgroundIgnoresTheAppAppearance() {
        // The point of choosing sepia is that it stays sepia.
        let doc = document(article(html: "<p>x</p>", codeBlocks: []),
                           style: style(theme: .sepia), appearanceIsDark: true)
        XCTAssertTrue(doc.contains("data-theme=\"sepia\""))
    }

    func testTheUpdateScriptSetsTheSameAttributesTheDocumentUses() {
        // The script and the markup have to agree, or a change would select a
        // variant the stylesheet has no rule for.
        let script = ReaderDocumentBuilder.styleUpdateScript(
            style(width: .wide, theme: .matchBrowser, typeface: .sans),
            appearanceIsDark: true)
        XCTAssertTrue(script.contains("'data-theme','dark'"))
        XCTAssertTrue(script.contains("'data-width','wide'"))
        XCTAssertTrue(script.contains("'data-typeface','sans'"))
    }

    // MARK: - Text size

    func testTheDefaultSizeIsUnscaled() {
        // The live document is built at the default size, so that size must
        // map to no zoom at all.
        XCTAssertEqual(
            ReaderDocumentBuilder.textZoom(
                forFontSize: ReaderDocumentBuilder.defaultFontSize),
            1.0, accuracy: 0.0001)
    }

    func testSizeStepsScaleMonotonically() {
        var previous = 0.0
        for size in stride(from: ReaderDocumentBuilder.minFontSize,
                           through: ReaderDocumentBuilder.maxFontSize,
                           by: ReaderDocumentBuilder.fontSizeStep) {
            let zoom = Double(ReaderDocumentBuilder.textZoom(forFontSize: size))
            XCTAssertGreaterThan(zoom, previous, "size \(size) did not increase the zoom")
            previous = zoom
        }
    }

    func testTheExtremesStayWithinAReadableRange() {
        // A zoom far from 1 would mean the document is built at the wrong
        // base size, and hairlines and spacing would scale badly.
        let smallest = ReaderDocumentBuilder.textZoom(forFontSize: ReaderDocumentBuilder.minFontSize)
        let largest = ReaderDocumentBuilder.textZoom(forFontSize: ReaderDocumentBuilder.maxFontSize)
        XCTAssertGreaterThan(smallest, 0.6)
        XCTAssertLessThan(largest, 1.6)
    }

    // MARK: - Click parsing

    func testParsesTheIndexBackOutOfACopyURL() {
        let url = URL(string: "phi-reader://copy/7")!
        XCTAssertEqual(ReaderDocumentBuilder.copyIndex(from: url), 7)
    }

    // MARK: - The click, end to end

    @MainActor
    private func clickReader(_ urlString: String,
                             blocks: [String]) -> (policy: WKNavigationActionPolicy,
                                                   copied: Bool,
                                                   navigated: URL?) {
        let controller = ReaderViewController()
        controller.loadView()
        controller.present(article: article(html: "<p>x</p>", codeBlocks: blocks))

        var copied = false
        var navigated: URL?
        controller.onDidCopyCode = { copied = true }
        controller.onNavigate = { navigated = $0 }

        var policy: WKNavigationActionPolicy = .allow
        controller.webView(WKWebView(),
                           decidePolicyFor: StubNavigationAction(
                            url: URL(string: urlString)!)) { policy = $0 }
        return (policy, copied, navigated)
    }

    @MainActor
    func testClickingACopyControlPutsThatBlockOnThePasteboard() {
        NSPasteboard.general.clearContents()
        let result = clickReader("phi-reader://copy/1", blocks: ["first()", "second()"])

        XCTAssertEqual(result.policy, .cancel, "a copy control must not navigate")
        XCTAssertTrue(result.copied)
        XCTAssertNil(result.navigated, "copying is not a navigation")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "second()")
    }

    @MainActor
    func testAnOutOfRangeCopyControlDoesNothing() {
        // Defensive: a stale document rendered against a newer article must
        // not copy the wrong block or crash.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("untouched", forType: .string)
        let result = clickReader("phi-reader://copy/9", blocks: ["only()"])

        XCTAssertFalse(result.copied)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "untouched")
    }

    @MainActor
    func testAnOrdinaryLinkStillLeavesTheReader() {
        let result = clickReader("https://example.com/elsewhere", blocks: ["only()"])
        XCTAssertEqual(result.policy, .cancel)
        XCTAssertFalse(result.copied)
        XCTAssertEqual(result.navigated?.absoluteString, "https://example.com/elsewhere")
    }

    func testRejectsURLsThatAreNotCopyControls() {
        for value in ["https://example.com/copy/1", "phi-reader://other/1",
                      "phi-reader://copy/notanumber", "https://example.com"] {
            let url = URL(string: value)!
            XCTAssertNil(ReaderDocumentBuilder.copyIndex(from: url),
                         "expected \(value) to be rejected")
        }
    }

    // MARK: - Threads

    func testStylesEveryPartOfAThreadTheExtractorEmits() {
        // A thread rule emits <section class="phi-post"> holding a
        // <p class="phi-post-by"> and, for a comment tree, a data-depth. The
        // markup and the stylesheet are written in different files and in
        // different languages, so nothing but this connects them: drop a rule
        // and the reader silently goes back to showing a wall of text.
        let rendered = document(article(html:
            "<section class=\"phi-post\"><p class=\"phi-post-by\">Ann · 12</p>" +
            "<p>question</p></section>" +
            "<section class=\"phi-post\" data-depth=\"2\"><p>reply</p></section>",
            codeBlocks: []))

        XCTAssertTrue(rendered.contains(".phi-post {"), "no post styling")
        XCTAssertTrue(rendered.contains(".phi-post-by {"), "no byline styling")
        // The name has to be weighted differently from the score, or a thread
        // reads as one voice.
        XCTAssertTrue(rendered.contains(".phi-post-author {"), "no author styling")
        XCTAssertTrue(rendered.contains(".phi-post-meta {"), "no meta styling")
        // Depth 1 needs no indent step — the spine on `.phi-post[data-depth]`
        // already sets it apart from a top-level post — but 2 and deeper each
        // step further in, and the extractor caps at 5.
        XCTAssertTrue(rendered.contains(".phi-post[data-depth] {"),
                      "replies are not distinguished from top-level posts")
        for depth in 2...5 {
            XCTAssertTrue(rendered.contains("[data-depth=\"\(depth)\"]"),
                          "depth \(depth) is emitted by the extractor but not indented")
        }
    }
}
