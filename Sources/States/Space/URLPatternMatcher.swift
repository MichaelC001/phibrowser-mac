// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Host and path-prefix matching, shared by everything in Phi that routes a
/// URL through a table of patterns.
///
/// The semantics come from the C++ `phi::PhiURLRouter` in
/// `chrome/browser/phinomenon/phi_url_router.{h,cc}` and are pinned by
/// `URLRouterTests`. `URLRouter` relies on them to resolve a URL to a Space;
/// the Reader extension's rule matcher (`src/background/rules.ts` in
/// phi-ai/ai-extension/reader) is a TS port of the same ranking. They exist
/// here rather than in the caller so Swift cannot drift from the C++ side.
enum URLPatternMatcher {

    /// The lowercased host and percent-encoded path a pattern is matched
    /// against. Nil for anything that is not a website: `chrome:`, `file:`,
    /// `data:`, `view-source:`, and hostless URLs never match a rule.
    struct Target {
        let host: String
        let path: String
    }

    static func target(for url: URL) -> Target? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        // Use the percent-encoded path so non-ASCII characters survive in
        // their canonical form. GURL.path() on the C++ side returns the same
        // encoded shape, and stored path prefixes are already encoded, so
        // comparing against `url.path` (which Foundation percent-decodes)
        // would silently diverge for any prefix containing characters outside
        // `.urlPathAllowed`.
        // Empty path coerces to "/" so a pattern with no path prefix still
        // matches a host-only URL like `https://a`.
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedPath ?? ""
        return Target(host: host, path: encodedPath.isEmpty ? "/" : encodedPath)
    }

    /// Matches `host` against an exact host, a `*.suffix` wildcard, or a
    /// `*contains*` wildcard.
    static func hostMatches(pattern: String, host: String) -> Bool {
        let pattern = pattern.lowercased()
        // Contains form ("*needle*") must be detected before the suffix form:
        // a needle starting with "." (e.g. "*.git.*") also carries the "*."
        // prefix. Mirrors the flag compilation in PhiChromiumBridge.mm's
        // setSpaceRoutingTable.
        if pattern.count > 2, pattern.hasPrefix("*"), pattern.hasSuffix("*") {
            return host.contains(pattern.dropFirst().dropLast())
        }
        if !pattern.hasPrefix("*.") {
            return pattern == host
        }
        let bare = String(pattern.dropFirst(2))
        guard !bare.isEmpty else { return false }
        if host == bare { return true }
        // A wildcard "*.foo.com" matches sub-host "x.foo.com" but not
        // "barfoo.com" — require a dot before the bare suffix.
        guard host.count > bare.count + 1 else { return false }
        let suffixStart = host.index(host.endIndex, offsetBy: -(bare.count + 1))
        return host[suffixStart] == "." &&
               host[host.index(after: suffixStart)...] == bare
    }

    /// A nil or empty prefix matches every path.
    static func pathMatches(prefix: String?, path: String) -> Bool {
        guard let prefix, !prefix.isEmpty else { return true }
        guard path.hasPrefix(prefix) else { return false }
        // Require a "/" boundary so "/foo" doesn't match "/foobar".
        return path.count == prefix.count ||
               path[path.index(path.startIndex, offsetBy: prefix.count)] == "/"
    }

    /// Exact host (2) beats `*.suffix` (1) beats `*contains*` (0). Mirrors the
    /// C++ `Specificity()`.
    static func hostTier(_ pattern: String) -> Int {
        if pattern.count > 2, pattern.hasPrefix("*"), pattern.hasSuffix("*") {
            return 0
        }
        return pattern.hasPrefix("*.") ? 1 : 2
    }

    /// Ranks a matching pattern. Larger is more specific: longer path prefix
    /// first, then the host tier. Callers append their own final tiebreak.
    static func specificity(host: String, pathPrefix: String?) -> (Int, Int) {
        (pathPrefix?.count ?? 0, hostTier(host))
    }
}
