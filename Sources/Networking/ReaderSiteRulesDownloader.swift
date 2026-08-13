// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

/// The published description of the rule table. Downloaded on every check;
/// the table itself is downloaded only when `rules.sha256` has moved.
///
/// Encodable as well as Decodable because the store writes the manifest it
/// accepted next to the table it verified, and compares against it on the
/// next check.
struct ReaderSiteRulesManifest: Codable, Equatable {
    struct Payload: Codable, Equatable {
        /// Relative to the manifest's directory. Validated before use.
        let path: String
        let sha256: String
        let bytes: Int
        let count: Int
    }

    let formatVersion: Int
    let generatedAt: String?
    let revision: String?
    let rules: Payload
}

enum ReaderSiteRulesDownloaderError: Error, LocalizedError {
    case httpError(Int)
    case unsupportedFormat(Int)
    case unsafePayloadPath(String)
    case payloadTooLarge(Int)
    case sizeMismatch(expected: Int, actual: Int)
    case sha256Mismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let status):
            return "Reader site rules request failed with HTTP status \(status)."
        case .unsupportedFormat(let version):
            return "Reader site rules use unsupported format version \(version)."
        case .unsafePayloadPath(let path):
            return "Reader site rules manifest names an unusable payload path \(path)."
        case .payloadTooLarge(let bytes):
            return "Reader site rules payload of \(bytes) bytes exceeds the ceiling."
        case .sizeMismatch(let expected, let actual):
            return "Reader site rules payload is \(actual) bytes, manifest says \(expected)."
        case .sha256Mismatch(let expected, let actual):
            return "Reader site rules SHA-256 mismatch. Expected \(expected), got \(actual)."
        }
    }
}

/// Fetches the Reader View site-rule table from
/// `github.com/phibrowser/phi-reader-rules`, published to GitHub Pages by CI.
///
/// The rules are public data with no user identity attached, so the request
/// carries no credentials and is deliberately not routed through `APIClient`:
/// there is nothing to authenticate, and sending an access token to a static
/// host outside the Phi API surface would be worse, not better.
struct ReaderSiteRulesDownloader {

    /// The one format version this client understands. Bumping the published
    /// format means bumping the path, so an older browser keeps reading the
    /// table it was built against rather than failing.
    static let formatVersion = 1

    static let manifestURL = URL(
        string: "https://phibrowser.github.io/phi-reader-rules/v1/manifest.json")!

    /// Well over the corpus's plausible size, and small enough that a
    /// misbehaving host cannot make the browser download something large.
    private static let maximumPayloadBytes = 4 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchManifest() async throws -> ReaderSiteRulesManifest {
        let data = try await fetch(Self.uncached(Self.manifestURL))

        let manifest = try JSONDecoder().decode(ReaderSiteRulesManifest.self, from: data)
        guard manifest.formatVersion == Self.formatVersion else {
            throw ReaderSiteRulesDownloaderError.unsupportedFormat(manifest.formatVersion)
        }
        guard manifest.rules.bytes <= Self.maximumPayloadBytes else {
            throw ReaderSiteRulesDownloaderError.payloadTooLarge(manifest.rules.bytes)
        }
        return manifest
    }

    /// Downloads and verifies the table. Returns the raw bytes so the caller
    /// persists exactly what was hashed.
    func fetchTable(for manifest: ReaderSiteRulesManifest) async throws -> Data {
        let url = try Self.payloadURL(for: manifest.rules.path)
        let data = try await fetch(Self.uncached(url))

        // Both checks run against what actually arrived. Size first, because
        // it is the cheaper way to reject a truncated or substituted body.
        guard data.count == manifest.rules.bytes else {
            throw ReaderSiteRulesDownloaderError.sizeMismatch(
                expected: manifest.rules.bytes, actual: data.count)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let expected = manifest.rules.sha256.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard digest == expected else {
            throw ReaderSiteRulesDownloaderError.sha256Mismatch(
                expected: expected, actual: digest)
        }
        return data
    }

    /// Resolves the manifest's payload path against the manifest's own
    /// directory, and refuses anything that would leave the published site.
    /// The manifest is fetched over TLS from a host we control, so this is
    /// defence in depth rather than the primary protection, but it keeps a
    /// bad manifest from pointing the browser at an arbitrary origin.
    static func payloadURL(for path: String) throws -> URL {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains(".."),
              !path.contains("//"),
              URL(string: path)?.scheme == nil else {
            throw ReaderSiteRulesDownloaderError.unsafePayloadPath(path)
        }
        // The manifest sits at .../v1/manifest.json and its `path` is stated
        // relative to the site root, so resolve against the root.
        let siteRoot = manifestURL
            .deletingLastPathComponent()   // .../v1/
            .deletingLastPathComponent()   // .../
        guard let url = URL(string: path, relativeTo: siteRoot)?.absoluteURL,
              url.host == manifestURL.host else {
            throw ReaderSiteRulesDownloaderError.unsafePayloadPath(path)
        }
        return url
    }

    /// Both legs bypass the HTTP cache, and the table's leg is the one that
    /// matters: a cached body served against a freshly fetched manifest is a
    /// stale table paired with a new digest, which fails verification and
    /// leaves the client unable to update until the cache expires. Caching
    /// buys nothing here anyway, because the table is only ever fetched when
    /// its digest has already been seen to change.
    private static func uncached(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ReaderSiteRulesDownloaderError.httpError(http.statusCode)
        }
        guard data.count <= Self.maximumPayloadBytes else {
            throw ReaderSiteRulesDownloaderError.payloadTooLarge(data.count)
        }
        return data
    }
}
