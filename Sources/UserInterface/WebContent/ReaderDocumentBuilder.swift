// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Assembles a standalone reader document from an extracted article.
///
/// The interactive reading surface lives in the Phi Reader extension; this
/// builder remains for the article documents the app itself produces — the
/// agent API's `readerDocument` and file exports — which is why the output
/// is static markup with no scripts or controls.
///
/// The style model (font-size grid, palettes, axes) is mirrored by the
/// extension's `src/reader/style.ts`; keep the two in agreement so a
/// preference means the same thing on both surfaces.
enum ReaderDocumentBuilder {

    /// Body text size in points. The floor is where the column stops being
    /// readable; the ceiling is roughly double the default, which is a low-
    /// vision size rather than a taste size — past it the em-based column
    /// degenerates to a few words per line. Both bounds sit on the step grid
    /// from the default so every press moves a full step.
    static let minFontSize = 15
    static let maxFontSize = 39
    static let fontSizeStep = 2
    static let defaultFontSize = 19

    static func makeDocument(article: ReaderArticle,
                             style: ReaderStyle,
                             appearanceIsDark: Bool) -> String {
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
        <article>\(article.contentHTML)</article>
        </main>
        </body>
        </html>
        """
    }

    /// Every style choice rides on the root element as a data attribute; the
    /// stylesheet carries every variant and the attributes pick one. Values
    /// come from closed enums, never from the page, so writing them into
    /// markup is safe by construction.
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
        /* Still links, just no longer shouting. */
        html[data-links="off"] a {
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
