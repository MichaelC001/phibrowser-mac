// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Tests for the Reader View coverage gate — the policy that decides whether
/// an extraction is a real article or a truncated one.
///
/// This is the fix for the failure mode every reader mode shares: Readability
/// reports success at an absolute 500 characters, so a long article that
/// extracted a few hundred characters is accepted. The gate measures against
/// the page instead, and takes the best rung rather than the first that
/// cleared a floor. Extraction itself runs in the page and is covered by the
/// fixture corpus, not here.
@MainActor
final class ReaderCoverageGateTests: XCTestCase {

    private func attempt(rung: String,
                         coverage: Double,
                         html: String = "<p>body</p>",
                         title: String = "Title",
                         byline: String? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "rung": rung,
            "coverage": coverage,
            "contentHTML": html,
            "title": title,
            "extractedLength": 1000,
        ]
        if let byline {
            dict["byline"] = byline
        }
        return dict
    }

    private func payload(_ attempts: [[String: Any]],
                         url: String = "https://example.com/a") -> [String: Any] {
        ["ok": true, "url": url, "visibleTextLength": 5000, "attempts": attempts]
    }

    // MARK: - Rung selection

    func testPrefersTheEarliestRungThatClearsTheFloor() throws {
        // Ladder order is precision order, so a rule that clears the floor
        // beats a later rung that merely captured more.
        let article = try ReaderExtractionService.article(
            from: payload([
                attempt(rung: "rule", coverage: 0.20, html: "<p>precise</p>"),
                attempt(rung: "readability", coverage: 0.65, html: "<p>broader</p>"),
                attempt(rung: "structural", coverage: 0.90),
            ]),
            fallbackURL: "")

        XCTAssertEqual(article.rung, "rule")
        XCTAssertEqual(article.contentHTML, "<p>precise</p>")
    }

    func testSkipsAnEarlyRungThatFellBelowTheFloor() throws {
        // Truncation still loses: a rung under the floor is passed over for
        // the next one that clears it.
        let article = try ReaderExtractionService.article(
            from: payload([
                attempt(rung: "readability", coverage: 0.03, html: "<p>truncated</p>"),
                attempt(rung: "structural", coverage: 0.55, html: "<p>whole</p>"),
            ]),
            fallbackURL: "")

        XCTAssertEqual(article.rung, "structural")
        XCTAssertEqual(article.contentHTML, "<p>whole</p>")
    }

    func testASiteRuleIsExemptFromTheFloor() throws {
        // Coverage is a ratio against the whole page, so on a site whose
        // article is a small fraction of what is rendered — a Substack post
        // under its archive and recommendation rails — a correct rule scores
        // below the floor while the rung that swallows everything scores 1.0.
        // A rule is a person's verified assertion about one site, so it is
        // trusted over a ratio that is measuring the page more than the
        // extraction.
        let article = try ReaderExtractionService.article(
            from: payload([
                attempt(rung: "rule", coverage: 0.14, html: "<p>the article</p>"),
                attempt(rung: "structural", coverage: 1.0,
                        html: "<p>article plus the whole archive</p>"),
            ]),
            fallbackURL: "")

        XCTAssertEqual(article.rung, "rule")
        XCTAssertFalse(article.contentHTML.contains("archive"))
    }

    func testDoesNotRewardOverCapture() throws {
        // The failure this rule exists to prevent: a rung that swallowed the
        // comment thread and the article-to-article navigation scores highest
        // on coverage precisely because it took too much, and must not win
        // over the rung that isolated the article.
        let article = try ReaderExtractionService.article(
            from: payload([
                attempt(rung: "readability", coverage: 0.45,
                        html: "<p>just the article</p>"),
                attempt(rung: "structural", coverage: 0.98,
                        html: "<p>article plus comments plus nav</p>"),
            ]),
            fallbackURL: "")

        XCTAssertEqual(article.rung, "readability")
        XCTAssertFalse(article.contentHTML.contains("comments"))
    }

    func testAcceptsSingleRungAtTheFloor() throws {
        let article = try ReaderExtractionService.article(
            from: payload([attempt(rung: "rule",
                                   coverage: ReaderExtractionService.coverageFloor)]),
            fallbackURL: "")
        XCTAssertEqual(article.rung, "rule")
    }

    // MARK: - Rejection

    func testRejectsWhenEveryRungIsBelowTheFloor() {
        // The truncation case: something extracted, but a sliver of the page.
        // No rule rung here, because a rule is exempt from the floor.
        XCTAssertThrowsError(
            try ReaderExtractionService.article(
                from: payload([
                    attempt(rung: "structural", coverage: 0.02),
                    attempt(rung: "readability", coverage: 0.04),
                ]),
                fallbackURL: "")
        ) { error in
            guard case ReaderExtractionError.belowCoverageFloor(let best) = error else {
                return XCTFail("expected belowCoverageFloor, got \(error)")
            }
            // Reports the best seen, not the last tried.
            XCTAssertEqual(best, 0.04, accuracy: 0.0001)
        }
    }

    func testRejectsEmptyAttemptList() {
        XCTAssertThrowsError(
            try ReaderExtractionService.article(from: payload([]), fallbackURL: "")
        ) { error in
            guard case ReaderExtractionError.noArticleDetected = error else {
                return XCTFail("expected noArticleDetected, got \(error)")
            }
        }
    }

    func testIgnoresAttemptsWithEmptyMarkup() {
        // A rung can report a high coverage number alongside no usable markup;
        // it must not be selected on the strength of the number alone.
        XCTAssertThrowsError(
            try ReaderExtractionService.article(
                from: payload([attempt(rung: "structural", coverage: 0.9, html: "")]),
                fallbackURL: "")
        ) { error in
            guard case ReaderExtractionError.noArticleDetected = error else {
                return XCTFail("expected noArticleDetected, got \(error)")
            }
        }
    }

    func testPropagatesScriptSideFailure() {
        XCTAssertThrowsError(
            try ReaderExtractionService.article(
                from: ["ok": false, "reason": "no_article_detected"],
                fallbackURL: "")
        ) { error in
            guard case ReaderExtractionError.noArticleDetected = error else {
                return XCTFail("expected noArticleDetected, got \(error)")
            }
        }
    }

    func testDistinguishesRestrictedPageFromMissingArticle() {
        XCTAssertThrowsError(
            try ReaderExtractionService.article(
                from: ["ok": false, "reason": "no_document"],
                fallbackURL: "")
        ) { error in
            guard case ReaderExtractionError.failed(let reason) = error else {
                return XCTFail("expected failed, got \(error)")
            }
            XCTAssertEqual(reason, "no_document")
        }
    }

    // MARK: - Field mapping

    func testFallsBackToTabURLWhenScriptReportsNone() throws {
        var raw = payload([attempt(rung: "rule", coverage: 0.5)])
        raw.removeValue(forKey: "url")
        let article = try ReaderExtractionService.article(
            from: raw, fallbackURL: "https://fallback.example/x")
        XCTAssertEqual(article.sourceURL, "https://fallback.example/x")
    }

    func testBlankBylineBecomesNilRatherThanAnEmptyLine() throws {
        let article = try ReaderExtractionService.article(
            from: payload([attempt(rung: "rule", coverage: 0.5, byline: "   ")]),
            fallbackURL: "")
        XCTAssertNil(article.byline)
    }

    func testTrimsTitleWhitespace() throws {
        let article = try ReaderExtractionService.article(
            from: payload([attempt(rung: "rule", coverage: 0.5,
                                   title: "  Spaced Title \n")]),
            fallbackURL: "")
        XCTAssertEqual(article.title, "Spaced Title")
    }

    // MARK: - Whether to offer the reader at all

    func testDoesNotOfferTheReaderOnAPDF() {
        // Extraction declines a PDF, so a button there can only ever produce
        // "Reader View is unavailable on this page".
        XCTAssertFalse(ReaderExtractionService.canOfferReader(
            forURLString: "https://example.com/papers/report.pdf"))
        XCTAssertFalse(ReaderExtractionService.canOfferReader(
            forURLString: "https://example.com/papers/REPORT.PDF"))
        // A query or fragment must not hide the extension.
        XCTAssertFalse(ReaderExtractionService.canOfferReader(
            forURLString: "https://example.com/a.pdf?download=1#page=3"))
    }

    func testStillOffersTheReaderOnOrdinaryPages() {
        XCTAssertTrue(ReaderExtractionService.canOfferReader(
            forURLString: "https://example.com/blog/post"))
        // "pdf" as a word in the path is not a PDF.
        XCTAssertTrue(ReaderExtractionService.canOfferReader(
            forURLString: "https://example.com/how-to-read-pdf-files"))
        XCTAssertTrue(ReaderExtractionService.canOfferReader(
            forURLString: "https://example.com/pdf/guide"))
    }

    func testDoesNotOfferTheReaderWithoutARealPage() {
        XCTAssertFalse(ReaderExtractionService.canOfferReader(forURLString: nil))
        XCTAssertFalse(ReaderExtractionService.canOfferReader(forURLString: ""))
        XCTAssertFalse(ReaderExtractionService.canOfferReader(forURLString: "chrome://newtab/"))
    }
}
