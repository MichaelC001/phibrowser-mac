// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Turns an accessibility snapshot into a reader article.
///
/// This is the PDF path. A PDF has no article DOM, so Readability cannot see
/// it; the plugin's accessibility tree is the only place its text, headings,
/// and reading order exist. Chromium's own Reading Mode reaches the same
/// conclusion and forces the accessibility path for PDFs.
///
/// The same walk also serves as a last resort for HTML pages whose markup
/// defeats the DOM rungs, since roles survive where class names do not.
enum ReaderAccessibilityExtractor {

    /// Roles whose subtree is page furniture rather than content. `banner` and
    /// `contentInfo` also carry the PDF OCR status markers, which must not
    /// appear in the article.
    private static let skippedRoles: Set<String> = [
        "banner", "contentInfo", "navigation", "complementary",
        "footer", "toolbar", "menu", "menuBar", "search", "form",
    ]

    /// Roles that end a block: their combined descendant text becomes one
    /// paragraph or heading.
    private static let blockRoles: Set<String> = [
        "paragraph", "heading",
    ]

    /// Figure roles. The accessibility tree carries a description and the
    /// reading position of an image, but never its pixels, so these become
    /// captioned placeholders rather than pictures. See the note on
    /// `figurePlaceholder`.
    private static let figureRoles: Set<String> = [
        "image", "figure",
    ]

    private static let minimumTextLength = 200

    static func article(from snapshot: [String: Any],
                        fallbackTitle: String,
                        sourceURL: String) throws -> ReaderArticle {
        guard let rawNodes = snapshot["nodes"] as? [[String: Any]],
              !rawNodes.isEmpty,
              let rootId = snapshot["rootId"] as? Int else {
            throw ReaderExtractionError.noArticleDetected
        }

        var byId: [Int: [String: Any]] = [:]
        byId.reserveCapacity(rawNodes.count)
        for node in rawNodes {
            if let id = node["id"] as? Int {
                byId[id] = node
            }
        }
        guard byId[rootId] != nil else {
            throw ReaderExtractionError.noArticleDetected
        }

        var blocks: [String] = []
        var textLength = 0
        var firstHeading: String?
        // Where each figure landed, so a caption that turns out to repeat can
        // be withdrawn once the whole document has been walked.
        var figureCaptionByBlock: [Int: String] = [:]

        // Iterative walk: PDFs can nest deeply enough that recursion is a
        // needless risk, and the traversal is a simple pre-order.
        var stack: [Int] = [rootId]
        var visited = Set<Int>()

        while let id = stack.popLast() {
            guard visited.insert(id).inserted, let node = byId[id] else { continue }
            let role = node["role"] as? String ?? ""

            if skippedRoles.contains(role) {
                continue
            }

            if figureRoles.contains(role) {
                if let caption = figureCaption(for: id, in: byId) {
                    figureCaptionByBlock[blocks.count] = caption
                    blocks.append(figurePlaceholder(caption: caption))
                }
                continue
            }

            if blockRoles.contains(role) {
                let text = collectText(from: id, in: byId)
                if !text.isEmpty {
                    textLength += text.count
                    if role == "heading" {
                        let level = min(max(node["level"] as? Int ?? 2, 2), 6)
                        if firstHeading == nil {
                            firstHeading = text
                        }
                        blocks.append("<h\(level)>\(escape(text))</h\(level)>")
                    } else {
                        blocks.append("<p>\(escape(text))</p>")
                    }
                }
                // The block owns its subtree; do not descend further.
                continue
            }

            // Push children in reverse so the walk stays in document order.
            if let children = node["children"] as? [Int] {
                stack.append(contentsOf: children.reversed())
            }
        }

        guard textLength >= minimumTextLength else {
            throw ReaderExtractionError.noArticleDetected
        }

        blocks = withoutRepeatedFigures(blocks, captions: figureCaptionByBlock)

        let title = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReaderArticle(
            title: title.isEmpty ? (firstHeading ?? "") : title,
            byline: nil,
            siteName: nil,
            lang: nil,
            contentHTML: blocks.joined(separator: "\n"),
            sourceURL: sourceURL,
            rung: "accessibility",
            // The coverage ratio is meaningless here: there is no comparable
            // "visible page text" to measure a PDF against, so the minimum
            // length check above is the gate instead.
            coverage: 1.0)
    }

    /// Renders a figure as a captioned placeholder.
    ///
    /// The accessibility tree exposes an image's description and where it sits
    /// in the reading order, but not the image itself — the pixels live in the
    /// PDF's content stream, which only PDFium can rasterise. Showing the
    /// caption at the right point keeps the document's structure honest
    /// instead of silently dropping the figure. Untitled images are dropped,
    /// since an empty box tells the reader nothing.
    /// A figure whose caption occurs this many times or more is page
    /// furniture, not a figure. A real caption describes one picture and is
    /// unique; a running header or footer logo repeats on every page.
    private static let repeatedFigureThreshold = 3

    /// Drops figures whose caption repeats across the document.
    ///
    /// This is what removes a PDF's running header and footer imagery. The
    /// alternative signals do not survive contact with real documents: the
    /// page has no position information in the accessibility tree to test
    /// "near the top", and the platform's synthesised description for an
    /// image with no alt text is localised, so it cannot be matched as a
    /// string. Repetition needs neither and is what actually distinguishes
    /// furniture from content — the reported case was a header logo appearing
    /// 62 times in a 66-page book.
    ///
    /// Deliberately not applied to text blocks. A book repeats real sentences
    /// too — "Sun Tzu said" opens most verses of the reported document — and
    /// deleting those would be far worse than leaving a header in.
    private static func withoutRepeatedFigures(_ blocks: [String],
                                               captions: [Int: String]) -> [String] {
        guard !captions.isEmpty else { return blocks }
        var occurrences: [String: Int] = [:]
        for caption in captions.values {
            occurrences[caption, default: 0] += 1
        }
        let repeated = Set(occurrences.filter { $0.value >= repeatedFigureThreshold }.keys)
        guard !repeated.isEmpty else { return blocks }

        return blocks.enumerated().compactMap { index, block in
            if let caption = captions[index], repeated.contains(caption) {
                return nil
            }
            return block
        }
    }

    /// Read straight off the node rather than through `collectText`, which
    /// deliberately ignores figures so an image's description never lands in
    /// a paragraph's text.
    private static func figureCaption(for id: Int,
                                      in byId: [Int: [String: Any]]) -> String? {
        guard let name = byId[id]?["name"] as? String else { return nil }
        let caption = sanitize(name)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return caption.isEmpty ? nil : caption
    }

    private static func figurePlaceholder(caption: String) -> String {
        "<figure class=\"phi-figure-placeholder\">"
            + "<figcaption>\(escape(caption))</figcaption></figure>"
    }

    /// Concatenates the text carried by a node and its descendants. PDF text
    /// hangs off `staticText` children rather than the block itself.
    private static func collectText(from id: Int,
                                    in byId: [Int: [String: Any]]) -> String {
        var parts: [String] = []
        var stack: [Int] = [id]
        var visited = Set<Int>()

        while let current = stack.popLast() {
            guard visited.insert(current).inserted,
                  let node = byId[current] else { continue }
            let role = node["role"] as? String ?? ""
            // An image's name is a description of it, not text on the page,
            // and a PDF image without alt text gets a synthesised one —
            // "Unlabeled image", localised. A page-header logo repeated on
            // every page therefore reads as a paragraph of that phrase once
            // reflowed: 62 of them in a 66-page book. Images are handled by
            // `figurePlaceholder` at the walk level, where a description that
            // does mean something still gets shown.
            if figureRoles.contains(role) {
                continue
            }
            let children = node["children"] as? [Int] ?? []
            // A container's accessible name is computed *from* its
            // descendants, so taking both prints the text twice. Reddit labels
            // its comment area with a screen-reader-only <h1>: the heading node
            // is named "Comments Section" and owns a staticText child saying
            // the same, and the reader showed "Comments Section Comments
            // Section". So a name is only text when the node has nothing below
            // it to say it instead.
            //
            // inlineTextBox is the same duplication one level lower — it
            // repeats its parent staticText word for word — and staticText is
            // where PDF text actually lives, so it keeps its name even though
            // it has inlineTextBox children.
            let saysItSelf = role == "staticText" || children.isEmpty
            if role != "inlineTextBox", saysItSelf,
               let name = node["name"] as? String, !name.isEmpty {
                parts.append(name)
            }
            if role == "staticText" {
                continue
            }
            stack.append(contentsOf: children.reversed())
        }

        return sanitize(parts.joined(separator: " "))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips characters that carry no meaning once the text is reflowed.
    ///
    /// A PDF hyphenates across line breaks, and the break marker survives into
    /// the accessibility text as a soft hyphen or an unmapped codepoint. In a
    /// fixed-layout page it is invisible; in the reader it lands mid-word and
    /// renders as a missing-glyph box ("relia□bility"). Dropping it also
    /// rejoins the word, which is the correct result for reflowed text.
    ///
    /// Format, control, private-use, and unassigned scalars all go, since none
    /// of them survive reflow usefully. Real hyphens (U+002D) are deliberately
    /// left alone so genuinely hyphenated words like "multi-user" keep theirs.
    private static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned,
                 .lineSeparator, .paragraphSeparator:
                continue
            default:
                // The replacement character is a symbol, so it needs naming.
                if scalar == "\u{FFFD}" { continue }
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}
