import Foundation
import XCTest
@testable import PastaCore

final class SearchServiceTests: XCTestCase {
    func testSearchFindsExactMatches() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try db.insert(ClipboardEntry(content: "hello there", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)))

        let service = SearchService(database: db)
        let results = try service.search(query: "hello", limit: 10)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.entry.content.lowercased().contains("hello") })
    }

    func testFuzzySearchFindsApproximateMatches() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try db.insert(ClipboardEntry(content: "completely different text that should not match", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)))

        let service = SearchService(database: db)
        // "helo" should fuzzy-match "hello world"
        let results = try service.search(query: "helo", limit: 10)

        // Should find hello world via fuzzy match
        XCTAssertTrue(results.contains(where: { $0.entry.content == "hello world" }), "Should find 'hello world' via fuzzy match")
        // The first result should be the better match
        XCTAssertEqual(results.first?.entry.content, "hello world", "Best match should be 'hello world'")
    }

    func testSearchSupportsPinnedOnlyFilter() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello pinned", contentType: .text, timestamp: Date(timeIntervalSince1970: 1), isPinned: true))
        try db.insert(ClipboardEntry(content: "hello unpinned", contentType: .text, timestamp: Date(timeIntervalSince1970: 2), isPinned: false))
        try db.insert(ClipboardEntry(content: "another hello also pinned", contentType: .text, timestamp: Date(timeIntervalSince1970: 3), isPinned: true))

        // Direct DatabaseManager.searchFTS call
        let dbResults = try db.searchFTS(query: "hello", contentType: nil, limit: 10, pinnedOnly: true)
        XCTAssertEqual(dbResults.count, 2)
        XCTAssertTrue(dbResults.allSatisfy { $0.isPinned })

        // SearchService surfaces pinnedOnly through to FTS
        let service = SearchService(database: db)
        let serviceResults = try service.search(query: "hello", limit: 10, pinnedOnly: true)
        XCTAssertEqual(serviceResults.count, 2)
        XCTAssertTrue(serviceResults.allSatisfy { $0.entry.isPinned })

        // Without pinnedOnly we still see all three
        let allResults = try service.search(query: "hello", limit: 10)
        XCTAssertEqual(allResults.count, 3)
    }

    func testSearchSupportsContentTypeFiltering() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try db.insert(ClipboardEntry(content: "hello@example.com", contentType: .email, timestamp: Date(timeIntervalSince1970: 2)))

        let service = SearchService(database: db)
        let results = try service.search(query: "hello", contentType: .email, limit: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.entry.contentType, .email)
    }
    
    func testSearchReturnsMatchRanges() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))

        let service = SearchService(database: db)
        let results = try service.search(query: "hello", limit: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results.first!.ranges.isEmpty, "Should return match ranges for highlighting")
    }
    
    func testSearchPrioritizesExactMatches() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "test", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try db.insert(ClipboardEntry(content: "testing something longer", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)))

        let service = SearchService(database: db)
        let results = try service.search(query: "test", limit: 10)

        XCTAssertEqual(results.count, 2)
        // Exact match should come first (lower score)
        XCTAssertEqual(results.first?.entry.content, "test")
        XCTAssertTrue(results.first?.isExactMatch ?? false)
    }
    
    func testEmptyQueryReturnsNoResults() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))

        let service = SearchService(database: db)
        let results = try service.search(query: "  ", limit: 10)

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Recency-aware ranking (pasta-45c)

    /// Repro from screenshot 1: searching "github" used to surface an 11465-day-old
    /// 6kB prose entry as the #1 result, ahead of fresh github URLs.
    func testRecentExactMatchOutranksAncientLongDoc() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        let elevenThousandDaysAgo = now.addingTimeInterval(-11_000 * 86_400)

        let ancient = String(repeating: "STANDARD CLAUSE STATUS SOURCE LAST UPDATED EVIDENCE github-repository-policy ", count: 80)
        try db.insert(ClipboardEntry(content: ancient, contentType: .text, timestamp: elevenThousandDaysAgo))
        try db.insert(ClipboardEntry(content: "https://github.com/example/repo", contentType: .url, timestamp: now))

        let service = SearchService(database: db)
        let results = try service.search(query: "github", limit: 10)

        XCTAssertGreaterThanOrEqual(results.count, 2)
        XCTAssertTrue(
            results.first?.entry.content.hasPrefix("https://github.com") ?? false,
            "Fresh github URL should rank #1, got: \(results.first?.entry.content.prefix(60) ?? "nil")"
        )
    }

    /// Repro from screenshot 2: searching "bead" used to surface old prose
    /// mentioning the whole word above a 1-minute-old URL ending in "/beads".
    /// FTS5 prefix matching catches both, but recency must break the tie.
    func testRecentPrefixMatchOutranksOldWholeWordMatch() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        let twentyFiveMinutesAgo = now.addingTimeInterval(-25 * 60)
        let oneMinuteAgo = now.addingTimeInterval(-60)

        try db.insert(ClipboardEntry(
            content: "So bead isn't about project context or structure. It's about planning future work.",
            contentType: .text,
            timestamp: twentyFiveMinutesAgo
        ))
        try db.insert(ClipboardEntry(
            content: "https://github.com/gastownhall/beads",
            contentType: .url,
            timestamp: oneMinuteAgo
        ))

        let service = SearchService(database: db)
        let results = try service.search(query: "bead", limit: 10)

        XCTAssertGreaterThanOrEqual(results.count, 2)
        XCTAssertEqual(
            results.first?.entry.content,
            "https://github.com/gastownhall/beads",
            "Fresh URL ending in /beads should rank #1 over older prose mentioning bead"
        )
    }

    /// Empty / whitespace queries must return [] from the search path so the
    /// caller falls back to the recency-ordered entry list.
    func testEmptyQueryShortCircuit() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        try db.insert(ClipboardEntry(content: "old", contentType: .text, timestamp: now.addingTimeInterval(-86_400)))
        try db.insert(ClipboardEntry(content: "new", contentType: .text, timestamp: now))

        let service = SearchService(database: db)
        XCTAssertTrue(try service.search(query: "", limit: 10).isEmpty)
        XCTAssertTrue(try service.search(query: "   ", limit: 10).isEmpty)

        // And the entry list itself must be timestamp DESC so the empty-query UI
        // path (which uses fetchRecent) shows newest first.
        let recent = try db.fetchRecent(limit: 10)
        XCTAssertEqual(recent.map(\.content), ["new", "old"])
    }

    /// Exact case-insensitive equality of trimmed content vs trimmed query
    /// must outrank everything else — recency, popularity, BM25.
    func testExactEqualityBoostBeatsRecency() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()

        // Old exact-equal entry
        try db.insert(ClipboardEntry(content: "Acme Corp", contentType: .text, timestamp: now.addingTimeInterval(-30 * 86_400)))
        // Fresh fuzzy match
        try db.insert(ClipboardEntry(content: "Acme Corp acquired Initech today", contentType: .text, timestamp: now.addingTimeInterval(-60)))

        let service = SearchService(database: db)
        let results = try service.search(query: "acme corp", limit: 10)

        XCTAssertEqual(results.first?.entry.content, "Acme Corp",
                       "Exact-equality boost should put 'Acme Corp' first even though the fuzzy match is fresher")
    }

    /// Frequently-pasted entries should rank higher when relevance is comparable.
    func testCopyCountBoostsRanking() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()

        try db.insert(ClipboardEntry(content: "design notes alpha", contentType: .text, timestamp: now, copyCount: 1))
        try db.insert(ClipboardEntry(content: "design notes beta", contentType: .text, timestamp: now, copyCount: 50))

        let service = SearchService(database: db)
        let results = try service.search(query: "design", limit: 10)

        XCTAssertEqual(results.first?.entry.content, "design notes beta",
                       "Entry pasted 50× should outrank an equally-fresh entry pasted 1×")
    }

    /// Punctuation-bearing queries (URLs, emails, paths) must be tokenised the
    /// same way the FTS5 unicode61 tokenizer tokenises content.
    func testPunctuationInQueryIsTokenised() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        try db.insert(ClipboardEntry(content: "https://github.com/example/repo", contentType: .url, timestamp: now))
        try db.insert(ClipboardEntry(content: "unrelated entry", contentType: .text, timestamp: now))

        let service = SearchService(database: db)

        let urlQuery = try service.search(query: "github.com", limit: 10)
        XCTAssertEqual(urlQuery.first?.entry.content, "https://github.com/example/repo")

        let pathQuery = try service.search(query: "example/repo", limit: 10)
        XCTAssertEqual(pathQuery.first?.entry.content, "https://github.com/example/repo")
    }

    /// `unicode61 remove_diacritics 2` should fold combining marks so `cafe`
    /// matches `café`. (Note: ligatures like `ß` are *not* folded — they aren't
    /// diacritics, they're separate codepoints.)
    func testDiacriticInsensitiveSearch() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        try db.insert(ClipboardEntry(content: "Café Münchner", contentType: .text, timestamp: now))

        let service = SearchService(database: db)

        XCTAssertEqual(try service.search(query: "cafe", limit: 10).count, 1, "'cafe' should match 'Café'")
        XCTAssertEqual(try service.search(query: "munchner", limit: 10).count, 1, "'munchner' should match 'Münchner'")
    }

    /// `contentType` is filtered via the explicit param, not via the FTS index.
    /// Searching for the literal text "url" or "email" must NOT return rows
    /// just because their contentType happens to be that value.
    func testContentTypeNotIndexedInFTS() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        try db.insert(ClipboardEntry(content: "https://example.com", contentType: .url, timestamp: now))
        try db.insert(ClipboardEntry(content: "user@example.com", contentType: .email, timestamp: now))
        try db.insert(ClipboardEntry(content: "the quick brown fox", contentType: .text, timestamp: now))

        let service = SearchService(database: db)

        // None of the entries have the word "url" or "email" in their content,
        // so these queries should match nothing — even though two of the rows
        // have those values as their contentType.
        XCTAssertEqual(try service.search(query: "url", limit: 10).count, 0,
                       "Searching 'url' must not match rows just because their contentType is 'url'")
        XCTAssertEqual(try service.search(query: "email", limit: 10).count, 0,
                       "Searching 'email' must not match rows just because their contentType is 'email'")
    }
}
