import XCTest
@testable import PastaCore

/// Performance benchmarks for SearchService over a synthesized 10k-row in-memory database.
final class SearchServicePerformanceTests: XCTestCase {
    private static var sharedDB: DatabaseManager?

    override class func setUp() {
        super.setUp()
        sharedDB = try? makeSeededDatabase()
    }

    override class func tearDown() {
        sharedDB = nil
        super.tearDown()
    }

    private static func makeSeededDatabase() throws -> DatabaseManager {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        let domains = ["github.com", "stackoverflow.com", "apple.com", "google.com", "example.com"]
        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa"]
        let types: [ContentType] = [.text, .url, .email, .code, .prose]

        for i in 0..<10_000 {
            let domain = domains[i % domains.count]
            let word = words[i % words.count]
            let type = types[i % types.count]
            let content: String
            switch type {
            case .url:
                content = "https://\(domain)/path/\(word)/\(i)"
            case .email:
                content = "\(word)\(i)@\(domain)"
            case .code:
                content = "func \(word)_\(i)() -> Int { return \(i) }"
            case .prose:
                content = "Some prose mentioning \(word) and entry \(i) with extra padding text."
            default:
                content = "\(word) entry number \(i) at \(domain)"
            }
            try db.insert(ClipboardEntry(
                content: content,
                contentType: type,
                timestamp: now.addingTimeInterval(-Double(i))
            ))
        }
        return db
    }

    func testSearchSingleTerm() throws {
        let db = try XCTUnwrap(Self.sharedDB)
        let service = SearchService(database: db)
        measure {
            for _ in 0..<50 {
                _ = try? service.search(query: "alpha", limit: 50)
            }
        }
    }

    func testSearchPunctuationTerm() throws {
        let db = try XCTUnwrap(Self.sharedDB)
        let service = SearchService(database: db)
        measure {
            for _ in 0..<50 {
                _ = try? service.search(query: "github.com", limit: 50)
            }
        }
    }

    func testSearchWithContentTypeFilter() throws {
        let db = try XCTUnwrap(Self.sharedDB)
        let service = SearchService(database: db)
        measure {
            for _ in 0..<50 {
                _ = try? service.search(query: "alpha", contentType: .url, limit: 50)
            }
        }
    }

    func testSearchTwoWordPrefix() throws {
        let db = try XCTUnwrap(Self.sharedDB)
        let service = SearchService(database: db)
        measure {
            for _ in 0..<50 {
                _ = try? service.search(query: "alpha entry", limit: 50)
            }
        }
    }

    /// Stress test for the two-stage FTS5 query: a populated DB where most
    /// entries carry a non-trivial rawData BLOB. The benefit of ranking
    /// rowids first (without dragging the BLOB into the rank stage) only
    /// shows up when the un-ranked rows would otherwise be hydrated.
    func testSearchOnDatabaseWithBlobs() throws {
        let db = try Self.makeBlobDatabase()
        let service = SearchService(database: db)
        measure {
            for _ in 0..<10 {
                _ = try? service.search(query: "alpha", limit: 50)
            }
        }
    }

    private static func makeBlobDatabase() throws -> DatabaseManager {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        let words = ["alpha", "beta", "gamma", "delta", "epsilon"]
        // ~4kB blob per entry — modest but enough to make hydration measurable.
        let blob = Data(repeating: 0x5A, count: 32_768)
        for i in 0..<2_000 {
            let word = words[i % words.count]
            try db.insert(ClipboardEntry(
                content: "\(word) entry number \(i) with mixed text",
                contentType: .text,
                rawData: blob,
                timestamp: now.addingTimeInterval(-Double(i))
            ))
        }
        return db
    }
}
