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
}
