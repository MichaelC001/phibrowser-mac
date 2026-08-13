// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Tests for site-rule lookup and for the wire format shared with
/// phibrowser/phi-reader-rules.
///
/// Matching semantics themselves are pinned by `URLRouterTests`, which covers
/// the same `URLPatternMatcher` primitives. What is pinned here is the part
/// specific to Reader View: which rule wins, and that the published JSON still
/// decodes into the shape the extraction script expects.
final class ReaderSiteRuleStoreTests: XCTestCase {

    private func rule(_ host: String,
                      path: String? = nil,
                      pathContains: String? = nil,
                      content: [String] = [".article"],
                      strip: [String]? = nil,
                      expand: [String]? = nil,
                      title: String? = nil,
                      byline: String? = nil,
                      forceRung: String? = nil,
                      thread: ReaderSiteThread? = nil,
                      source: String? = nil) -> ReaderSiteRule {
        ReaderSiteRule(host: host,
                       pathPrefix: path,
                       pathContains: pathContains,
                       content: content,
                       strip: strip,
                       expand: expand,
                       title: title,
                       byline: byline,
                       forceRung: forceRung,
                       thread: thread,
                       source: source)
    }

    private func lookup(_ rules: [ReaderSiteRule], _ urlString: String?)
        -> ReaderSiteRule? {
        ReaderSiteRuleTable(formatVersion: 1, rules: rules)
            .rule(forURLString: urlString)
    }

    // MARK: - Selection

    func testMatchesASuffixWildcardAgainstTheBareHostAndSubdomains() {
        let rules = [rule("*.example.com")]
        XCTAssertNotNil(lookup(rules, "https://example.com/a"))
        XCTAssertNotNil(lookup(rules, "https://news.example.com/a"))
        XCTAssertNil(lookup(rules, "https://notexample.com/a"))
    }

    func testPrefersAnExactHostOverASuffixWildcard() {
        let rules = [rule("*.example.com", content: [".wildcard"]),
                     rule("news.example.com", content: [".exact"])]
        let match = lookup(rules, "https://news.example.com/a")
        XCTAssertEqual(match?.content, [".exact"])
    }

    func testPrefersTheLongerPathPrefix() {
        let rules = [rule("*.example.com", path: "/blog", content: [".blog"]),
                     rule("*.example.com", path: "/blog/tech", content: [".tech"])]
        XCTAssertEqual(lookup(rules, "https://example.com/blog/tech/x")?.content,
                       [".tech"])
        XCTAssertEqual(lookup(rules, "https://example.com/blog/life/x")?.content,
                       [".blog"])
    }

    func testPathPrefixNeedsASlashBoundary() {
        let rules = [rule("*.example.com", path: "/blog")]
        XCTAssertNotNil(lookup(rules, "https://example.com/blog"))
        XCTAssertNotNil(lookup(rules, "https://example.com/blog/post"))
        XCTAssertNil(lookup(rules, "https://example.com/blogroll"))
    }

    // MARK: - Thread scoping

    func testPathContainsMatchesInTheMiddleOfAPath() {
        // The point of the field: a thread's identifying segment sits after a
        // subreddit or a handle, so no prefix can select it.
        let rules = [rule("*.reddit.com", pathContains: "/comments/")]
        XCTAssertNotNil(lookup(rules, "https://www.reddit.com/r/programming/comments/abc/title/"))
        XCTAssertNil(lookup(rules, "https://www.reddit.com/r/programming/"))
    }

    func testPathContainsKeepsAThreadRuleOffAFeed() {
        // Without this the x.com rule fires on the home timeline and presents
        // a page of unrelated posts as one conversation.
        let rules = [rule("x.com", pathContains: "/status/")]
        XCTAssertNotNil(lookup(rules, "https://x.com/naval/status/1002103360646823936"))
        XCTAssertNil(lookup(rules, "https://x.com/home"))
        XCTAssertNil(lookup(rules, "https://x.com/naval"))
    }

    func testPrefersARuleScopedByPathContains() {
        let rules = [rule("x.com", content: [".generic"]),
                     rule("x.com", pathContains: "/status/", content: [".thread"])]
        XCTAssertEqual(lookup(rules, "https://x.com/a/status/1")?.content, [".thread"])
        XCTAssertEqual(lookup(rules, "https://x.com/a")?.content, [".generic"])
    }

    func testIgnoresNonWebsiteURLs() {
        // A rule must never fire on the new-tab page, a local file, or a
        // devtools surface, where there is no site to have a rule about.
        let rules = [rule("*example*")]
        XCTAssertNil(lookup(rules, "chrome://newtab/"))
        XCTAssertNil(lookup(rules, "file:///tmp/example.html"))
        XCTAssertNil(lookup(rules, "data:text/html,example"))
    }

    func testReturnsNilWhenNothingMatches() {
        XCTAssertNil(lookup([rule("*.example.com")], "https://other.com/a"))
        XCTAssertNil(lookup([], "https://example.com/a"))
    }

    func testIgnoresAMalformedURLString() {
        XCTAssertNil(lookup([rule("*.example.com")], nil))
        XCTAssertNil(lookup([rule("*.example.com")], ""))
    }

    // MARK: - Wire format

    func testDecodesThePublishedTableShape() throws {
        // Byte-for-byte the shape tools/build.mjs emits, including the omitted
        // optional fields. If this stops decoding, the browser silently loses
        // every rule.
        let json = """
        {
          "formatVersion": 1,
          "rules": [
            {
              "host": "*.ruanyifeng.com",
              "pathPrefix": "/blog",
              "content": ["#main-content"],
              "title": "#page-title",
              "byline": ".asset-meta .author"
            }
          ]
        }
        """
        let table = try JSONDecoder().decode(ReaderSiteRuleTable.self,
                                             from: Data(json.utf8))
        XCTAssertEqual(table.formatVersion, 1)
        XCTAssertEqual(table.rules.count, 1)
        XCTAssertEqual(table.rules[0].content, ["#main-content"])
        XCTAssertNil(table.rules[0].strip)
        XCTAssertNil(table.rules[0].forceRung)
    }

    func testEncodesTheKeysTheExtractionScriptReads() throws {
        // ReaderExtract.js reads rule.content, rule.strip, rule.expand,
        // rule.title, rule.byline, rule.forceRung and rule.thread by name.
        let encoded = try JSONEncoder().encode(
            rule("*.example.com",
                 path: "/p",
                 content: [".a"],
                 strip: [".b"],
                 expand: [".c"],
                 title: "h1",
                 byline: ".by",
                 forceRung: "rule",
                 thread: ReaderSiteThread(body: ".body", author: "@author",
                                          meta: ".score", depth: "@depth"),
                 source: "googleDocsExport"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        for key in ["host", "pathPrefix", "content", "strip", "expand",
                    "title", "byline", "forceRung", "source"] {
            XCTAssertNotNil(object[key], "missing \(key)")
        }
        let thread = try XCTUnwrap(object["thread"] as? [String: Any])
        for key in ["body", "author", "meta", "depth"] {
            XCTAssertNotNil(thread[key], "missing thread.\(key)")
        }
    }

    func testDecodesAThreadRuleFromThePublishedTable() throws {
        // Byte-for-byte the shape tools/build.mjs now emits for Reddit. The
        // fields the browser silently loses if this stops decoding are the
        // ones that make a comment tree readable at all.
        let json = """
        {
          "formatVersion": 1,
          "rules": [
            {
              "host": "*.reddit.com",
              "pathContains": "/comments/",
              "content": ["shreddit-post", "shreddit-comment"],
              "title": "shreddit-post h1",
              "thread": {
                "body": "[slot=\\"text-body\\"], [slot=\\"comment\\"]",
                "author": "@author",
                "meta": "@score",
                "depth": "@depth"
              }
            }
          ]
        }
        """
        let table = try JSONDecoder().decode(ReaderSiteRuleTable.self,
                                             from: Data(json.utf8))
        let rule = try XCTUnwrap(table.rules.first)
        XCTAssertEqual(rule.pathContains, "/comments/")
        XCTAssertEqual(rule.thread?.author, "@author")
        XCTAssertEqual(rule.thread?.depth, "@depth")
    }

    func testTheBundledBaselineParses() throws {
        // The baseline is copied from the rules repository by hand, so a bad
        // copy would otherwise only show up as Reader View quietly losing its
        // rules on a fresh install.
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "ReaderSiteRules",
                                            withExtension: "json")
            ?? Bundle.main.url(forResource: "ReaderSiteRules", withExtension: "json"))
        let table = try JSONDecoder().decode(ReaderSiteRuleTable.self,
                                             from: Data(contentsOf: url))
        XCTAssertEqual(table.formatVersion, ReaderSiteRulesDownloader.formatVersion)
        XCTAssertFalse(table.rules.isEmpty)
        for rule in table.rules {
            // A source-driven rule selects nothing — it takes the article from
            // somewhere other than the page — but it must say where from.
            if rule.source != nil { continue }
            XCTAssertFalse(rule.content.isEmpty, "\(rule.host) has no content selector")
        }
        // The published payload always carries `content`, even empty: a
        // browser already in the field decodes it as required, and a missing
        // key would fail the whole table rather than the one rule.
        let sourceRules = table.rules.filter { $0.source != nil }
        XCTAssertFalse(sourceRules.isEmpty, "the baseline lost its source-driven rule")
        for rule in sourceRules {
            XCTAssertEqual(rule.source, "googleDocsExport")
        }
    }

    // MARK: - Source-driven rules

    func testDecodesASourceRuleWithNoSelectors() throws {
        // Byte-for-byte what tools/build.mjs emits for Google Docs. `content`
        // is present but empty on purpose: a browser already in the field
        // decodes it as required, and a missing key would fail the whole table
        // rather than this one rule.
        let json = """
        {
          "formatVersion": 1,
          "rules": [
            {
              "host": "docs.google.com",
              "pathContains": "/document/d/",
              "content": [],
              "source": "googleDocsExport"
            }
          ]
        }
        """
        let table = try JSONDecoder().decode(ReaderSiteRuleTable.self,
                                             from: Data(json.utf8))
        let rule = try XCTUnwrap(table.rules.first)
        XCTAssertEqual(rule.source, "googleDocsExport")
        XCTAssertTrue(rule.content.isEmpty)

        // It has to reach a document, and stay off everything else Google
        // serves from the same host.
        XCTAssertNotNil(table.rule(forURLString:
            "https://docs.google.com/document/d/1nW3yS/edit"))
        XCTAssertNil(table.rule(forURLString:
            "https://docs.google.com/spreadsheets/d/1nW3yS/edit"))
        XCTAssertNil(table.rule(forURLString:
            "https://docs.google.com/presentation/d/1nW3yS/edit"))
    }

    // MARK: - Payload URL safety

    func testResolvesTheManifestPayloadPathAgainstTheSiteRoot() throws {
        let url = try ReaderSiteRulesDownloader.payloadURL(for: "v1/rules.json")
        XCTAssertEqual(url.absoluteString,
                       "https://phibrowser.github.io/phi-reader-rules/v1/rules.json")
    }

    func testRejectsAPayloadPathThatLeavesThePublishedSite() {
        for path in ["", "/etc/passwd", "../secrets.json", "v1//rules.json",
                     "https://evil.example.com/rules.json"] {
            XCTAssertThrowsError(try ReaderSiteRulesDownloader.payloadURL(for: path),
                                 "expected \(path) to be rejected")
        }
    }
}
