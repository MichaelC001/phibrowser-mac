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
            comment: "Reader View - Tooltip for the control that opens the reading appearance settings"),
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
        PhiPreferences.Reader.persist(style)
        // Deliberately not a re-render: the document does not change, only
        // its scale, so the reader keeps its place on the page.
        applyTextZoom()
        updateControlAvailability()
    }

    @objc private func closeReader() {
        onDismiss?()
    }

    // MARK: - Style

    /// Every reading setting the surface offers, in one menu.
    ///
    /// Grouped into submenus rather than listed flat: the axes are independent
    /// and there are now seven of them, so a flat menu would be forty items
    /// deep and would hide the one being adjusted behind the pointer. None of
    /// them rebuilds the document — each is an attribute the stylesheet
    /// already has rules for — so a choice can be made mid-article without
    /// losing the line being read.
    @objc private func showStyleMenu() {
        let menu = NSMenu()
        // Reset says whether there is anything to reset, and AppKit's
        // automatic validation would overwrite that the moment the menu opened.
        menu.autoenablesItems = false
        menu.addItem(styleSubmenu(
            title: NSLocalizedString(
                "browser.readerView.styleTheme", value: "Background",
                comment: "Reader View - Style menu section for the reading background"),
            cases: ReaderStyle.Theme.allCases, selected: style.theme,
            action: #selector(selectTheme(_:)), titleFor: Self.themeTitle))
        menu.addItem(styleSubmenu(
            title: NSLocalizedString(
                "browser.readerView.styleTypeface", value: "Typeface",
                comment: "Reader View - Style menu section for the article typeface"),
            cases: ReaderStyle.Typeface.allCases, selected: style.typeface,
            action: #selector(selectTypeface(_:)), titleFor: Self.typefaceTitle))
        menu.addItem(styleSubmenu(
            title: NSLocalizedString(
                "browser.readerView.styleWidth", value: "Width",
                comment: "Reader View - Style menu section for the content column width"),
            cases: ReaderStyle.Width.allCases, selected: style.width,
            action: #selector(selectWidth(_:)), titleFor: Self.widthTitle))
        menu.addItem(styleSubmenu(
            title: NSLocalizedString(
                "browser.readerView.styleLineHeight", value: "Line Height",
                comment: "Reader View - Style menu section for the space between lines of text"),
            cases: ReaderStyle.LineHeight.allCases, selected: style.lineHeight,
            action: #selector(selectLineHeight(_:)), titleFor: Self.lineHeightTitle))
        menu.addItem(styleSubmenu(
            title: NSLocalizedString(
                "browser.readerView.styleLetterSpacing", value: "Letter Spacing",
                comment: "Reader View - Style menu section for the space between characters"),
            cases: ReaderStyle.LetterSpacing.allCases, selected: style.letterSpacing,
            action: #selector(selectLetterSpacing(_:)), titleFor: Self.letterSpacingTitle))

        menu.addItem(.separator())
        menu.addItem(toggleItem(
            title: NSLocalizedString(
                "browser.readerView.showImages", value: "Show Images",
                comment: "Reader View - Switch that shows or hides the article's illustrations"),
            isOn: style.showsImages, action: #selector(toggleImages)))
        menu.addItem(toggleItem(
            title: NSLocalizedString(
                "browser.readerView.highlightLinks", value: "Highlight Links",
                comment: "Reader View - Switch that tints and underlines links, or leaves them looking like body text"),
            isOn: style.highlightsLinks, action: #selector(toggleLinkHighlighting)))

        menu.addItem(.separator())
        let reset = NSMenuItem(
            title: NSLocalizedString(
                "browser.readerView.resetStyle", value: "Reset to Defaults",
                comment: "Reader View - Menu item that returns every reading setting to its original value"),
            action: #selector(resetStyle), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = style != .standard
        menu.addItem(reset)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: styleButton.bounds.height + 4),
                   in: styleButton)
    }

    /// One group of mutually exclusive choices. Generic over the option type
    /// because the five groups differ only in which enum they list and which
    /// action they send; written out per group, the checkmark bookkeeping was
    /// the same eight lines five times.
    private func styleSubmenu<Option>(title: String,
                                      cases: [Option],
                                      selected: Option,
                                      action: Selector,
                                      titleFor: (Option) -> String) -> NSMenuItem
    where Option: RawRepresentable & Equatable, Option.RawValue == String {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for option in cases {
            submenu.addItem(styleItem(title: titleFor(option),
                                      selected: option == selected,
                                      action: action,
                                      value: option.rawValue))
        }
        parent.submenu = submenu
        return parent
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

    private func toggleItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    /// The one path every style change takes: mutate, remember, restyle the
    /// document that is already on screen. Persisting the whole style rather
    /// than the one field that changed means a new axis cannot be wired to a
    /// menu and then forgotten in the preference store.
    private func apply(_ change: (inout ReaderStyle) -> Void) {
        var updated = style
        change(&updated)
        guard updated != style else { return }
        style = updated
        PhiPreferences.Reader.persist(updated)
        applyStyleInPlace()
    }

    @objc private func selectWidth(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let width = ReaderStyle.Width(rawValue: raw) else { return }
        apply { $0.width = width }
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = ReaderStyle.Theme(rawValue: raw) else { return }
        apply { $0.theme = theme }
    }

    @objc private func selectTypeface(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let typeface = ReaderStyle.Typeface(rawValue: raw) else { return }
        apply { $0.typeface = typeface }
    }

    @objc private func selectLineHeight(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lineHeight = ReaderStyle.LineHeight(rawValue: raw) else { return }
        apply { $0.lineHeight = lineHeight }
    }

    @objc private func selectLetterSpacing(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let letterSpacing = ReaderStyle.LetterSpacing(rawValue: raw) else { return }
        apply { $0.letterSpacing = letterSpacing }
    }

    @objc private func toggleImages() {
        apply { $0.showsImages.toggle() }
    }

    @objc private func toggleLinkHighlighting() {
        apply { $0.highlightsLinks.toggle() }
    }

    /// Text size is the one setting that is a zoom rather than an attribute,
    /// so a reset has to put both back.
    @objc private func resetStyle() {
        let sizeChanged = style.fontSize != ReaderStyle.standard.fontSize
        apply { $0 = .standard }
        guard sizeChanged else { return }
        applyTextZoom()
        updateControlAvailability()
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
        case .yellow:
            return NSLocalizedString("browser.readerView.themeYellow", value: "Yellow",
                comment: "Reader View - Background option, dark text on a pale yellow page")
        case .blue:
            return NSLocalizedString("browser.readerView.themeBlue", value: "Blue",
                comment: "Reader View - Background option, dark text on a pale blue page")
        case .dark:
            return NSLocalizedString("browser.readerView.themeDark", value: "Dark",
                comment: "Reader View - Background option, always dark")
        case .dim:
            return NSLocalizedString("browser.readerView.themeDim", value: "Dim",
                comment: "Reader View - Background option, a dark page with softer contrast than Dark")
        case .contrast:
            return NSLocalizedString("browser.readerView.themeContrast", value: "High Contrast",
                comment: "Reader View - Background option, pure white text on pure black for low vision")
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
        case .book:
            return NSLocalizedString("browser.readerView.typefaceBook", value: "Book",
                comment: "Reader View - Typeface option, the old-style serif used for printed books")
        case .rounded:
            return NSLocalizedString("browser.readerView.typefaceRounded", value: "Rounded",
                comment: "Reader View - Typeface option, a sans-serif face with rounded letterforms")
        case .mono:
            return NSLocalizedString("browser.readerView.typefaceMono", value: "Monospace",
                comment: "Reader View - Typeface option, a fixed-width face where every character is the same width")
        }
    }

    private static func lineHeightTitle(_ lineHeight: ReaderStyle.LineHeight) -> String {
        switch lineHeight {
        case .tight:
            return NSLocalizedString("browser.readerView.lineHeightTight", value: "Tight",
                comment: "Reader View - Line spacing option, lines closer together than the default")
        case .normal:
            return NSLocalizedString("browser.readerView.lineHeightNormal", value: "Normal",
                comment: "Reader View - Line spacing option, the default spacing between lines")
        case .relaxed:
            return NSLocalizedString("browser.readerView.lineHeightRelaxed", value: "Relaxed",
                comment: "Reader View - Line spacing option, lines further apart than the default")
        case .loose:
            return NSLocalizedString("browser.readerView.lineHeightLoose", value: "Loose",
                comment: "Reader View - Line spacing option, the widest spacing between lines")
        }
    }

    private static func letterSpacingTitle(_ spacing: ReaderStyle.LetterSpacing) -> String {
        switch spacing {
        case .normal:
            return NSLocalizedString("browser.readerView.letterSpacingNormal", value: "Normal",
                comment: "Reader View - Character spacing option, the typeface's own spacing")
        case .wide:
            return NSLocalizedString("browser.readerView.letterSpacingWide", value: "Wide",
                comment: "Reader View - Character spacing option, characters set further apart")
        case .wider:
            return NSLocalizedString("browser.readerView.letterSpacingWider", value: "Wider",
                comment: "Reader View - Character spacing option, the widest spacing between characters")
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
