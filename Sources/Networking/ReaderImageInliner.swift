// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Rewrites a reader document's remote images as `data:` URIs so the exported
/// file stands on its own.
///
/// An exported article that still points at the origin for its pictures is not
/// really one file: it breaks offline, and it quietly tells the origin every
/// time the saved copy is opened. Inlining costs size, which is why the
/// budgets below exist — an image that cannot be inlined keeps its original
/// URL rather than being dropped, so the export degrades to what it was
/// instead of losing the figure.
///
/// Not routed through `APIClient`: these are arbitrary third-party image URLs
/// taken from the article, carrying no Phi identity, and sending an access
/// token to them would be a defect rather than an improvement.
struct ReaderImageInliner {

    /// Skipped above this size. A hero photograph is worth carrying; a video
    /// poster or a print-resolution scan makes the file unusable.
    static let maximumImageBytes = 3 * 1024 * 1024
    /// Total budget across the document, so a gallery cannot produce a file
    /// too large to open or mail.
    static let maximumTotalBytes = 24 * 1024 * 1024
    /// Bounded so one unresponsive host cannot hold up the whole export.
    private static let requestTimeout: TimeInterval = 10

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns `html` with every inlinable image replaced by a data URI.
    func inlineImages(in html: String) async -> String {
        let sources = Self.imageSources(in: html)
        guard !sources.isEmpty else { return html }

        var replacements: [String: String] = [:]
        var used = 0
        // Sequential on purpose: the budget is a running total, and a parallel
        // pass would have to overshoot it to know it had.
        for source in sources {
            guard used < Self.maximumTotalBytes else { break }
            guard let encoded = await dataURI(for: source) else { continue }
            used += encoded.utf8.count
            replacements[source] = encoded
        }

        var result = html
        for (source, encoded) in replacements {
            result = result.replacingOccurrences(of: "src=\"\(source)\"",
                                                 with: "src=\"\(encoded)\"")
        }
        return result
    }

    private func dataURI(for source: String) async -> String? {
        guard let url = URL(string: source),
              url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout

        guard let (data, response) = try? await session.data(for: request) else {
            return nil
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            return nil
        }
        guard !data.isEmpty, data.count <= Self.maximumImageBytes else {
            return nil
        }
        let mime = response.mimeType ?? "application/octet-stream"
        guard mime.hasPrefix("image/") else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// The distinct `src` values worth fetching. Anything already inline, or
    /// not a URL we can fetch, is left alone.
    static func imageSources(in html: String) -> [String] {
        guard let pattern = try? NSRegularExpression(
            pattern: "<img[^>]+src=\"([^\"]+)\"", options: .caseInsensitive) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var sources: [String] = []
        var seen = Set<String>()
        for match in pattern.matches(in: html, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: html) else { continue }
            let source = String(html[valueRange])
            guard source.range(of: "^https?://", options: [.regularExpression,
                                                           .caseInsensitive]) != nil,
                  seen.insert(source).inserted else { continue }
            sources.append(source)
        }
        return sources
    }
}
