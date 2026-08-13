// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

#if DEBUG
/// Development aid: `-phi-auto-reader` opens Reader View on the first content
/// tab shortly after it loads.
///
/// macOS refuses synthesized keystrokes without an Accessibility grant, so
/// without this there is no way to exercise Reader View unattended — which
/// matters most for the PDF path, where a capture takes seconds and has to be
/// watched end to end. Debug builds only.
private enum ReaderAutoTrigger {
    @MainActor static var hasFired = false
    static let launchArgument = "-phi-auto-reader"

    /// Optional `-phi-auto-reader-url <substring>`. Without it the trigger
    /// takes the first content tab, which on a machine with a restored
    /// session is whatever the previous run left open rather than the page
    /// under test.
    static var urlNeedle: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "\(launchArgument)-url"),
              index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

extension BrowserState {
    @MainActor
    func triggerAutoReaderIfRequested(for tab: Tab) {
        guard ProcessInfo.processInfo.arguments
                .contains(ReaderAutoTrigger.launchArgument),
              !ReaderAutoTrigger.hasFired,
              // Restoring a session shows every restored tab, so without this
              // the reader opens on whichever matching tab was restored first
              // and the tab on screen is left showing the live page — which
              // looks exactly like the reader having failed.
              tab.isActive,
              let url = tab.url, !url.isEmpty, !url.isLocalUrlString else {
            return
        }
        if let needle = ReaderAutoTrigger.urlNeedle, !url.contains(needle) {
            return
        }
        ReaderAutoTrigger.hasFired = true
        Task { @MainActor [weak self, weak tab] in
            // Let the PDF finish its own load before asking for the tree.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let tab else { return }
            self.toggleReaderView(for: tab)
        }
    }
}
#endif

extension BrowserState {

    /// Toggles Reader View for a tab. Entering extracts first, so a page that
    /// yields no article never leaves the tab in a half-entered state.
    @MainActor
    func toggleReaderView(for tab: Tab) {
        if tab.isReaderViewActive {
            exitReaderView(for: tab)
        } else {
            Task { await enterReaderView(for: tab) }
        }
    }

    /// Extracts the article and, on success, flips the tab into Reader View.
    ///
    /// The tab is never navigated: the underlying WebContents stays exactly
    /// where it was, which is what keeps the address bar, history, bookmarks,
    /// and sharing pointing at the real page.
    ///
    /// This first pass does not walk the page for lazy content. Walking is the
    /// one part of preparation with a visible cost — the page scrolls itself
    /// under the user, and the reader only appears once it has finished, so
    /// pressing the button read as "watch the page scroll, then get a reader".
    /// Whatever the walk would have recovered is picked up afterwards, behind
    /// the article, by `settleLazyContent(for:)`.
    @MainActor
    func enterReaderView(for tab: Tab) async {
        guard !tab.isReaderViewActive else { return }
        guard !tab.isReaderViewLoading else { return }

        // Deliberately not awaited. This extraction uses the corpus already
        // in hand; the check is so a browser left running for days does not
        // go stale between launches.
        ReaderSiteRuleStore.shared.refreshIfStale()

        tab.isReaderViewLoading = true
        defer { tab.isReaderViewLoading = false }

        do {
            let started = Date()
            let article = try await ReaderExtractionService.shared
                .extract(from: tab, settlingLazyContent: false)
            AppLogDebug("[Reader] extraction took " +
                        "\(Int(Date().timeIntervalSince(started) * 1000))ms")
            // The user can switch or close the tab while extraction runs.
            guard tab.webContentWrapper != nil else { return }
            // Set before the reader is shown: the content host reads it as it
            // mounts, to decide whether to leave the live page underneath.
            //
            // A thread rule is excluded because the walk is refused for one
            // anyway (see ReaderExtractionService): scheduling the pass would
            // re-extract the same article, adopt nothing, and hold a live page
            // rendering behind the reader for a second and a half to do it.
            let isThread = article.rung == "rule"
                && ReaderSiteRuleStore.shared.rule(forURLString: tab.url)?.thread != nil
            tab.isReaderSettling = article.isComplete
                && article.rung != "accessibility"
                && !isThread
            tab.readerArticle = article
            tab.isReaderViewActive = true
            if !article.isComplete {
                captureRemainingPages(for: tab)
            } else if tab.isReaderSettling {
                settleLazyContent(for: tab)
            }
        } catch {
            presentReaderFailure(error)
        }
    }

    /// Walks the page behind the open reader and adopts the result if the walk
    /// brought more of the article into the DOM.
    ///
    /// This is the half of preparation that the first pass skipped, because
    /// walking the page is visible: it scrolls the live page under the user,
    /// and the reader used to appear only once it had finished. Running it here
    /// puts it behind the article instead.
    ///
    /// It has to run while the page is still rendering. Walking works by making
    /// content intersect the viewport, and a hidden page runs no lifecycle
    /// updates for an IntersectionObserver to fire from — a Medium post walked
    /// while visible goes from 5 images to 30, and walked as a background tab
    /// gains nothing. `isReaderSettling` is what keeps the page mounted, and
    /// therefore rendering, for as long as this takes.
    ///
    /// A pass that found nothing new is discarded rather than swapped in, so
    /// the common case — most pages have no deferred content at all — never
    /// re-renders the reader.
    @MainActor
    private func settleLazyContent(for tab: Tab) {
        Task { [weak tab] in
            guard let tab else { return }
            let settled = try? await ReaderExtractionService.shared
                .extractSettledArticle(from: tab)
            // Released whatever happened, including the throwing paths: while
            // it is set, a live page is being composited behind the reader.
            tab.isReaderSettling = false
            guard let settled,
                  // Still reading the same article, extracted the same way.
                  tab.isReaderViewActive,
                  let shown = tab.readerArticle,
                  settled.sourceURL == shown.sourceURL,
                  settled.rung == shown.rung,
                  settled.contentHTML.count > shown.contentHTML.count else {
                return
            }
            AppLogDebug("[Reader] lazy settle grew the article by " +
                        "\(settled.contentHTML.count - shown.contentHTML.count) bytes")
            tab.readerArticle = settled
        }
    }

    /// How long an export will wait for the reader's content to stop growing.
    /// A backstop rather than an expectation: the walk is bounded by the
    /// preparation budget, and a 66-page PDF captures in a few seconds. It
    /// matches the full capture's own ceiling so the wait can never outlive
    /// the work it is waiting for.
    private static let readerFinalisationTimeout: TimeInterval = 60

    /// Waits until nothing is still being added to the reader's content.
    ///
    /// Two passes keep working after the reader opens: the page walk in
    /// `settleLazyContent(for:)`, and the rest of a paginated document in
    /// `captureRemainingPages(for:)`. Both replace the article when they land,
    /// so an export taken while one is running saves less than the reader is
    /// about to show — on a long PDF, the first five pages of a whole book.
    ///
    /// Returns immediately when nothing is pending, which is the usual case.
    ///
    /// - Parameter includingPagination: false for the original-page export,
    ///   whose MHTML is serialised from the live page and so does not depend on
    ///   the accessibility capture at all.
    @MainActor
    func awaitReaderContentFinal(for tab: Tab,
                                 includingPagination: Bool = true) async {
        guard !isReaderContentFinal(for: tab,
                                    includingPagination: includingPagination) else {
            return
        }
        let deadline = Date().addingTimeInterval(Self.readerFinalisationTimeout)
        while !isReaderContentFinal(for: tab,
                                    includingPagination: includingPagination),
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        AppLogDebug("[Reader] export waited for the content to settle")
    }

    /// Whether anything is still being added to the reader's content.
    ///
    /// Separate from the wait so a caller can tell the user *before* it blocks
    /// rather than after; leaving the reader clears both flags, which releases
    /// any wait in progress.
    @MainActor
    func isReaderContentFinal(for tab: Tab,
                              includingPagination: Bool = true) -> Bool {
        if tab.isReaderSettling { return false }
        guard includingPagination, let article = tab.readerArticle else {
            return true
        }
        return article.isComplete
    }

    /// Captures the rest of a long document behind the open reader.
    ///
    /// The first pages are already on screen by the time this runs, so the
    /// wait costs the reader nothing. The result replaces the partial article,
    /// which re-renders the reader surface.
    @MainActor
    private func captureRemainingPages(for tab: Tab) {
        Task { [weak tab] in
            guard let tab else { return }
            let full = try? await ReaderExtractionService.shared
                .extractCompleteAccessibilityArticle(tab: tab)
            guard let full,
                  // Still reading the same document, and the full capture
                  // really did find more than the partial one.
                  tab.isReaderViewActive,
                  let partial = tab.readerArticle,
                  full.sourceURL == partial.sourceURL,
                  full.contentHTML.count > partial.contentHTML.count else {
                return
            }
            tab.readerArticle = full
        }
    }

    @MainActor
    func exitReaderView(for tab: Tab) {
        guard tab.isReaderViewActive else { return }
        tab.isReaderViewActive = false
        tab.readerArticle = nil
        tab.isReaderSettling = false
    }

    /// Leaves Reader View for every tab that is in it. Used when a window-wide
    /// change makes the reader surface stale.
    @MainActor
    func exitReaderViewForAllTabs() {
        for tab in tabs where tab.isReaderViewActive {
            exitReaderView(for: tab)
        }
    }

    @MainActor
    private func presentReaderFailure(_ error: Error) {
        let title: String
        switch error {
        case ReaderExtractionError.noArticleDetected,
             ReaderExtractionError.belowCoverageFloor:
            title = NSLocalizedString(
                "browser.readerView.noArticleFound",
                value: "No article found on this page",
                comment: "Reader View - Toast shown when the page has no article content to display")
        default:
            title = NSLocalizedString(
                "browser.readerView.unavailable",
                value: "Reader View is unavailable on this page",
                comment: "Reader View - Toast shown when reader extraction could not run at all")
        }
        OverlayToastCenter.shared.show(title: title, in: self)
    }
}
