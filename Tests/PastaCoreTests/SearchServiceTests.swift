import Foundation
import XCTest
@testable import PastaCore

final class SearchServiceTests: XCTestCase {
    func testLiteralTokenisationAndMatching() throws {
        let db = try DatabaseManager.inMemory()
        let literal = ClipboardEntry(content: "price $50 is 100% ready AND OR NOT foo_bar github.com", contentType: .text, timestamp: Date(timeIntervalSince1970: 1))
        let hello = ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 2))
        let url = ClipboardEntry(content: "https://example.net/sample/repo", contentType: .url, timestamp: Date(timeIntervalSince1970: 3))
        let email = ClipboardEntry(content: "user@example.net", contentType: .email, timestamp: Date(timeIntervalSince1970: 4))
        let accented = ClipboardEntry(content: "Café Münchner", contentType: .text, timestamp: Date(timeIntervalSince1970: 5))
        let different = ClipboardEntry(content: "completely different text that never matches", contentType: .text, timestamp: Date(timeIntervalSince1970: 6))
        for entry in [literal, hello, url, email, accented, different] {
            try db.insert(entry)
        }
        let service = SearchService(database: db)

        // FTS operators and punctuation are literal text, not query syntax.
        for query in ["$50", "100%", "AND", "OR", "NOT", "foo_ba", "github.co", "\"ready\"", "OR rea"] {
            XCTAssertEqual(try service.search(query: query).map(\.entry.id), [literal.id], "Query: \(query)")
        }
        // Queries with no tokens neither throw nor match everything.
        for query in ["$", "%", "\"", "*", "()", "😀", "", "   "] {
            XCTAssertTrue(try service.search(query: query, limit: 10).isEmpty, "Query: \(query)")
        }
        let cases: [(query: String, expected: [UUID])] = [
            ("hello", [hello.id]),
            ("helo", [hello.id]),                // fuzzy fallback
            ("example.net", [email.id, url.id]),  // tokenised like the unicode61 index
            ("sample/repo", [url.id]),
            ("cafe", [accented.id]),              // remove_diacritics folds combining marks
            ("munchner", [accented.id]),
            ("url", []),                          // contentType is not indexed in FTS
            ("email", []),
        ]
        for (query, expected) in cases {
            XCTAssertEqual(Set(try service.search(query: query, limit: 10).map(\.entry.id)), Set(expected), "Query: \(query)")
        }
        XCTAssertEqual(try service.search(query: "helo", limit: 10).first?.entry.id, hello.id)
    }

    func testFiltersAndHighlightRanges() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "hello pinned", contentType: .text, timestamp: Date(timeIntervalSince1970: 1), isPinned: true))
        try db.insert(ClipboardEntry(content: "hello unpinned", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)))
        try db.insert(ClipboardEntry(content: "another hello also pinned", contentType: .text, timestamp: Date(timeIntervalSince1970: 3), isPinned: true))
        try db.insert(ClipboardEntry(content: "hello@example.com", contentType: .email, timestamp: Date(timeIntervalSince1970: 4)))
        let service = SearchService(database: db)

        let dbPinned = try db.searchFTS(query: "hello", contentType: nil, limit: 10, pinnedOnly: true)
        XCTAssertEqual(dbPinned.count, 2)
        XCTAssertTrue(dbPinned.allSatisfy(\.isPinned))
        let servicePinned = try service.search(query: "hello", limit: 10, pinnedOnly: true)
        XCTAssertEqual(servicePinned.count, 2)
        XCTAssertTrue(servicePinned.allSatisfy(\.entry.isPinned))
        XCTAssertEqual(try service.search(query: "hello", limit: 10).count, 4)
        XCTAssertEqual(try service.search(query: "hello", contentType: .email, limit: 10).map(\.entry.contentType), [.email])

        // Ranges are UTF-16 offsets so emoji surrogate pairs don't shift highlighting.
        let content = "😀 highlight"
        try db.insert(ClipboardEntry(content: content, contentType: .text))
        let range = try XCTUnwrap(try service.search(query: "highlight", limit: 10).first?.ranges.first)
        let nsRange = NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound + 1)
        XCTAssertEqual((content as NSString).substring(with: nsRange), "highlight")

        // mixedOnly filters before limiting, keeps the base type and ignores children.
        let mixedDB = try DatabaseManager.inMemory()
        let metadata = try ContentComposition.metadata(nil, content: "Contact a@example.com about launch",
            values: [(.email, "a@example.com")], analysisTruncated: false)
        let mixed = ClipboardEntry(content: "Contact a@example.com about launch", contentType: .prose, metadata: metadata)
        try mixedDB.insert(mixed, deduplicate: false)
        for index in 0..<210 {
            try mixedDB.insert(ClipboardEntry(content: "launch \(index)", contentType: .text), deduplicate: false)
        }
        let matches = try SearchService(database: mixedDB).search(query: "launch", limit: 1, mixedOnly: true)
        XCTAssertEqual(matches.map(\.entry.id), [mixed.id])
        XCTAssertEqual(matches.first?.entry.contentType, .prose)
        XCTAssertEqual(try mixedDB.searchFTS(query: "launch", contentType: .prose, mixedOnly: true).map(\.id), [mixed.id])
        let child = ClipboardEntry(content: "launch child", contentType: .text, metadata: metadata, parentEntryId: mixed.id)
        try mixedDB.insert(child, deduplicate: false)
        XCTAssertFalse(child.isMixedContent)
        XCTAssertEqual(try mixedDB.searchFTS(query: "launch", contentType: nil, mixedOnly: true).map(\.id), [mixed.id])
    }

    /// Recency, exact equality and popularity ranking (pasta-45c). Each case
    /// runs on a fresh database and asserts which entry ranks first.
    func testRanking() throws {
        let now = Date()
        let ancientDoc = String(repeating: "STANDARD CLAUSE STATUS SOURCE LAST UPDATED EVIDENCE github-repository-policy ", count: 80)
        let longAcme = "Acme Corp " + String(repeating: "quarterly filing notes ", count: 2_000)
        let cases: [(name: String, query: String, entries: [ClipboardEntry], winner: String)] = [
            ("exact match first", "test", [
                ClipboardEntry(content: "test", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)),
                ClipboardEntry(content: "testing something longer", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)),
            ], "test"),
            ("fresh URL beats ancient long doc", "github", [
                ClipboardEntry(content: ancientDoc, contentType: .text, timestamp: now.addingTimeInterval(-11_000 * 86_400)),
                ClipboardEntry(content: "https://github.com/example/repo", contentType: .url, timestamp: now),
            ], "https://github.com/example/repo"),
            ("fresh prefix match beats older whole word", "bead", [
                ClipboardEntry(content: "So bead isn't about project context or structure. It's about planning future work.", contentType: .text, timestamp: now.addingTimeInterval(-25 * 60)),
                ClipboardEntry(content: "https://github.com/gastownhall/beads", contentType: .url, timestamp: now.addingTimeInterval(-60)),
            ], "https://github.com/gastownhall/beads"),
            ("exact equality beats recency", "acme corp", [
                ClipboardEntry(content: "Acme Corp", contentType: .text, timestamp: now.addingTimeInterval(-30 * 86_400)),
                ClipboardEntry(content: "Acme Corp acquired Initech today", contentType: .text, timestamp: now.addingTimeInterval(-60)),
            ], "Acme Corp"),
            ("length guard allows trimmed padding only", "acme corp", [
                ClipboardEntry(content: "   Acme Corp   ", contentType: .text, timestamp: now.addingTimeInterval(-30 * 86_400)),
                ClipboardEntry(content: longAcme, contentType: .text, timestamp: now.addingTimeInterval(-60)),
                ClipboardEntry(content: "Acme Corp acquired Initech today", contentType: .text, timestamp: now.addingTimeInterval(-30)),
            ], "   Acme Corp   "),
            ("copy count boosts equal relevance", "design", [
                ClipboardEntry(content: "design notes alpha", contentType: .text, timestamp: now, copyCount: 1),
                ClipboardEntry(content: "design notes beta", contentType: .text, timestamp: now, copyCount: 50),
            ], "design notes beta"),
        ]
        for testCase in cases {
            let db = try DatabaseManager.inMemory()
            for entry in testCase.entries {
                try db.insert(entry)
            }
            let results = try SearchService(database: db).search(query: testCase.query, limit: 10)
            XCTAssertEqual(results.count, testCase.entries.count, testCase.name)
            XCTAssertEqual(results.first?.entry.content, testCase.winner, testCase.name)
            if testCase.name == "exact match first" {
                XCTAssertTrue(results.first?.isExactMatch ?? false)
            }
        }
    }
}
