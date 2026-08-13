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

    /// What the user last chose.
    @MainActor
    static var current: ReaderStyle {
        ReaderStyle(fontSize: PhiPreferences.Reader.fontSize,
                    width: PhiPreferences.Reader.width,
                    theme: PhiPreferences.Reader.theme,
                    typeface: PhiPreferences.Reader.typeface)
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
    enum Theme: String, CaseIterable {
        case matchBrowser, light, sepia, dark

        /// The concrete palette this resolves to. `matchBrowser` is a
        /// preference, not a palette, so the document is always told a real
        /// one — which is also what lets the appearance change swap the
        /// palette in place instead of rebuilding.
        func resolved(appearanceIsDark: Bool) -> Theme {
            self == .matchBrowser ? (appearanceIsDark ? .dark : .light) : self
        }

        /// Whether this theme wants the dark palette. `matchBrowser` defers to
        /// the caller, which is the only one that knows the app's appearance.
        func isDark(appearanceIsDark: Bool) -> Bool {
            switch self {
            case .matchBrowser: return appearanceIsDark
            case .light, .sepia: return false
            case .dark: return true
            }
        }
    }

    enum Typeface: String, CaseIterable {
        case serif, sans

        var cssFontFamily: String {
            switch self {
            case .serif:
                return "Georgia, \"Times New Roman\", serif"
            case .sans:
                return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif"
            }
        }
    }
}
