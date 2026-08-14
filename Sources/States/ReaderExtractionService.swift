// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// A distilled article, ready for presentation.
struct ReaderArticle: Equatable {
    let title: String
    let byline: String?
    let siteName: String?
    let lang: String?
    /// Sanitised, URL-absolutised article markup. Rendered with scripting
    /// disabled, so this is trusted only as inert markup.
    let contentHTML: String
    let sourceURL: String
    /// Which rung of the ladder produced this — "rule", "readability", or
    /// "structural". Carried for diagnostics and future rule tuning.
    let rung: String
    /// Extracted text as a fraction of the page's total visible text.
    let coverage: Double
    /// The text of each `<pre>` in `contentHTML`, in document order, indexed
    /// by the `data-phi-code` attribute on that element. Taken from the live
    /// DOM during extraction because syntax highlighting shreds a sample into
    /// nested spans that cannot be reassembled reliably from markup.
    var codeBlocks: [String] = []
    /// False while more of the document is still being captured. Only the
    /// accessibility path produces partial articles; the DOM path always has
    /// the whole page in hand.
    var isComplete: Bool = true
    /// Pages captured so far, for the "still loading" affordance. Nil outside
    /// the paginated (PDF) path.
    var pageCount: Int?
}

enum ReaderExtractionError: Error {
    /// The tab has no live WebContents, or the framework predates
    /// `devToolsTargetId`.
    case noTarget
    /// The DevTools injection transport is not running, or the page target is
    /// stale.
    case transportUnavailable
    /// Bundled extraction scripts are missing from Resources.
    case scriptUnavailable
    /// Every rung declined; the page is not an article.
    case noArticleDetected
    /// Something extracted, but too little of the page to be a real article.
    case belowCoverageFloor(best: Double)
    case failed(String)
}

/// Extracts a readable article from a live tab.
///
/// Runs entirely in the client. The only framework dependency is
/// `WebContentWrapper.devToolsTargetId`; everything else goes through the
/// app-owned CDP session, which is unaffected by the AI or extension toggles.
@MainActor
final class ReaderExtractionService {

    static let shared = ReaderExtractionService()

    /// Extracted text must be at least this fraction of the page's visible
    /// text to be accepted.
    ///
    /// This is the fix for the truncation mode that every reader mode shares:
    /// Readability declares success at an absolute 500 characters, so a long
    /// article that extracted a few hundred characters is reported as fine.
    /// Measuring against the page instead catches that.
    ///
    /// Provisional. It should be derived from a fixture corpus rather than
    /// chosen — see the design's open questions. Kept deliberately permissive
    /// so that a legitimately short article on a link-heavy page still passes;
    /// because the best rung is taken, this only fails when every rung is bad.
    static let coverageFloor: Double = 0.15

    /// Ceiling for the in-page preparation step (expanding sections, waiting
    /// for lazy content). Extraction proceeds with whatever has loaded.
    private static let prepareBudgetMs = 1500

    /// Ceiling for waiting out a page that is still loading when the reader is
    /// asked for. Zero on a page that has already fired `load`, which is the
    /// usual case; it only spends anything when the button is pressed during
    /// the load, and that is the case it exists to rescue.
    private static let readyBudgetMs = 3000

    private init() {}

    /// Whether the reader could conceivably have anything to offer for this
    /// URL — the fast gate under `isReaderWorthOffering`, and the whole test
    /// for surfaces that cannot wait for a probe (the Chromium context menu
    /// mirrors it).
    ///
    /// A PDF is excluded because extraction now declines one, and a button
    /// whose only outcome is "Reader View is unavailable on this page" is
    /// worse than no button.
    ///
    /// The path extension is the only URL-side signal the client has: a tab's
    /// content type does not cross the bridge. So a PDF served from a URL
    /// that does not end in .pdf still passes here, and still refuses when
    /// pressed — the refusal is the guarantee, this is only the tidying.
    nonisolated static func canOfferReader(forURLString urlString: String?) -> Bool {
        guard let urlString, !urlString.isEmpty, !urlString.isLocalUrlString,
              let url = URL(string: urlString) else {
            return false
        }
        return url.pathExtension.lowercased() != "pdf"
    }

    /// Whether the address bar should draw its reader button for this tab.
    ///
    /// Two signals past the URL gate, either sufficient:
    ///
    /// - a site rule matches, which covers exactly the pages the heuristic
    ///   below misreads: paulgraham.com writes paragraphs as `<br><br>` with
    ///   no `<p>` to count, Google Docs paints into a canvas, and a thread
    ///   page is many short posts rather than one article
    /// - Mozilla's `isProbablyReaderable` passes in the live page, which
    ///   covers the long tail of sites nobody has written a rule for
    ///
    /// Only the button consults this. The View menu, the shortcut, and the
    /// page context menu stay unconditional, so a wrong "no" here costs one
    /// affordance rather than the feature: extraction's own refusal remains
    /// the authority on what can actually be read.
    func isReaderWorthOffering(for tab: Tab) async -> Bool {
        guard Self.canOfferReader(forURLString: tab.url) else { return false }
        if ReaderSiteRuleStore.shared.rule(forURLString: tab.url) != nil {
            return true
        }
        return await probeIsProbablyReaderable(tab: tab)
    }

    /// Mozilla's readerability heuristic plus Phi's supplements — see
    /// `ReaderProbe.js` for why the stock answer alone under-reports what the
    /// ladder reads. Wrapped to always resolve: a page that throws inside the
    /// probe counts as readerable, because the failure is ours, not evidence
    /// about the page, and a refusal on press is the cheaper mistake.
    private static let readerableExpression: String? = {
        guard let readerable = try? loadScript(named: "Readability-readerable"),
              let probe = try? loadScript(named: "ReaderProbe") else {
            return nil
        }
        return """
        (function() {
        \(readerable)
        \(probe)
        try { return __phiIsProbablyReaderable(document); } catch (e) { return true; }
        })()
        """
    }()

    /// Asks the live page whether it probably holds an article.
    ///
    /// Failure shapes split by what they say about the page: no DevTools
    /// target means there is no page to read (native surfaces) — nothing to
    /// offer. Everything after that point — transport down, evaluate failed,
    /// missing script — is our machinery failing, so the answer falls back
    /// to "offer it" and the press-time refusal keeps the truth.
    private func probeIsProbablyReaderable(tab: Tab) async -> Bool {
        guard let wrapper = tab.webContentWrapper,
              let targetId = wrapper.devToolsTargetId,
              !targetId.isEmpty else {
            return false
        }
        guard let expression = Self.readerableExpression else { return true }

        guard let session = try? await AppDevToolsPageSession.open(targetId: targetId) else {
            return true
        }
        defer { session.close() }

        guard let reply = try? await session.command(
            "Runtime.evaluate",
            params: ["expression": expression, "returnByValue": true],
            timeout: 10) else {
            return true
        }
        guard reply["exceptionDetails"] == nil,
              let value = (reply["result"] as? [String: Any])?["value"] as? Bool else {
            return true
        }
        return value
    }

    /// Extracts an article, walking the page first unless told not to.
    ///
    /// `settlingLazyContent` is false for the pass that opens the reader,
    /// because the walk moves the live page under the user and there is
    /// nothing on screen yet to hide it. Callers with no user watching — the
    /// agent API, the pass that runs behind the open reader — leave it on.
    func extract(from tab: Tab,
                 settlingLazyContent: Bool = true) async throws -> ReaderArticle {
        do {
            let article = try await extractFromDOM(
                tab: tab, settlingLazyContent: settlingLazyContent)
            AppLogDebug("[Reader] DOM path succeeded rung=\(article.rung) " +
                        "coverage=\(article.coverage)")
            return article
        } catch {
            // The accessibility tree is the only route into a PDF, and it also
            // rescues HTML whose markup defeats every DOM rung. Falling back on
            // any DOM-side miss keeps that one path instead of two.
            let canFallBack = Self.shouldFallBackToAccessibility(after: error)
            AppLogDebug("[Reader] DOM path failed: \(error) " +
                        "accessibilityFallback=\(canFallBack)")
            guard canFallBack else {
                throw error
            }
            let article = try await extractFromAccessibilityTree(tab: tab)
            AppLogDebug("[Reader] accessibility path produced " +
                        "pages=\(article.pageCount ?? -1) " +
                        "complete=\(article.isComplete)")
            return article
        }
    }

    /// Whether a DOM-side miss is worth a second attempt through the
    /// accessibility tree.
    ///
    /// A PDF is deliberately excluded, which means Reader View declines every
    /// PDF: the accessibility tree was the only route into one, so refusing it
    /// here turns the feature off for them.
    ///
    /// The reader could read a PDF, but not well enough to be worth offering.
    /// The tree arrives a page at a time, so a long document opened at five
    /// pages and rewrote itself underneath the reader as the rest landed; text
    /// came reflowed with the hyphenation of a fixed layout still in it;
    /// figures became captions rather than pictures, and a logo repeated in a
    /// page header became a paragraph of "Unlabeled image" until that was
    /// fixed specially. Each of those was a fix on its own, and the result was
    /// still worse than the PDF viewer the tab already has.
    private static func shouldFallBackToAccessibility(after error: Error) -> Bool {
        switch error {
        case ReaderExtractionError.noArticleDetected,
             ReaderExtractionError.belowCoverageFloor:
            return true
        default:
            // A PDF, no target, or no transport: nothing the fallback can fix.
            return false
        }
    }

    // MARK: - Accessibility path

    /// Pages captured before the reader opens. A long PDF builds its tree page
    /// by page, so waiting for all of it would stall the reader for seconds;
    /// this is enough to start reading while the rest is captured behind it.
    static let initialPageCount = 5
    private static let initialCaptureTimeoutMs = 6000
    private static let fullCaptureTimeoutMs = 60000

    func extractFromAccessibilityTree(tab: Tab,
                                      minimumPages: Int,
                                      timeoutMs: Int) async throws -> ReaderArticle {
        guard let wrapper = tab.webContentWrapper else {
            throw ReaderExtractionError.noTarget
        }
        let snapshot: [String: Any]? = await withCheckedContinuation { continuation in
            wrapper.requestAccessibilityTreeSnapshot(
                withMinimumPages: minimumPages,
                timeoutMs: timeoutMs) { result in
                    continuation.resume(returning: result)
                }
        }
        guard let snapshot else {
            throw ReaderExtractionError.noArticleDetected
        }
        var article = try ReaderAccessibilityExtractor.article(
            from: snapshot,
            fallbackTitle: tab.title,
            sourceURL: tab.url ?? "")
        article.isComplete = snapshot["complete"] as? Bool ?? true
        article.pageCount = snapshot["pageCount"] as? Int
        return article
    }

    private func extractFromAccessibilityTree(tab: Tab) async throws -> ReaderArticle {
        try await extractFromAccessibilityTree(
            tab: tab,
            minimumPages: Self.initialPageCount,
            timeoutMs: Self.initialCaptureTimeoutMs)
    }

    /// Captures the whole document, for the pass that runs behind the reader
    /// once the first pages are on screen.
    func extractCompleteAccessibilityArticle(tab: Tab) async throws -> ReaderArticle {
        try await extractFromAccessibilityTree(
            tab: tab,
            minimumPages: 0,
            timeoutMs: Self.fullCaptureTimeoutMs)
    }

    // MARK: - DOM path

    /// Re-extracts with the page walk, for the pass that runs behind an open
    /// reader. DOM-only on purpose: the first pass already decided whether
    /// this document has a DOM to read, and the accessibility path has its own
    /// second pass in `extractCompleteAccessibilityArticle`.
    func extractSettledArticle(from tab: Tab) async throws -> ReaderArticle {
        try await extractFromDOM(tab: tab, settlingLazyContent: true)
    }

    private func extractFromDOM(tab: Tab,
                                settlingLazyContent: Bool) async throws -> ReaderArticle {
        guard let wrapper = tab.webContentWrapper,
              let targetId = wrapper.devToolsTargetId,
              !targetId.isEmpty else {
            throw ReaderExtractionError.noTarget
        }

        let rule = ReaderSiteRuleStore.shared.rule(forURLString: tab.url)
        if let rule {
            AppLogDebug("[Reader] using site rule for \(rule.host)")
        }
        // A thread rule never wants the page walked. Walking exists to make a
        // lazy-loader fill in content, but a virtualised timeline does the
        // opposite: scrolling unmounts the posts already in the DOM to mount
        // later ones. On an x.com status page the walk turned 25 posts
        // starting at the opening tweet into 19 starting from the middle of
        // the thread. A thread rule has named its posts explicitly, so there
        // is nothing for the walk to discover and everything for it to lose.
        let settle = settlingLazyContent && rule?.thread == nil
        let expression = try Self.makeExpression(
            rule: rule, settlingLazyContent: settle)

        let session: AppDevToolsPageSession
        do {
            session = try await AppDevToolsPageSession.open(targetId: targetId)
        } catch {
            throw ReaderExtractionError.transportUnavailable
        }
        defer { session.close() }

        let reply: [String: Any]
        do {
            reply = try await session.command(
                "Runtime.evaluate",
                params: ["expression": expression,
                         "awaitPromise": true,
                         "returnByValue": true],
                // Covers the preparation budget plus serialisation of a long
                // article, with headroom over the script's own deadline.
                timeout: 30)
        } catch {
            throw ReaderExtractionError.failed("evaluate_failed")
        }

        if reply["exceptionDetails"] != nil {
            throw ReaderExtractionError.failed("script_exception")
        }
        guard let payload = (reply["result"] as? [String: Any])?["value"]
                as? [String: Any] else {
            throw ReaderExtractionError.failed("unreadable_result")
        }
        // "interactive" here means the reader was asked for mid-load and the
        // wait timed out, which is the shape most likely to extract badly.
        AppLogDebug("[Reader] page readyState=" +
                    "\(payload["readyState"] as? String ?? "unknown") " +
                    "visibility=\(payload["visibilityState"] as? String ?? "unknown") " +
                    "walked=\(settle)")

        return try Self.article(from: payload, fallbackURL: tab.url ?? "")
    }

    // MARK: - Result handling

    /// Applies the coverage gate and picks a winner.
    ///
    /// Coverage is a floor, never something to maximise.
    ///
    /// Maximising it rewards over-capture: a rung that swallows the comment
    /// thread, the breadcrumb, and the next-article links scores higher than
    /// one that correctly isolates the article, because coverage only measures
    /// volume. So the floor rejects truncation, and among the rungs that clear
    /// it the earliest wins — ladder order is precision order, from an
    /// explicit site rule down to the crude structural fallback.
    ///
    /// A truncated rung cannot clear a floor expressed relative to the page,
    /// which is what makes "first past the floor" safe here even though it
    /// would not be against Readability's absolute character threshold.
    ///
    /// A site rule is exempt from the floor. The floor guards against *generic*
    /// extraction failing quietly; a rule is a person's verified assertion
    /// about one site, and the ratio it produces says as much about the page
    /// as about the extraction. On a Substack post the surrounding archive and
    /// recommendation rails are several times the length of the article, so a
    /// correct rule scores 0.14 and the rung that swallows the whole page
    /// scores 1.0 — applying the floor there rejects the right answer in
    /// favour of the wrong one. The rule rung still has to clear the script's
    /// own minimum length, so an empty or broken selector declines rather than
    /// winning by exemption.
    ///
    /// Internal rather than private so the gate can be tested without a live
    /// page; it is not called from anywhere else.
    static func article(from payload: [String: Any],
                        fallbackURL: String) throws -> ReaderArticle {
        guard payload["ok"] as? Bool == true else {
            let reason = payload["reason"] as? String ?? "unknown"
            throw reason == "no_article_detected"
                ? ReaderExtractionError.noArticleDetected
                : ReaderExtractionError.failed(reason)
        }

        let attempts = payload["attempts"] as? [[String: Any]] ?? []
        guard !attempts.isEmpty else {
            throw ReaderExtractionError.noArticleDetected
        }

        // Kept in ladder order: rule, then Readability, then structural.
        let usable = attempts
            .compactMap { attempt -> (attempt: [String: Any], coverage: Double)? in
                guard let html = attempt["contentHTML"] as? String,
                      !html.isEmpty else { return nil }
                return (attempt, attempt["coverage"] as? Double ?? 0)
            }

        guard !usable.isEmpty else {
            throw ReaderExtractionError.noArticleDetected
        }
        guard let winner = usable.first(where: {
            ($0.attempt["rung"] as? String) == "rule" || $0.coverage >= coverageFloor
        }) else {
            let best = usable.map(\.coverage).max() ?? 0
            throw ReaderExtractionError.belowCoverageFloor(best: best)
        }

        let attempt = winner.attempt
        let title = (attempt["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ReaderArticle(
            title: title,
            byline: nonEmpty(attempt["byline"] as? String),
            siteName: nonEmpty(attempt["siteName"] as? String),
            lang: nonEmpty(attempt["lang"] as? String)
                ?? nonEmpty(payload["lang"] as? String),
            contentHTML: attempt["contentHTML"] as? String ?? "",
            sourceURL: nonEmpty(payload["url"] as? String) ?? fallbackURL,
            rung: attempt["rung"] as? String ?? "unknown",
            coverage: winner.coverage,
            codeBlocks: attempt["codeBlocks"] as? [String] ?? [])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Script assembly

    /// Readability declares `function Readability` at the top level, so
    /// wrapping both scripts in one IIFE puts it in scope for the extractor
    /// without leaking a global into the page.
    private static func makeExpression(rule: ReaderSiteRule?,
                                       settlingLazyContent: Bool) throws -> String {
        let readability = try loadScript(named: "Readability")
        let extractor = try loadScript(named: "ReaderExtract")

        // `rule` is absent for most pages, and the script's rule rung simply
        // declines when it is, leaving Readability first in the ladder.
        var config: [String: Any] = ["prepareBudgetMs": prepareBudgetMs,
                                     "readyBudgetMs": readyBudgetMs,
                                     "skipLazySettle": !settlingLazyContent]
        if let rule, let encoded = try? JSONEncoder().encode(rule),
           let object = try? JSONSerialization.jsonObject(with: encoded) {
            config["rule"] = object
        }
        let configJSON = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return """
        (function() {
        \(readability)
        \(extractor)
        return window.__phiReaderExtract(\(configJSON));
        })()
        """
    }

    private static func loadScript(named name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw ReaderExtractionError.scriptUnavailable
        }
        return source
    }
}
