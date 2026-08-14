// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// One site's extraction rule, as consumed by `ReaderExtract.js`.
///
/// The property names are the wire format on both sides: they are decoded
/// from the published table and re-encoded straight into the script's config,
/// so renaming one here breaks the rule rung silently. The authoritative
/// schema is `schema/rule.schema.json` in phibrowser/phi-reader-rules.
struct ReaderSiteRule: Codable, Equatable {
    /// Exact host, `*.suffix`, or `*contains*`.
    let host: String
    let pathPrefix: String?
    /// Restricts the rule to paths containing this substring.
    ///
    /// A prefix cannot express the shape a thread URL usually has: the part
    /// that identifies it sits in the middle, after a handle or a subreddit —
    /// `/r/programming/comments/…`, `/naval/status/…`. Without this a thread
    /// rule also fires on the subreddit listing and the home timeline, which
    /// are feeds, and the reader would present a page of unrelated posts as
    /// one conversation.
    let pathContains: String?
    /// Selectors for the article body, concatenated in document order. This
    /// is what makes an article split across sibling containers come out
    /// whole, which single-root selection cannot do.
    let content: [String]
    let strip: [String]?
    let expand: [String]?
    let title: String?
    let byline: String?
    let forceRung: String?
    /// Present when the page is a thread rather than an article, which turns
    /// each node `content` selects into its own post with a byline.
    let thread: ReaderSiteThread?
    /// Names a built-in way of getting the article from somewhere other than
    /// the page's markup, for a document the browser cannot read by selecting
    /// elements at all. The capability lives in the extraction script; a rule
    /// only chooses which sites use it, so a rule can never name a URL of its
    /// own for the browser to fetch.
    let source: String?
}

/// How to render one post of a thread.
///
/// Every field is either a selector run inside the post, or `@name` to read an
/// attribute off the post element. The attribute form exists because Reddit
/// hangs a comment's author, score and nesting depth on the
/// `shreddit-comment` element itself, with nothing inside carrying them.
struct ReaderSiteThread: Codable, Equatable {
    /// The post's text. Absent means the whole post, which is only right when
    /// the container holds nothing but the body.
    let body: String?
    let author: String?
    /// Score, timestamp, or whatever else belongs beside the author.
    let meta: String?
    /// Nesting depth for a comment tree, indented up to a fixed maximum.
    let depth: String?
}

struct ReaderSiteRuleTable: Codable, Equatable {
    let formatVersion: Int
    let rules: [ReaderSiteRule]

    static let empty = ReaderSiteRuleTable(formatVersion: 0, rules: [])

    /// The most specific rule matching `url`, or nil.
    ///
    /// Specificity matches Space routing: longer path prefix first, then exact
    /// host over `*.suffix` over `*contains*`, and a `pathContains` rule over
    /// one without. Ties go to the earlier rule, and the published table is
    /// sorted, so the choice is stable.
    ///
    /// `pathContains` is scored here rather than in `URLPatternMatcher`
    /// because Space routing has no such concept, and giving the shared
    /// matcher a field only one caller uses would be the wrong trade.
    ///
    /// Lookup lives on the table rather than on the store because it is pure:
    /// it needs no disk, no network, and no main actor.
    func rule(for url: URL) -> ReaderSiteRule? {
        guard let target = URLPatternMatcher.target(for: url) else { return nil }

        var best: (rule: ReaderSiteRule, specificity: (Int, Int, Int))?
        for rule in rules {
            guard URLPatternMatcher.hostMatches(pattern: rule.host,
                                                host: target.host) else { continue }
            guard URLPatternMatcher.pathMatches(prefix: rule.pathPrefix,
                                                path: target.path) else { continue }
            if let needle = rule.pathContains, !target.path.contains(needle) {
                continue
            }
            let shared = URLPatternMatcher.specificity(host: rule.host,
                                                       pathPrefix: rule.pathPrefix)
            let score = (shared.0, shared.1, rule.pathContains == nil ? 0 : 1)
            if best == nil || score > best!.specificity {
                best = (rule, score)
            }
        }
        return best?.rule
    }

    func rule(forURLString urlString: String?) -> ReaderSiteRule? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return rule(for: url)
    }
}

/// Owns the Reader View site-rule corpus: which rule applies to a URL, and
/// keeping the corpus current.
///
/// Three sources, in descending precedence, so Reader View never depends on
/// the network being reachable:
///
/// 1. the table last downloaded and verified, persisted to Application Support
/// 2. the baseline bundled in `Resources/ReaderSiteRules.json`
/// 3. no rules at all, which only costs the first rung of the ladder
///
/// Rules are data rather than code precisely so a site fix does not wait for
/// a browser build, which is the whole reason this is fetched at runtime.
@MainActor
final class ReaderSiteRuleStore {

    static let shared = ReaderSiteRuleStore()

    /// How long a verified table is considered current. Rules change on the
    /// scale of a merged pull request, not minutes, and every check costs a
    /// request whether or not anything moved.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    /// How soon to try again after a failed check. A launch that races the
    /// network coming up would otherwise pin a fresh rule out for the full
    /// interval, even though `refreshIfStale` fires on every reader entry.
    private static let failureRetryInterval: TimeInterval = 15 * 60

    private let downloader: ReaderSiteRulesDownloader
    private let fileManager: FileManager
    private let directory: URL
    private let tableURL: URL
    private let manifestURL: URL
    private var table: ReaderSiteRuleTable
    private var lastCheck: Date?
    private var lastCheckFailed = false
    /// Whether the pair on disk describes the table being served. The digest
    /// short-circuit in `refresh()` is only sound when it does: a cached
    /// table that fails to load leaves the bundled baseline serving behind a
    /// manifest that still matches the published digest, which would
    /// otherwise pin the store to the baseline until the digest happens to
    /// move. False from init when the persisted table did not load; true
    /// again once a refresh has decoded a fresh one.
    private var tableMatchesDisk: Bool
    /// Coalesces the launch refresh with the one a reader entry can kick off.
    private var inFlight: Task<Void, Never>?

    init(downloader: ReaderSiteRulesDownloader = ReaderSiteRulesDownloader(),
         fileManager: FileManager = .default,
         directory: URL = ReaderSiteRuleStore.defaultDirectory) {
        self.downloader = downloader
        self.fileManager = fileManager
        self.directory = directory
        let tableURL = directory.appendingPathComponent("rules.json")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        self.tableURL = tableURL
        self.manifestURL = manifestURL
        let persisted = Self.loadPersisted(from: tableURL)
        self.table = persisted
            ?? Self.loadBundled()
            ?? .empty
        self.tableMatchesDisk = persisted != nil
        self.lastCheck = Self.persistedCheckDate(at: manifestURL,
                                                 fileManager: fileManager)
    }

    var ruleCount: Int { table.rules.count }

    // MARK: - Lookup

    func rule(for url: URL) -> ReaderSiteRule? {
        table.rule(for: url)
    }

    func rule(forURLString urlString: String?) -> ReaderSiteRule? {
        table.rule(forURLString: urlString)
    }

    // MARK: - Refresh

    /// Checks for a newer table if the last check has aged out. Safe to call
    /// from anywhere and as often as convenient; concurrent calls share one
    /// request, and a failure is retried on the shorter interval rather than
    /// waiting out the full one.
    func refreshIfStale() {
        let interval = lastCheckFailed ? Self.failureRetryInterval
                                       : Self.refreshInterval
        if let lastCheck, Date().timeIntervalSince(lastCheck) < interval {
            return
        }
        guard inFlight == nil else { return }
        inFlight = Task { [weak self] in
            await self?.refresh()
            self?.inFlight = nil
        }
    }

    func refresh() async {
        do {
            let manifest = try await downloader.fetchManifest()

            // The manifest is small and the table is not, so a digest that
            // has not moved ends the check here. This is the common case.
            if let current = persistedDigest(), current == manifest.rules.sha256 {
                lastCheck = Date()
                lastCheckFailed = false
                persistCheckDate()
                AppLogDebug("[Reader] site rules unchanged at " +
                            "\(manifest.rules.sha256.prefix(12))")
                return
            }

            let data = try await downloader.fetchTable(for: manifest)
            let decoded = try JSONDecoder().decode(ReaderSiteRuleTable.self, from: data)
            guard decoded.formatVersion == ReaderSiteRulesDownloader.formatVersion else {
                throw ReaderSiteRulesDownloaderError.unsupportedFormat(decoded.formatVersion)
            }

            // Whole-table replacement, never a merge. A rule that was deleted
            // upstream because it broke has to actually disappear here.
            table = decoded
            // True even if the persist below fails: the stale manifest left
            // behind then disagrees with the published digest, so the next
            // check downloads again and retries the write.
            tableMatchesDisk = true
            lastCheck = Date()
            lastCheckFailed = false
            persist(table: data, manifest: manifest)
            AppLogDebug("[Reader] site rules updated to " +
                        "\(manifest.rules.sha256.prefix(12)), \(decoded.rules.count) rule(s)")
        } catch {
            // The persisted or bundled table stays in use. Reader View is
            // fully functional without any rules at all, so this is never
            // worth surfacing.
            lastCheck = Date()
            lastCheckFailed = true
            AppLogDebug("[Reader] site rules refresh failed: \(error)")
        }
    }

    // MARK: - Persistence

    /// Where the store keeps its verified table. An init parameter overrides
    /// it so tests can stage cache states in a temporary directory.
    nonisolated static var defaultDirectory: URL {
        URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory())
            .appendingPathComponent("ReaderSiteRules", isDirectory: true)
    }

    private static func loadPersisted(from url: URL) -> ReaderSiteRuleTable? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ReaderSiteRuleTable.self, from: data),
              decoded.formatVersion == ReaderSiteRulesDownloader.formatVersion else {
            return nil
        }
        return decoded
    }

    private static func loadBundled() -> ReaderSiteRuleTable? {
        // The same format guard as the persisted path. The baseline ships
        // with the binary, so a mismatch is a build error — but enforcing it
        // in one loader and not the other invites drift when the format bumps.
        guard let url = Bundle.main.url(forResource: "ReaderSiteRules",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ReaderSiteRuleTable.self, from: data),
              decoded.formatVersion == ReaderSiteRulesDownloader.formatVersion else {
            return nil
        }
        return decoded
    }

    private static func persistedCheckDate(at url: URL,
                                           fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate]
            as? Date
    }

    /// The digest the on-disk pair vouches for, or nil when it vouches for
    /// nothing. Internal rather than private so tests can pin the staleness
    /// decision without reaching the network; nothing else should read it.
    func persistedDigest() -> String? {
        // A manifest can only vouch for the table written beside it. When
        // that table failed to load, the store is serving the bundled
        // baseline, and honouring the digest would keep it there.
        guard tableMatchesDisk else { return nil }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ReaderSiteRulesManifest.self,
                                                       from: data) else {
            return nil
        }
        // A digest recorded without the table beside it would skip a download
        // the store still needs.
        guard fileManager.fileExists(atPath: tableURL.path) else {
            return nil
        }
        return manifest.rules.sha256
    }

    private func persist(table data: Data, manifest: ReaderSiteRulesManifest) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Table first: a manifest on disk is the claim that the matching
            // table is there too, so writing it first would make an
            // interrupted update look complete.
            try data.write(to: tableURL, options: .atomic)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: manifestURL, options: .atomic)
        } catch {
            AppLogError("[Reader] failed to persist site rules: \(error)")
        }
    }

    /// Records that a check happened even though nothing changed, so a stable
    /// corpus is not re-checked on every reader entry.
    private func persistCheckDate() {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return }
        try? fileManager.setAttributes([.modificationDate: Date()],
                                       ofItemAtPath: manifestURL.path)
    }
}
