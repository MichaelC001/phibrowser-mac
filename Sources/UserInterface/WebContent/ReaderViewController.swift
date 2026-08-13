// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SnapKit
import UniformTypeIdentifiers
import WebKit

/// Presentation surface for Reader View.
///
/// Renders the distilled article in a `WKWebView` with scripting disabled.
/// Article markup is sanitised in the page before it reaches Swift; disabling
/// scripting here means extracted markup cannot execute even if that pass is
/// ever incomplete.
///
/// Turning scripting off stops the *page's* scripts, not the host's, so the
/// surface still adjusts itself without reloading: a style change rewrites
/// root attributes the stylesheet already covers, and a text-size change
/// scales with `pageZoom`. A reload happens only when the article itself is
/// replaced, and even then the reading position is carried across.
final class ReaderViewController: NSViewController {

    /// Invoked when the user dismisses Reader View from inside the surface.
    var onDismiss: (() -> Void)?
    /// Invoked when the user follows a link. Reader View closes and the tab
    /// navigates, so the reader never becomes a browsing surface of its own.
    var onNavigate: ((URL) -> Void)?
    /// Invoked after a code block is copied, so the owner can confirm it.
    var onDidCopyCode: (() -> Void)?
    /// Asks the owner to save the page the article came from. The owner holds
    /// the tab; this surface only holds the article.
    var onExportOriginalPage: (() -> Void)?
    /// Asks the owner to wait until the article has stopped being added to,
    /// and hand back the final one. The passes that grow it are driven from
    /// the tab, which this surface cannot see.
    var awaitFinalArticle: (() async -> ReaderArticle?)?

    private var article: ReaderArticle?
    private var style: ReaderStyle = .current
    /// Reading position held across a re-render of the same article, applied
    /// once the replacement document has loaded.
    private var scrollOffsetToRestore: Double?
    /// When the document on screen started loading, for attributing a slow
    /// reader to the document rather than to extraction.
    private var loadStartedAt: Date?
    /// Retains the theme subscription; dropping it unsubscribes.
    private var themeSubscription: AnyObject?

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Deliberately NOT suppressing incremental rendering.
        //
        // Suppression withholds every pixel until the document is fully
        // loaded — including its images, which the reader refetches from the
        // origin through WebKit's own network stack rather than reusing what
        // Chromium already has. On an image-heavy article that is seconds of
        // nothing: a ruanyifeng weekly issue carries 40 images and took 4988ms
        // to finish loading from a cold cache, against 56ms to extract. The
        // text was ready the whole time.
        //
        // There is no flash of unstyled content to protect against here: the
        // stylesheet is inline in the same string as the markup, so it is
        // parsed before the first layout either way.
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }()

    private lazy var controlBar: NSVisualEffectView = {
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        return bar
    }()

    private lazy var decreaseButton = makeControl(
        systemName: "textformat.size.smaller",
        label: NSLocalizedString(
            "browser.readerView.decreaseTextSize",
            value: "Decrease Text Size",
            comment: "Reader View - Tooltip for the control that makes article text smaller"),
        action: #selector(decreaseFontSize))

    private lazy var increaseButton = makeControl(
        systemName: "textformat.size.larger",
        label: NSLocalizedString(
            "browser.readerView.increaseTextSize",
            value: "Increase Text Size",
            comment: "Reader View - Tooltip for the control that makes article text larger"),
        action: #selector(increaseFontSize))

    private lazy var styleButton = makeControl(
        systemName: "textformat",
        label: NSLocalizedString(
            "browser.readerView.style",
            value: "Reading Style",
            comment: "Reader View - Tooltip for the control that changes width, background and typeface"),
        action: #selector(showStyleMenu))

    private lazy var exportButton = makeControl(
        systemName: "square.and.arrow.down",
        label: NSLocalizedString(
            "browser.readerView.export",
            value: "Save Article",
            comment: "Reader View - Tooltip for the control that saves the article to a file"),
        action: #selector(showExportMenu))

    private lazy var closeButton = makeControl(
        systemName: "xmark",
        label: NSLocalizedString(
            "browser.readerView.close",
            value: "Close Reader View",
            comment: "Reader View - Tooltip for the control that returns to the original page"),
        action: #selector(closeReader))

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        // Matches the reader document's own background so the gap before the
        // first paint does not flash white in dark mode.
        applyHostBackground()

        view.addSubview(webView)
        webView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let stack = NSStackView(views: [decreaseButton, increaseButton,
                                        styleButton, exportButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        view.addSubview(controlBar)
        controlBar.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        controlBar.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(12)
            make.right.equalToSuperview().offset(-18)
        }

        // An appearance change only moves which palette applies, and the
        // document carries them all, so this is a restyle rather than a
        // rebuild.
        themeSubscription = view.subscribe { [weak self] _, _ in
            self?.applyStyleInPlace()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The effective appearance is only trustworthy once the view is in a
        // window, so reapply it now that there is one.
        applyStyleInPlace()
    }

    // MARK: - Content

    /// Shows an article, replacing whatever is on screen.
    ///
    /// An article can be replaced by a better capture of the same document —
    /// the rest of a long PDF, or the images a page only loads once it has
    /// been scrolled. Reloading would return the reader to the top, which
    /// while someone is reading looks like the article restarted, so the
    /// position is read off the old document and reapplied to the new one.
    func present(article: ReaderArticle) {
        // Re-presenting what is already on screen costs a full reload, and on a
        // single-page site it is not rare: every push-state the page makes runs
        // the content host again, which re-presents. Reddit did it seven times
        // in thirty milliseconds. The article is Equatable, so the cheap
        // question is also the right one.
        guard article != self.article else { return }
        let replacesSameDocument = self.article?.sourceURL == article.sourceURL
        self.article = article
        guard replacesSameDocument else {
            scrollOffsetToRestore = nil
            render()
            return
        }
        webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
            guard let self else { return }
            self.scrollOffsetToRestore = value as? Double
            AppLogDebug("[Reader] replacing the article in place, " +
                        "holding scroll at \(self.scrollOffsetToRestore ?? -1)")
            self.render()
        }
    }

    private func applyHostBackground() {
        view.layer?.backgroundColor = ReaderDocumentBuilder
            .backgroundColor(theme: style.theme,
                             appearanceIsDark: ThemeManager.shared.currentAppearance.isDark)
            .cgColor
    }

    /// The live document is always built at the default size and scaled with
    /// `pageZoom`, so changing text size is a relayout rather than a reload.
    ///
    /// Rebuilding the document for each step re-parsed the whole article,
    /// refetched its images, and — the part that actually read as broken —
    /// returned a long page to the top. A two-point step taken while deep in
    /// a Wikipedia article looked like nothing had happened, because what you
    /// were reading was gone. Export still bakes the chosen size into the
    /// file, which has no zoom to carry.
    private func render() {
        applyHostBackground()
        guard let article else { return }
        // Built at the default size and scaled by `pageZoom`; the rest of the
        // style rides on root attributes the stylesheet already covers.
        var rendered = style
        rendered.fontSize = ReaderDocumentBuilder.defaultFontSize
        let document = ReaderDocumentBuilder.makeDocument(
            article: article,
            style: rendered,
            appearanceIsDark: ThemeManager.shared.currentAppearance.isDark)
        // baseURL is the article's origin so any relative reference that
        // survived absolutisation still resolves sensibly.
        loadStartedAt = Date()
        webView.loadHTMLString(document, baseURL: URL(string: article.sourceURL))
        applyTextZoom()
        updateControlAvailability()
    }

    /// Restyles the loaded document rather than rebuilding it.
    ///
    /// Content scripting is off, which stops the page's own scripts; it does
    /// not stop the host evaluating its own. So every style choice is an
    /// attribute on the root element that the stylesheet already has rules
    /// for, and changing one keeps the reader's place in the article.
    private func applyStyleInPlace() {
        applyHostBackground()
        let script = ReaderDocumentBuilder.styleUpdateScript(
            style, appearanceIsDark: ThemeManager.shared.currentAppearance.isDark)
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                AppLogDebug("[Reader] in-place restyle failed: \(error)")
            }
        }
    }

    private func applyTextZoom() {
        webView.pageZoom = ReaderDocumentBuilder.textZoom(forFontSize: style.fontSize)
    }


    private func updateControlAvailability() {
        decreaseButton.isEnabled = style.fontSize > ReaderDocumentBuilder.minFontSize
        increaseButton.isEnabled = style.fontSize < ReaderDocumentBuilder.maxFontSize
    }

    // MARK: - Actions

    @objc private func decreaseFontSize() {
        setFontSize(style.fontSize - ReaderDocumentBuilder.fontSizeStep)
    }

    @objc private func increaseFontSize() {
        setFontSize(style.fontSize + ReaderDocumentBuilder.fontSizeStep)
    }

    private func setFontSize(_ newValue: Int) {
        let clamped = min(max(newValue, ReaderDocumentBuilder.minFontSize),
                          ReaderDocumentBuilder.maxFontSize)
        guard clamped != style.fontSize else { return }
        style.fontSize = clamped
        PhiPreferences.Reader.fontSize = clamped
        // Deliberately not a re-render: the document does not change, only
        // its scale, so the reader keeps its place on the page.
        applyTextZoom()
        updateControlAvailability()
    }

    @objc private func closeReader() {
        onDismiss?()
    }

    // MARK: - Style

    /// Width, background and typeface, in one menu.
    ///
    /// These rebuild the document, unlike text size, which scales it. The
    /// stylesheet is generated in Swift and the surface has no scripting, so
    /// there is nothing in the page to restyle in place — but these are
    /// settle-once choices rather than something stepped while reading, so the
    /// rebuild is not the interruption it would be for size.
    @objc private func showStyleMenu() {
        let menu = NSMenu()
        menu.addItem(sectionHeader(NSLocalizedString(
            "browser.readerView.styleWidth", value: "Width",
            comment: "Reader View - Style menu section for the content column width")))
        for width in ReaderStyle.Width.allCases {
            menu.addItem(styleItem(title: Self.widthTitle(width),
                                   selected: style.width == width,
                                   action: #selector(selectWidth(_:)),
                                   value: width.rawValue))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader(NSLocalizedString(
            "browser.readerView.styleTheme", value: "Background",
            comment: "Reader View - Style menu section for the reading background")))
        for theme in ReaderStyle.Theme.allCases {
            menu.addItem(styleItem(title: Self.themeTitle(theme),
                                   selected: style.theme == theme,
                                   action: #selector(selectTheme(_:)),
                                   value: theme.rawValue))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader(NSLocalizedString(
            "browser.readerView.styleTypeface", value: "Typeface",
            comment: "Reader View - Style menu section for the article typeface")))
        for typeface in ReaderStyle.Typeface.allCases {
            menu.addItem(styleItem(title: Self.typefaceTitle(typeface),
                                   selected: style.typeface == typeface,
                                   action: #selector(selectTypeface(_:)),
                                   value: typeface.rawValue))
        }

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: styleButton.bounds.height + 4),
                   in: styleButton)
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The chosen value rides on `representedObject` so one action serves
    /// every item in its group.
    private func styleItem(title: String, selected: Bool,
                           action: Selector, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = selected ? .on : .off
        return item
    }

    @objc private func selectWidth(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let width = ReaderStyle.Width(rawValue: raw), width != style.width else { return }
        style.width = width
        PhiPreferences.Reader.width = width
        applyStyleInPlace()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = ReaderStyle.Theme(rawValue: raw), theme != style.theme else { return }
        style.theme = theme
        PhiPreferences.Reader.theme = theme
        applyStyleInPlace()
    }

    @objc private func selectTypeface(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let typeface = ReaderStyle.Typeface(rawValue: raw),
              typeface != style.typeface else { return }
        style.typeface = typeface
        PhiPreferences.Reader.typeface = typeface
        applyStyleInPlace()
    }

    // MARK: - Export

    /// Two exports, because the reader is a view of a page rather than a
    /// replacement for it: the article as the reader distilled it, and the
    /// page it came from, complete.
    @objc private func showExportMenu() {
        let menu = NSMenu()
        let article = NSMenuItem(
            title: NSLocalizedString(
                "browser.readerView.exportArticle",
                value: "Save Article as HTML…",
                comment: "Reader View - Menu item that saves the distilled article as a single HTML file"),
            action: #selector(exportArticle), keyEquivalent: "")
        article.target = self
        menu.addItem(article)

        let original = NSMenuItem(
            title: NSLocalizedString(
                "browser.readerView.exportOriginal",
                value: "Save Original Page…",
                comment: "Reader View - Menu item that saves the page the article came from as a single archive file"),
            action: #selector(exportOriginal), keyEquivalent: "")
        original.target = self
        menu.addItem(original)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: exportButton.bounds.height + 4),
                   in: exportButton)
    }

    @objc private func exportArticle() {
        let isDark = ThemeManager.shared.currentAppearance.isDark
        let exported = style
        Task { @MainActor in
            // The rest of a long PDF, or whatever walking the page recovers,
            // can still be on its way in. Saving the article as it stands
            // would write a file the reader is about to disagree with.
            guard let article = await awaitFinalArticle?() ?? self.article else {
                return
            }
            let data = await ReaderExportService.makeArticleDocument(
                article: article, style: exported, appearanceIsDark: isDark)
            save(data,
                 suggestedName: ReaderExportService.suggestedFileName(
                    title: article.title, extension: "html"),
                 contentType: .html)
        }
    }

    @objc private func exportOriginal() {
        onExportOriginalPage?()
    }

    /// Writes the exported bytes wherever the user chooses. Public so the
    /// owner can complete the original-page export, which needs the tab.
    func save(_ data: Data, suggestedName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedName
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogError("[Reader] export failed: \(error)")
            }
        }
    }

    // MARK: - Style names

    private static func widthTitle(_ width: ReaderStyle.Width) -> String {
        switch width {
        case .narrow:
            return NSLocalizedString("browser.readerView.widthNarrow", value: "Narrow",
                comment: "Reader View - Content width option, a column narrower than the default")
        case .normal:
            return NSLocalizedString("browser.readerView.widthNormal", value: "Normal",
                comment: "Reader View - Content width option, the default reading column")
        case .wide:
            return NSLocalizedString("browser.readerView.widthWide", value: "Wide",
                comment: "Reader View - Content width option, a column wider than the default")
        case .full:
            return NSLocalizedString("browser.readerView.widthFull", value: "Full Width",
                comment: "Reader View - Content width option, the article fills the window")
        }
    }

    private static func themeTitle(_ theme: ReaderStyle.Theme) -> String {
        switch theme {
        case .matchBrowser:
            return NSLocalizedString("browser.readerView.themeMatch", value: "Match Browser",
                comment: "Reader View - Background option that follows the browser's light or dark appearance")
        case .light:
            return NSLocalizedString("browser.readerView.themeLight", value: "Light",
                comment: "Reader View - Background option, always light")
        case .sepia:
            return NSLocalizedString("browser.readerView.themeSepia", value: "Sepia",
                comment: "Reader View - Background option, warm off-white paper")
        case .dark:
            return NSLocalizedString("browser.readerView.themeDark", value: "Dark",
                comment: "Reader View - Background option, always dark")
        }
    }

    private static func typefaceTitle(_ typeface: ReaderStyle.Typeface) -> String {
        switch typeface {
        case .serif:
            return NSLocalizedString("browser.readerView.typefaceSerif", value: "Serif",
                comment: "Reader View - Typeface option, a serif face for body text")
        case .sans:
            return NSLocalizedString("browser.readerView.typefaceSans", value: "Sans Serif",
                comment: "Reader View - Typeface option, a sans-serif face for body text")
        }
    }

    // MARK: - Helpers

    private func makeControl(systemName: String,
                             label: String,
                             action: Selector) -> HoverableButtonNSView {
        let config = HoverableButtonConfig(
            imageSize: NSSize(width: 14, height: 14),
            systemName: systemName,
            hoverBackgroundColor: .hover,
            cornerRadius: 5)
        let button = HoverableButtonNSView(config: config, target: self, selector: action)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.snp.makeConstraints { make in
            make.width.height.equalTo(26)
        }
        return button
    }
}

// MARK: - Copying code

extension ReaderViewController {

    /// Copies a code block from the article model rather than from the
    /// rendered document: the model holds the sample as the extractor read it
    /// out of the real page, so highlighting spans and entity escaping cannot
    /// corrupt what lands on the clipboard.
    fileprivate func copyCodeBlock(at index: Int) {
        guard let blocks = article?.codeBlocks,
              blocks.indices.contains(index) else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(blocks[index], forType: .string)
        // The document has no scripting, so it cannot acknowledge the click
        // itself. The owner shows the confirmation.
        onDidCopyCode?()
    }
}

// MARK: - WKNavigationDelegate

extension ReaderViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The initial loadHTMLString is the only navigation the reader
        // performs itself. Anything user-initiated leaves Reader View and is
        // handed to the tab, so browsing never happens inside this surface.
        guard navigationAction.navigationType != .other,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)

        // A copy control is a link because the surface has no scripting. It
        // is handled here and is not a navigation at all.
        if let index = ReaderDocumentBuilder.copyIndex(from: url) {
            copyCodeBlock(at: index)
            return
        }
        onNavigate?(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let loadStartedAt {
            AppLogDebug("[Reader] document finished loading in " +
                        "\(Int(Date().timeIntervalSince(loadStartedAt) * 1000))ms")
            self.loadStartedAt = nil
        }
        guard let offset = scrollOffsetToRestore, offset > 0 else { return }
        scrollOffsetToRestore = nil
        webView.evaluateJavaScript("window.scrollTo(0, \(offset))")
    }
}
