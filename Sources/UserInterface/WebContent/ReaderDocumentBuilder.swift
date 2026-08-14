// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Assembles the reader document served to the reader web view.
///
/// The document is static: the reader web view runs with scripting disabled,
/// so appearance changes re-render here rather than mutating the page.
enum ReaderDocumentBuilder {

    /// Body text size in points. Bounds match what stays readable at the
    /// fixed content column width.
    static let minFontSize = 15
    static let maxFontSize = 26
    static let fontSizeStep = 2
    static let defaultFontSize = 19

    /// Maps a chosen body size onto a page zoom against the size the live
    /// document is built at. The reader scales rather than re-renders, so a
    /// size step keeps the reader's place in the article.
    static func textZoom(forFontSize fontSize: Int) -> CGFloat {
        CGFloat(fontSize) / CGFloat(defaultFontSize)
    }

    /// `includeCopyControls` is false for an exported file: the controls are
    /// links the app intercepts, so outside it they are dead.
    static func makeDocument(article: ReaderArticle,
                             style: ReaderStyle,
                             appearanceIsDark: Bool,
                             includeCopyControls: Bool = true) -> String {
        let lang = article.lang.map { " lang=\"\(escape($0))\"" } ?? ""

        var header = "<h1 class=\"phi-title\">\(escape(article.title))</h1>"
        var meta: [String] = []
        if let byline = article.byline {
            meta.append(escape(byline))
        }
        if let siteName = article.siteName {
            meta.append(escape(siteName))
        }
        if !meta.isEmpty {
            header += "<p class=\"phi-meta\">\(meta.joined(separator: " · "))</p>"
        }

        return """
        <!DOCTYPE html>
        <html\(lang)\(styleAttributes(style, appearanceIsDark: appearanceIsDark))>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(article.title))</title>
        <style>\(stylesheet(fontSize: style.fontSize))</style>
        </head>
        <body>
        <main class="phi-reader">
        <header>\(header)</header>
        <article>\(includeCopyControls
                    ? withCopyControls(article.contentHTML, count: article.codeBlocks.count)
                    : article.contentHTML)</article>
        </main>
        </body>
        </html>
        """
    }

    /// Every style choice rides on the root element, so a change is one
    /// attribute rather than a new document. Values come from closed enums,
    /// never from the page, so writing them into markup and into a script is
    /// safe by construction.
    ///
    /// The document's opening tag and the in-place restyle script both render
    /// from this one list. They were written out separately and had to be held
    /// in agreement by hand, which with two axes was a nuisance and with seven
    /// would be a bug: an axis missing from the script silently does nothing
    /// until the article is next rebuilt.
    private static func rootAttributes(_ style: ReaderStyle,
                                       appearanceIsDark: Bool) -> [(String, String)] {
        [("data-theme", style.theme.resolved(appearanceIsDark: appearanceIsDark).rawValue),
         ("data-width", style.width.rawValue),
         ("data-typeface", style.typeface.rawValue),
         ("data-line-height", style.lineHeight.rawValue),
         ("data-letter-spacing", style.letterSpacing.rawValue),
         ("data-images", style.showsImages ? "on" : "off"),
         ("data-links", style.highlightsLinks ? "on" : "off")]
    }

    static func styleAttributes(_ style: ReaderStyle, appearanceIsDark: Bool) -> String {
        rootAttributes(style, appearanceIsDark: appearanceIsDark)
            .map { " \($0.0)=\"\($0.1)\"" }
            .joined()
    }

    /// The script the host runs to restyle a loaded document in place.
    ///
    /// The reader keeps content scripting off, which blocks the page's own
    /// scripts but not the host's own evaluation — so a style change is an
    /// attribute write on a live document rather than a reload, and the
    /// reader keeps its place in the article.
    static func styleUpdateScript(_ style: ReaderStyle, appearanceIsDark: Bool) -> String {
        let writes = rootAttributes(style, appearanceIsDark: appearanceIsDark)
            .map { "e.setAttribute('\($0.0)','\($0.1)');" }
            .joined()
        return "(function(){var e=document.documentElement;\(writes)})()"
    }

    // MARK: - Reading aloud

    /// Every element that is a unit of speech. A block holding another one is
    /// a container, not a passage — reading both would say its text twice.
    private static let passageSelector =
        "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,figcaption,dt,dd,td,th"

    /// Numbers the article's readable blocks and hands back their text, in
    /// reading order.
    ///
    /// Read out of the rendered document rather than out of the article's
    /// markup because only the document knows what is on screen: a block
    /// hidden by the images switch has no `offsetParent`, and what is spoken
    /// should be what is shown.
    static let speechPassagesScript = """
    (function(){
      var SELECTOR = '\(passageSelector)';
      var nodes = document.querySelectorAll(SELECTOR);
      var texts = [];
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        node.removeAttribute('data-phi-say');
        if (node.querySelector(SELECTOR)) { continue; }
        if (!node.offsetParent) { continue; }
        var text = (node.innerText || '').replace(/\\s+/g, ' ').trim();
        if (!text) { continue; }
        node.setAttribute('data-phi-say', String(texts.length));
        texts.push(text);
      }
      return texts;
    })()
    """

    /// Marks the block being spoken and brings it into view.
    ///
    /// Scrolled only when it has left the window: a reader who has scrolled
    /// ahead to look at something is not asking to be dragged back every
    /// paragraph.
    static func speechHighlightScript(index: Int) -> String {
        """
        (function(){
          var previous = document.querySelector('.phi-speaking');
          if (previous) { previous.classList.remove('phi-speaking'); }
          var node = document.querySelector('[data-phi-say="\(index)"]');
          if (!node) { return; }
          node.classList.add('phi-speaking');
          var box = node.getBoundingClientRect();
          if (box.top < 0 || box.bottom > window.innerHeight) {
            node.scrollIntoView({block: 'center', behavior: 'smooth'});
          }
        })()
        """
    }

    static let speechClearHighlightScript = """
    (function(){var n=document.querySelector('.phi-speaking');\
    if(n){n.classList.remove('phi-speaking');}})()
    """

    /// The scheme the copy links use. `ReaderViewController` cancels these
    /// navigations and copies natively.
    static let copyScheme = "phi-reader"

    static func copyIndex(from url: URL) -> Int? {
        guard url.scheme == copyScheme, url.host == "copy" else { return nil }
        return Int(url.lastPathComponent)
    }

    /// Attaches a copy control to each code block.
    ///
    /// The control is a link, not a button, because the reader web view runs
    /// with JavaScript disabled — deliberately, since it renders markup
    /// extracted from an untrusted page. A scripted button would mean turning
    /// that off for every article to add one affordance. A link costs nothing:
    /// the view controller cancels the navigation and copies from the article
    /// model, so the copied text is the code the extractor read from the real
    /// DOM rather than anything reconstructed from this markup.
    private static func withCopyControls(_ html: String, count: Int) -> String {
        guard count > 0 else { return html }
        let label = NSLocalizedString(
            "browser.readerView.copyCode",
            value: "Copy",
            comment: "Reader View - Button on a code block that copies it to the clipboard")

        var result = html
        for index in 0..<count {
            // The extractor wraps each block in a div carrying this marker, so
            // the only thing to do here is put the control just inside that
            // wrapper. Found by the attribute and then by the end of its tag,
            // rather than by matching the whole opening tag, because attribute
            // order is whatever the DOM serialiser produced.
            guard let marker = result.range(of: "data-phi-code=\"\(index)\""),
                  let tagEnd = result.range(of: ">", range: marker.upperBound..<result.endIndex)
            else { continue }

            // First inside the wrapper, so keyboard focus reaches it before
            // tabbing through a long sample; the stylesheet lifts it into the
            // block's top-right corner.
            let control = "<a class=\"phi-copy\" href=\"\(copyScheme)://copy/\(index)\">"
                + "\(escape(label))</a>"
            result.insert(contentsOf: control, at: tagEnd.upperBound)
        }
        return result
    }

    // MARK: - Appearance

    /// Stored as integers so the CSS and the host view's background come from
    /// one source.
    private struct Palette {
        let background: Int
        let text: Int
        let muted: Int
        let rule: Int
        let accent: Int
        let surface: Int
        let isDark: Bool

        static let light = Palette(background: 0xFBFBF9, text: 0x1C1C1E,
                                   muted: 0x6B6B70, rule: 0xE2E2DD,
                                   accent: 0x0B5CD5, surface: 0xF2F2EE, isDark: false)
        static let dark = Palette(background: 0x1A1A1C, text: 0xE6E6E3,
                                  muted: 0x9A9A9F, rule: 0x333336,
                                  accent: 0x6EA8FE, surface: 0x232326, isDark: true)
        /// Warm paper. The classic reading theme, and the reason people ask
        /// for a theme control at all: lower contrast than white without the
        /// halation of light text on black.
        static let sepia = Palette(background: 0xF6EFE1, text: 0x3B3226,
                                   muted: 0x7A6E5C, rule: 0xE0D5BF,
                                   accent: 0x9A5B12, surface: 0xEFE6D3, isDark: false)
        /// Tinted papers. Neither is a decoration: a coloured ground is the
        /// standard accommodation for visual stress, and which colour helps is
        /// personal enough that offering one would be offering none.
        static let yellow = Palette(background: 0xFBF3C9, text: 0x2A2405,
                                    muted: 0x6B6231, rule: 0xE6D98F,
                                    accent: 0x8A4B00, surface: 0xF4E9A9, isDark: false)
        static let blue = Palette(background: 0xE8F0FA, text: 0x172533,
                                  muted: 0x566577, rule: 0xC6D9EF,
                                  accent: 0x0A4FA0, surface: 0xDBE8F7, isDark: false)
        /// Dark without the contrast. `dark` puts near-white on near-black,
        /// which at night is its own kind of glare; this softens both ends and
        /// is the one to reach for in an unlit room.
        /// The muted grey is lighter than the softened body text would
        /// suggest: it carries bylines and captions, and softening those to
        /// match dropped them to 4.1:1, under the contrast floor. Low
        /// contrast is the point of this theme; unreadable is not.
        static let dim = Palette(background: 0x26262A, text: 0xB9B9BE,
                                 muted: 0x909097, rule: 0x3A3A3F,
                                 accent: 0x8FB6E8, surface: 0x2E2E33, isDark: true)
        /// The opposite end: pure black and pure white, with links in amber
        /// rather than blue because blue on black is the first pair to go for
        /// low vision. Deliberately outside the palette the rest of the
        /// browser uses — an accommodation is not a theme.
        static let contrast = Palette(background: 0x000000, text: 0xFFFFFF,
                                      muted: 0xC8C8C8, rule: 0x8A8A8A,
                                      accent: 0xFFD400, surface: 0x111111, isDark: true)

        static func forTheme(_ theme: ReaderStyle.Theme,
                             appearanceIsDark: Bool) -> Palette {
            switch theme {
            case .sepia: return sepia
            case .yellow: return yellow
            case .blue: return blue
            case .light: return light
            case .dim: return dim
            case .contrast: return contrast
            case .dark: return dark
            case .matchBrowser: return appearanceIsDark ? dark : light
            }
        }
    }

    private static func themeBlocks() -> String {
        ReaderStyle.Theme.allCases
            .filter { $0 != .matchBrowser }   // resolved before it reaches the document
            .map { theme in
                let palette = Palette.forTheme(theme, appearanceIsDark: false)
                return """
                html[data-theme="\(theme.rawValue)"] {
                  color-scheme: \(palette.isDark ? "dark" : "light");
                  --phi-bg: \(css(palette.background));
                  --phi-text: \(css(palette.text));
                  --phi-muted: \(css(palette.muted));
                  --phi-rule: \(css(palette.rule));
                  --phi-accent: \(css(palette.accent));
                  --phi-surface: \(css(palette.surface));
                }
                """
            }
            .joined(separator: "\n")
    }

    private static func widthBlocks() -> String {
        ReaderStyle.Width.allCases.map { width in
            "html[data-width=\"\(width.rawValue)\"] .phi-reader "
                + "{ max-width: \(width.maxWidth); }"
        }.joined(separator: "\n")
    }

    private static func typefaceBlocks() -> String {
        ReaderStyle.Typeface.allCases.map { typeface in
            "html[data-typeface=\"\(typeface.rawValue)\"] body "
                + "{ font-family: \(typeface.cssFontFamily); }"
        }.joined(separator: "\n")
    }

    private static func lineHeightBlocks() -> String {
        ReaderStyle.LineHeight.allCases.map { lineHeight in
            "html[data-line-height=\"\(lineHeight.rawValue)\"] body "
                + "{ line-height: \(lineHeight.cssLineHeight); }"
        }.joined(separator: "\n")
    }

    private static func letterSpacingBlocks() -> String {
        ReaderStyle.LetterSpacing.allCases.map { letterSpacing in
            "html[data-letter-spacing=\"\(letterSpacing.rawValue)\"] body "
                + "{ letter-spacing: \(letterSpacing.cssLetterSpacing); }"
        }.joined(separator: "\n")
    }

    private static func css(_ value: Int) -> String {
        String(format: "#%06x", value)
    }

    /// The reader document's page background, for the host view to match so
    /// the gap before first paint does not flash.
    static func backgroundColor(theme: ReaderStyle.Theme,
                                appearanceIsDark: Bool) -> NSColor {
        NSColor(hex: Palette.forTheme(theme, appearanceIsDark: appearanceIsDark).background)
    }

    /// Every palette and variant is in the document; the root attributes
    /// pick one. That is what makes a style change an attribute write rather
    /// than a rebuild.
    private static func stylesheet(fontSize: Int) -> String {
        return """
        \(themeBlocks())
        \(widthBlocks())
        \(typefaceBlocks())
        \(lineHeightBlocks())
        \(letterSpacingBlocks())
        /* Prose only. An illustration is hidden with its caption, because a
           caption describing something that is not there reads as a fault
           rather than a choice, but inline SVG stays: a page that sets its
           equations as SVG — which every MathJax page does — would otherwise
           lose its argument along with its pictures. */
        html[data-images="off"] img,
        html[data-images="off"] picture,
        html[data-images="off"] video,
        html[data-images="off"] figure { display: none; }
        /* Still links, just no longer shouting. The copy control is an anchor
           too and is not part of the article, so it keeps its own styling. */
        html[data-links="off"] a:not(.phi-copy) {
          color: inherit;
          text-decoration: none;
        }
        * { box-sizing: border-box; }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--phi-bg);
          color: var(--phi-text);
        }
        body {
          font-size: \(fontSize)px;
          -webkit-font-smoothing: antialiased;
        }
        .phi-reader {
          margin: 0 auto;
          padding: 56px 28px 96px;
        }
        .phi-title {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-size: 1.9em;
          line-height: 1.2;
          font-weight: 700;
          margin: 0 0 12px;
        }
        .phi-meta {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-size: 0.72em;
          letter-spacing: 0.02em;
          text-transform: uppercase;
          color: var(--phi-muted);
          margin: 0 0 28px;
          padding-bottom: 24px;
          border-bottom: 1px solid var(--phi-rule);
        }
        article > *:first-child { margin-top: 0; }
        p { margin: 0 0 1.1em; }
        h1, h2, h3, h4, h5, h6 {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          line-height: 1.3;
          margin: 1.8em 0 0.6em;
        }
        h2 { font-size: 1.35em; }
        h3 { font-size: 1.15em; }
        h4, h5, h6 { font-size: 1em; }
        a { color: var(--phi-accent); text-decoration: underline; }
        img, video, svg {
          max-width: 100%;
          height: auto;
          display: block;
          margin: 1.6em auto;
          border-radius: 4px;
        }
        figure { margin: 1.8em 0; }
        /* A figure whose pixels could not be recovered (PDF path): show the
           caption in place so the reading order still makes sense. */
        .phi-figure-placeholder {
          border: 1px dashed var(--phi-rule);
          border-radius: 6px;
          padding: 14px 16px;
          background: var(--phi-surface);
        }
        .phi-figure-placeholder figcaption { margin: 0; text-align: left; }
        figcaption {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-size: 0.76em;
          color: var(--phi-muted);
          text-align: center;
          margin-top: 0.6em;
        }
        blockquote {
          margin: 1.6em 0;
          padding: 0.2em 0 0.2em 1.2em;
          border-left: 3px solid var(--phi-rule);
          color: var(--phi-muted);
          font-style: italic;
        }
        pre, code, kbd, samp {
          font-family: "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
          /* Tracking is a prose setting. Widening a monospace face breaks the
             column alignment that is the whole reason code is set in one. */
          letter-spacing: normal;
        }
        code {
          font-size: 0.85em;
          background: var(--phi-surface);
          padding: 0.15em 0.35em;
          border-radius: 3px;
        }
        pre {
          background: var(--phi-surface);
          padding: 14px 16px;
          border-radius: 6px;
          overflow-x: auto;
          font-size: 0.82em;
          line-height: 1.5;
        }
        pre code { background: none; padding: 0; font-size: 1em; }
        /* The wrapper encloses the block and is the positioning context for
           the control, which is taken out of flow so it overlays the block's
           top-right corner instead of displacing the code. No padding or
           border here, so the block's own top margin still collapses through
           and the wrapper's top edge is the block's top edge. */
        .phi-code {
          position: relative;
        }
        .phi-copy {
          position: absolute;
          top: 0.5em;
          right: 0.5em;
          z-index: 1;
          display: inline-block;
          padding: 0.15em 0.6em;
          border: 1px solid var(--phi-rule);
          border-radius: 5px;
          background: var(--phi-bg);
          color: var(--phi-muted);
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          font-size: 0.72rem;
          line-height: 1.6;
          text-decoration: none;
          opacity: 0;
          transition: opacity 120ms ease-out;
        }
        /* Revealed on hover, and always present for keyboard focus, so the
           control never hides from someone who cannot hover. */
        .phi-code:hover .phi-copy, .phi-copy:focus { opacity: 1; }
        .phi-copy:active { color: var(--phi-text); }
        @media (hover: none) { .phi-copy { opacity: 1; } }
        /* The block being read aloud.
           A tinted ground rather than a border or an inserted marker: it has
           to read against seven palettes, and it must not move the text —
           someone following along cannot afford a reflow at every paragraph.
           The shadow spreads the same tint past the box's edges, which is
           what padding would do at exactly that cost. `color-mix` keeps the
           tint tied to each theme's own accent; the flat declaration before
           it is what an engine without `color-mix` is left with. */
        .phi-speaking {
          background: var(--phi-surface);
          background: color-mix(in srgb, var(--phi-accent) 15%, transparent);
          box-shadow: 0 0 0 5px var(--phi-surface);
          box-shadow: 0 0 0 5px color-mix(in srgb, var(--phi-accent) 15%, transparent);
          border-radius: 3px;
        }
        ul, ol { margin: 0 0 1.1em; padding-left: 1.4em; }
        li { margin-bottom: 0.4em; }
        hr { border: 0; border-top: 1px solid var(--phi-rule); margin: 2.2em 0; }
        /* A thread is many short pieces by different people, so the reader has
           to answer three questions a concatenated page cannot: where does this
           one end, who wrote it, and is it a post or a reply to one.

           A full-width rule closes each top-level post. The name answers the
           second question and so is set in body colour and weight — as a muted
           caption, the same grey as the score, it read as a footnote and the
           posts ran together. Depth answers the third: replies lose the rule,
           gain a spine on the left and step inward, capped so the deepest
           reply is still worth reading at the narrow width. */
        .phi-post {
          border-top: 1px solid var(--phi-rule);
          padding-top: 1.3em;
          margin: 1.9em 0 0;
        }
        .phi-post:first-child { border-top: none; padding-top: 0; margin-top: 0; }
        .phi-post-by {
          display: flex;
          flex-wrap: wrap;
          align-items: baseline;
          gap: 0 0.55em;
          margin: 0 0 0.7em;
        }
        .phi-post-author {
          color: var(--phi-text);
          font-weight: 600;
          font-size: 0.92em;
          letter-spacing: 0.01em;
        }
        .phi-post-meta {
          color: var(--phi-muted);
          font-size: 0.78em;
        }
        /* Only between the two, so a post with a score and no name does not
           start with a dangling separator. */
        .phi-post-author + .phi-post-meta::before {
          content: "·";
          margin-right: 0.5em;
        }
        /* An indented reply belongs to the one above it, so the separator
           becomes a spine on the left rather than a full-width rule implying a
           new top-level post, and the arrow says which it is without relying
           on the indent surviving a narrow window. */
        .phi-post[data-depth] {
          border-top: none;
          border-left: 2px solid var(--phi-rule);
          padding: 0.1em 0 0.1em 1em;
          margin-top: 1.2em;
        }
        .phi-post[data-depth] .phi-post-author::before {
          content: "↳";
          color: var(--phi-muted);
          font-weight: 400;
          margin-right: 0.4em;
        }
        .phi-post[data-depth="2"] { margin-left: 1.3em; }
        .phi-post[data-depth="3"] { margin-left: 2.6em; }
        .phi-post[data-depth="4"] { margin-left: 3.9em; }
        .phi-post[data-depth="5"] { margin-left: 5.2em; }
        /* Wide content scrolls inside its own box; the page never does. */
        .phi-table-scroll, table { display: block; overflow-x: auto; }
        table {
          width: 100%;
          border-collapse: collapse;
          font-size: 0.86em;
          margin: 1.6em 0;
        }
        /* An infobox is a summary card, not a data table: MediaWiki sites put
           one in the right rail of an article and the reader should read the
           same way. Without this it inherits the full-width table rules above
           and becomes a two-thousand-pixel block before the first paragraph.
           `display: table` undoes the scroll treatment, which a card neither
           needs nor survives. */
        .infobox {
          display: table;
          float: right;
          clear: right;
          width: 16em;
          max-width: 45%;
          margin: 0.3em 0 1.2em 1.6em;
          padding: 0.2em;
          border: 1px solid var(--phi-rule);
          border-radius: 6px;
          background: var(--phi-surface);
          font-size: 0.74em;
          overflow: visible;
        }
        .infobox th, .infobox td {
          border: none;
          padding: 0.25em 0.5em;
          vertical-align: top;
        }
        .infobox img { max-width: 100%; height: auto; }
        .infobox caption, .infobox > tbody > tr > th[colspan] {
          font-weight: 600;
          text-align: center;
        }
        /* Too narrow to sit beside the text: give it the full column instead
           of squeezing the prose into a gutter. */
        @media (max-width: 34em) {
          .infobox {
            float: none;
            width: auto;
            max-width: none;
            margin: 1.4em 0;
          }
        }
        th, td {
          border: 1px solid var(--phi-rule);
          padding: 7px 10px;
          text-align: left;
        }
        th { background: var(--phi-surface); font-weight: 600; }
        sup, sub { line-height: 0; font-size: 0.72em; }
        """
    }

    // MARK: - Escaping

    /// Escapes text interpolated into the document. Article markup itself is
    /// sanitised in the page before it reaches Swift.
    private static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
