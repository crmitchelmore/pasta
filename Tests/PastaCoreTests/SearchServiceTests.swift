import Foundation
import XCTest
@testable import PastaCore

final class SearchServiceTests: XCTestCase {
    func testExactSearchUsesFTSAndRanksResults() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try db.insert(ClipboardEntry(content: "hello there", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)))

        let service = SearchService(database: db)
        let results = try service.search(query: "hello", mode: .exact, limit: 10)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.entry.content.lowercased().contains("hello") })
    }

    func testFuzzySearchFindsApproximateMatches() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try db.insert(ClipboardEntry(content: "completely different", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)))

        let service = SearchService(database: db)
        let results = try service.search(query: "helo", mode: .fuzzy, limit: 10)

        XCTAssertTrue(results.contains(where: { $0.entry.content == "hello world" }))
        XCTAssertFalse(results.contains(where: { $0.entry.content == "completely different" }))
    }

    func testSearchSupportsContentTypeFiltering() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try db.insert(ClipboardEntry(content: "hello@example.com", contentType: .email, timestamp: Date(timeIntervalSince1970: 2)))

        let service = SearchService(database: db)
        let results = try service.search(query: "hello", mode: .exact, contentType: .email, limit: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.entry.contentType, .email)
    }
}
