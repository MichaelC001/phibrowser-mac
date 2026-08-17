// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Tests for the standalone reader document the builder still produces for
/// the agent API and file exports. The interactive surface lives in the Phi
/// Reader extension, whose `style.ts` mirrors this style model — these tests
/// pin the native half of that contract.
final class ReaderDocumentBuilderTests: XCTestCase {

    private func article(html: String, codeBlocks: [String]) -> ReaderArticle {
        ReaderArticle(title: "Title", byline: nil, siteName: nil, lang: "en",
                      contentHTML: html, sourceURL: "https://example.com/a",
                      rung: "rule", coverage: 0.8, codeBlocks: codeBlocks)
    }

    private func document(_ article: ReaderArticle,
                          style: ReaderStyle? = nil,
                          appearanceIsDark: Bool = false) -> String {
        ReaderDocumentBuilder.makeDocument(article: article,
                                           style: style ?? self.style(),
                                           appearanceIsDark: appearanceIsDark)
    }

    private func style(width: ReaderStyle.Width = .normal,
                       theme: ReaderStyle.Theme = .light,
                       typeface: ReaderStyle.Typeface = .serif,
                       lineHeight: ReaderStyle.LineHeight = .normal,
                       letterSpacing: ReaderStyle.LetterSpacing = .normal,
                       showsImages: Bool = true,
                       highlightsLinks: Bool = true) -> ReaderStyle {
        ReaderStyle(fontSize: 19, width: width, theme: theme, typeface: typeface,
                    lineHeight: lineHeight, letterSpacing: letterSpacing,
                    showsImages: showsImages, highlightsLinks: highlightsLinks)
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
        for lineHeight in ReaderStyle.LineHeight.allCases {
            XCTAssertTrue(doc.contains("html[data-line-height=\"\(lineHeight.rawValue)\"]"),
                          "no rule for line height \(lineHeight.rawValue)")
        }
        for letterSpacing in ReaderStyle.LetterSpacing.allCases {
            XCTAssertTrue(doc.contains("html[data-letter-spacing=\"\(letterSpacing.rawValue)\"]"),
                          "no rule for letter spacing \(letterSpacing.rawValue)")
        }
        XCTAssertTrue(doc.contains("html[data-images=\"off\"]"), "images cannot be hidden")
        XCTAssertTrue(doc.contains("html[data-links=\"off\"]"), "links cannot be un-highlighted")
        XCTAssertTrue(doc.contains("max-width: 32em"))
        // Full width means no column cap at all, not a very large one.
        XCTAssertTrue(doc.contains("max-width: none"))
        XCTAssertTrue(doc.contains("#f6efe1"), "sepia palette missing")
    }

    func testTheRootAttributesSelectTheChosenVariant() {
        let doc = document(article(html: "<p>x</p>", codeBlocks: []),
                           style: style(width: .full, theme: .sepia, typeface: .sans,
                                        lineHeight: .loose, letterSpacing: .wider,
                                        showsImages: false, highlightsLinks: false))
        XCTAssertTrue(doc.contains("data-width=\"full\""))
        XCTAssertTrue(doc.contains("data-theme=\"sepia\""))
        XCTAssertTrue(doc.contains("data-typeface=\"sans\""))
        XCTAssertTrue(doc.contains("data-line-height=\"loose\""))
        XCTAssertTrue(doc.contains("data-letter-spacing=\"wider\""))
        XCTAssertTrue(doc.contains("data-images=\"off\""))
        XCTAssertTrue(doc.contains("data-links=\"off\""))
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
