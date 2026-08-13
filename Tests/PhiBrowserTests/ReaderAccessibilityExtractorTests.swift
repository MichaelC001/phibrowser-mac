// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Tests for the accessibility walk that backs Reader View on PDFs.
///
/// The shapes here mirror what `PdfAccessibilityTreeBuilder` produces: a
/// pdfRoot holding one region per page, each region holding paragraphs and
/// headings whose text hangs off staticText children.
final class ReaderAccessibilityExtractorTests: XCTestCase {

    private func node(_ id: Int,
                      _ role: String,
                      name: String? = nil,
                      level: Int? = nil,
                      children: [Int] = []) -> [String: Any] {
        var dict: [String: Any] = ["id": id, "role": role, "children": children]
        if let name { dict["name"] = name }
        if let level { dict["level"] = level }
        return dict
    }

    private func snapshot(_ nodes: [[String: Any]], rootId: Int = 1) -> [String: Any] {
        ["rootId": rootId, "nodes": nodes]
    }

    /// Long enough to clear the extractor's minimum-length gate.
    private let bodyText = String(repeating: "Sample sentence about the topic. ", count: 12)

    // MARK: - Structure

    func testBuildsParagraphsAndHeadingsFromAPDFStylePageTree() throws {
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "region", name: "Page 1", children: [3, 5]),
                node(3, "heading", level: 3, children: [4]),
                node(4, "staticText", name: "Chapter One"),
                node(5, "paragraph", children: [6]),
                node(6, "staticText", name: bodyText),
            ]),
            fallbackTitle: "Report.pdf",
            sourceURL: "https://example.com/report.pdf")

        XCTAssertEqual(article.rung, "accessibility")
        XCTAssertEqual(article.title, "Report.pdf")
        XCTAssertTrue(article.contentHTML.contains("<h3>Chapter One</h3>"))
        XCTAssertTrue(article.contentHTML.contains("<p>"))
        XCTAssertTrue(article.contentHTML.contains("Sample sentence"))
    }

    func testKeepsDocumentOrderAcrossPages() throws {
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2, 5]),
                node(2, "region", name: "Page 1", children: [3]),
                node(3, "paragraph", children: [4]),
                node(4, "staticText", name: "First. " + bodyText),
                node(5, "region", name: "Page 2", children: [6]),
                node(6, "paragraph", children: [7]),
                node(7, "staticText", name: "Second."),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        let first = try XCTUnwrap(article.contentHTML.range(of: "First."))
        let second = try XCTUnwrap(article.contentHTML.range(of: "Second."))
        XCTAssertTrue(first.lowerBound < second.lowerBound,
                      "pages must render in reading order")
    }

    func testIgnoresInlineTextBoxesSoWordsAreNotDuplicated() throws {
        // PDFium hangs inlineTextBox children off staticText that repeat the
        // same words; counting both doubles every sentence.
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "paragraph", children: [3]),
                node(3, "staticText", name: bodyText, children: [4, 5]),
                node(4, "inlineTextBox", name: bodyText),
                node(5, "inlineTextBox", name: bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        let occurrences = article.contentHTML.components(
            separatedBy: "Sample sentence about the topic.").count - 1
        XCTAssertEqual(occurrences, 12, "text must appear once, not once per box")
    }

    // MARK: - Filtering

    func testDropsTheOCRStatusBannerAndFooter() throws {
        // The PDF OCR markers live under banner/contentInfo and must not read
        // as article content.
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2, 4, 6]),
                node(2, "banner", children: [3]),
                node(3, "staticText", name: "Beginning of PDF"),
                node(4, "paragraph", children: [5]),
                node(5, "staticText", name: bodyText),
                node(6, "contentInfo", children: [7]),
                node(7, "staticText", name: "End of PDF"),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        XCTAssertFalse(article.contentHTML.contains("Beginning of PDF"))
        XCTAssertFalse(article.contentHTML.contains("End of PDF"))
        XCTAssertTrue(article.contentHTML.contains("Sample sentence"))
    }

    func testEscapesMarkupInExtractedText() throws {
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "paragraph", children: [3]),
                node(3, "staticText", name: "<script>alert(1)</script> " + bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        XCTAssertFalse(article.contentHTML.contains("<script>"))
        XCTAssertTrue(article.contentHTML.contains("&lt;script&gt;"))
    }

    // MARK: - Reflow cleanup

    func testRejoinsWordsBrokenBySoftHyphenAtALineEnd() throws {
        // A PDF hyphenates across line breaks. The marker is invisible in the
        // fixed page but lands mid-word once reflowed, rendering as a
        // missing-glyph box. Dropping it restores the word.
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "paragraph", children: [3]),
                node(3, "staticText", name: "techniques for scalability and relia\u{00AD}bility now in use. " + bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        XCTAssertTrue(article.contentHTML.contains("reliability"))
        XCTAssertFalse(article.contentHTML.contains("\u{00AD}"))
    }

    func testKeepsRealHyphensInCompoundWords() throws {
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "paragraph", children: [3]),
                node(3, "staticText", name: "the earliest multi-user server systems. " + bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")
        XCTAssertTrue(article.contentHTML.contains("multi-user"))
    }

    func testDropsUnmappedAndControlCharacters() throws {
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "paragraph", children: [3]),
                node(3, "staticText",
                     name: "text\u{FFFD}with\u{0001}junk\u{200B}here. " + bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        XCTAssertTrue(article.contentHTML.contains("textwithjunkhere"))
        for bad in ["\u{FFFD}", "\u{0001}", "\u{200B}"] {
            XCTAssertFalse(article.contentHTML.contains(bad),
                           "expected \(bad.unicodeScalars.first!) to be stripped")
        }
    }

    // MARK: - Figures

    func testEmitsACaptionedPlaceholderForDescribedImages() throws {
        // The tree carries an image's description and reading position but not
        // its pixels, so the caption stands in for the figure.
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2, 3]),
                node(2, "image", name: "Figure 1: system architecture"),
                node(3, "paragraph", children: [4]),
                node(4, "staticText", name: bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        XCTAssertTrue(article.contentHTML.contains("phi-figure-placeholder"))
        XCTAssertTrue(article.contentHTML.contains("Figure 1: system architecture"))
    }

    func testDoesNotReadAnImageDescriptionAsPageText() throws {
        // A PDF image with no alt text is given a synthesised description by
        // the platform — "Unlabeled image", and localised, so it cannot be
        // filtered by matching the string. A header logo repeated on every
        // page turns that into a paragraph per page.
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2, 4]),
                node(2, "paragraph", children: [3]),
                node(3, "image", name: "Unlabeled image"),
                node(4, "paragraph", children: [5]),
                node(5, "staticText", name: bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        XCTAssertFalse(article.contentHTML.contains("Unlabeled image"))
        XCTAssertTrue(article.contentHTML.contains("Sample sentence"))
    }

    func testKeepsTextSittingBesideAnImageInTheSameBlock() throws {
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "paragraph", children: [3, 4]),
                node(3, "image", name: "Unlabeled image"),
                node(4, "staticText", name: bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        XCTAssertFalse(article.contentHTML.contains("Unlabeled image"))
        XCTAssertTrue(article.contentHTML.contains("Sample sentence"))
    }

    func testDropsAFigureWhoseCaptionRepeatsAcrossPages() throws {
        // A running header logo: the same image on every page. Its caption
        // repeating is what marks it as furniture rather than a figure.
        var nodes: [[String: Any]] = []
        var pageIds: [Int] = []
        var nextId = 2
        for page in 0..<4 {
            let region = nextId; nextId += 1
            let logo = nextId; nextId += 1
            let para = nextId; nextId += 1
            let text = nextId; nextId += 1
            nodes.append(node(region, "region", name: "Page \(page + 1)",
                              children: [logo, para]))
            nodes.append(node(logo, "image", name: "Unlabeled image"))
            nodes.append(node(para, "paragraph", children: [text]))
            nodes.append(node(text, "staticText", name: bodyText))
            pageIds.append(region)
        }
        nodes.insert(node(1, "pdfRoot", children: pageIds), at: 0)

        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot(nodes), fallbackTitle: "Doc", sourceURL: "")

        XCTAssertFalse(article.contentHTML.contains("phi-figure-placeholder"))
        XCTAssertFalse(article.contentHTML.contains("Unlabeled image"))
        XCTAssertTrue(article.contentHTML.contains("Sample sentence"))
    }

    func testKeepsFiguresWhoseCaptionsAreDistinct() throws {
        // Three different figures must survive: it is repetition that marks
        // furniture, not the number of images.
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2, 3, 4, 5]),
                node(2, "image", name: "Figure 1: the approach march"),
                node(3, "image", name: "Figure 2: the siege"),
                node(4, "image", name: "Figure 3: the retreat"),
                node(5, "paragraph", children: [6]),
                node(6, "staticText", name: bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")

        for caption in ["Figure 1", "Figure 2", "Figure 3"] {
            XCTAssertTrue(article.contentHTML.contains(caption), "lost \(caption)")
        }
    }

    func testSkipsImagesThatCarryNoDescription() throws {
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2, 3]),
                node(2, "image"),
                node(3, "paragraph", children: [4]),
                node(4, "staticText", name: bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")
        XCTAssertFalse(article.contentHTML.contains("phi-figure-placeholder"))
    }

    // MARK: - Rejection

    func testRejectsATreeWithTooLittleText() {
        XCTAssertThrowsError(
            try ReaderAccessibilityExtractor.article(
                from: snapshot([
                    node(1, "pdfRoot", children: [2]),
                    node(2, "paragraph", children: [3]),
                    node(3, "staticText", name: "Page 1 of 9"),
                ]),
                fallbackTitle: "Doc",
                sourceURL: "")
        ) { error in
            guard case ReaderExtractionError.noArticleDetected = error else {
                return XCTFail("expected noArticleDetected, got \(error)")
            }
        }
    }

    func testRejectsAnEmptySnapshot() {
        XCTAssertThrowsError(
            try ReaderAccessibilityExtractor.article(
                from: ["rootId": 1, "nodes": []],
                fallbackTitle: "Doc",
                sourceURL: "")
        ) { error in
            guard case ReaderExtractionError.noArticleDetected = error else {
                return XCTFail("expected noArticleDetected, got \(error)")
            }
        }
    }

    func testSurvivesACyclicTreeWithoutHanging() throws {
        // Defensive: a malformed tree must not spin the walk forever.
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "region", children: [3, 1]),
                node(3, "paragraph", children: [4]),
                node(4, "staticText", name: bodyText),
            ]),
            fallbackTitle: "Doc",
            sourceURL: "")
        XCTAssertTrue(article.contentHTML.contains("Sample sentence"))
    }

    func testFallsBackToTheFirstHeadingWhenTheTabHasNoTitle() throws {
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2, 4]),
                node(2, "heading", level: 2, children: [3]),
                node(3, "staticText", name: "Annual Review"),
                node(4, "paragraph", children: [5]),
                node(5, "staticText", name: bodyText),
            ]),
            fallbackTitle: "   ",
            sourceURL: "")
        XCTAssertEqual(article.title, "Annual Review")
    }

    func testDoesNotRepeatAHeadingThatNamesItself() throws {
        // A container's accessibility name is computed from its descendants,
        // so on an HTML page a heading arrives named "Comments Section" *and*
        // owning a staticText child that says the same. Reddit labels its
        // comment area with a screen-reader-only <h1> shaped exactly like
        // this, and the reader printed "Comments Section Comments Section".
        let article = try ReaderAccessibilityExtractor.article(
            from: snapshot([
                node(1, "pdfRoot", children: [2]),
                node(2, "region", name: "Page 1", children: [3, 5]),
                node(3, "heading", name: "Comments Section", level: 2,
                     children: [4]),
                node(4, "staticText", name: "Comments Section"),
                node(5, "paragraph", children: [6]),
                node(6, "staticText", name: bodyText),
            ]),
            fallbackTitle: "Thread",
            sourceURL: "https://example.com/thread")

        XCTAssertTrue(article.contentHTML.contains("<h2>Comments Section</h2>"))
        XCTAssertEqual(
            article.contentHTML.components(separatedBy: "Comments Section").count - 1,
            1,
            "the heading was emitted more than once")
    }
}
