// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// How the reader presents an article: everything the reader's own controls
/// change, in one value.
///
/// Grouped rather than passed as loose parameters because the document builder
/// needs all of it at once and every addition would otherwise widen the same
/// call in several places.
struct ReaderStyle: Equatable {
    var fontSize: Int
    var width: Width
    var theme: Theme
    var typeface: Typeface
    var lineHeight: LineHeight
    var letterSpacing: LetterSpacing
    /// Whether illustrations are shown. Off is a reading preference rather
    /// than a bandwidth one — the pixels are already fetched by the time the
    /// reader could hide them — for the reader who wants prose and nothing
    /// else. Inline SVG stays: a formula is not an illustration.
    var showsImages: Bool
    /// Whether links are tinted and underlined. Off leaves them as body text,
    /// still clickable but no longer interrupting the line, which is what
    /// makes a heavily cross-referenced page readable straight through.
    var highlightsLinks: Bool

    /// What a fresh install reads at, and what the reader's reset returns to.
    /// The preference store falls back to these rather than restating them, so
    /// there is one answer to what "default" means.
    static let standard = ReaderStyle(
        fontSize: ReaderDocumentBuilder.defaultFontSize,
        width: .normal,
        theme: .matchBrowser,
        typeface: .serif,
        lineHeight: .normal,
        letterSpacing: .normal,
        showsImages: true,
        highlightsLinks: true)

    /// What the user last chose.
    @MainActor
    static var current: ReaderStyle {
        ReaderStyle(fontSize: PhiPreferences.Reader.fontSize,
                    width: PhiPreferences.Reader.width,
                    theme: PhiPreferences.Reader.theme,
                    typeface: PhiPreferences.Reader.typeface,
                    lineHeight: PhiPreferences.Reader.lineHeight,
                    letterSpacing: PhiPreferences.Reader.letterSpacing,
                    showsImages: PhiPreferences.Reader.showsImages,
                    highlightsLinks: PhiPreferences.Reader.highlightsLinks)
    }

    /// Content column width.
    ///
    /// A measure of roughly 60 to 75 characters is what typography holds to be
    /// comfortable, which is where `normal` sits. The wider settings exist
    /// because they are asked for — reference pages and tables want the room,
    /// and a wide display makes a narrow column look stranded.
    enum Width: String, CaseIterable {
        case narrow, normal, wide, full

        /// The CSS `max-width` of the content column, in `em` so it tracks the
        /// text size rather than fighting it.
        var maxWidth: String {
            switch self {
            case .narrow: return "32em"
            case .normal: return "40em"
            case .wide: return "56em"
            case .full: return "none"
            }
        }
    }

    /// Reading background. `matchBrowser` is the default and the old
    /// behaviour: the reader follows the app's light or dark appearance.
    /// The rest are fixed regardless of the browser, because a reading
    /// surface is the one place people want their own preference to stick.
    ///
    /// Ordered light to dark so the menu reads as a scale rather than a list.
    enum Theme: String, CaseIterable {
        case matchBrowser, light, sepia, yellow, blue, dark, dim, contrast

        /// The concrete palette this resolves to. `matchBrowser` is a
        /// preference, not a palette, so the document is always told a real
        /// one — which is also what lets the appearance change swap the
        /// palette in place instead of rebuilding.
        func resolved(appearanceIsDark: Bool) -> Theme {
            self == .matchBrowser ? (appearanceIsDark ? .dark : .light) : self
        }
    }

    /// Body typeface. Headings and captions stay on the system sans face in
    /// every case: the pairing is the reader's own design, and the choice here
    /// is about the prose someone reads for minutes at a time.
    enum Typeface: String, CaseIterable {
        case serif, sans, book, rounded, mono

        var cssFontFamily: String {
            switch self {
            case .serif:
                return "Georgia, \"Times New Roman\", serif"
            case .sans:
                return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif"
            case .book:
                // The face Apple's own reading apps set books in: an old-style
                // text serif, lighter on the page than Georgia, which was cut
                // for screens that no longer exist.
                return "\"Iowan Old Style\", Palatino, \"Book Antiqua\", Georgia, serif"
            case .rounded:
                return "ui-rounded, \"SF Pro Rounded\", " +
                    "\"Hiragino Maru Gothic ProN\", -apple-system, sans-serif"
            case .mono:
                return "ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, monospace"
            }
        }
    }

    /// Space between lines. The default is the 1.65 the reader has always
    /// used; the rest exist because line spacing is the single most effective
    /// adjustment for someone who loses their place between lines.
    enum LineHeight: String, CaseIterable {
        case tight, normal, relaxed, loose

        var cssLineHeight: String {
            switch self {
            case .tight: return "1.4"
            case .normal: return "1.65"
            case .relaxed: return "1.9"
            case .loose: return "2.15"
            }
        }
    }

    /// Space between characters. Widened tracking separates letters that
    /// crowd each other, which is the other half of the same accessibility
    /// need line height answers.
    enum LetterSpacing: String, CaseIterable {
        case normal, wide, wider

        var cssLetterSpacing: String {
            switch self {
            case .normal: return "normal"
            case .wide: return "0.02em"
            case .wider: return "0.06em"
            }
        }
    }
}
