import Foundation
import XCTest
@testable import PastaCore

/// Coarse latency budgets for the paths users feel: first history page,
/// full history walk, search and save. They run on an on-disk 10k-entry
/// history with some long entries.
///
/// Debug-build medians on an Apple Silicon laptop: first page 1.5 ms, full
/// walk 67 ms, search 5-9 ms, save 0.25 ms. Budgets are at least 10x those
/// so shared, parallel CI runners don't flake. They catch order-of-magnitude
/// regressions, such as unbounded decoding or scanning large columns, not
/// small drifts. Use the `PastaSignpost` intervals in Instruments to profile.
final class PerformanceBudgetTests: XCTestCase {
    private static let rowCount = 10_000
    private static var directory: URL!
    private static var db: DatabaseManager!

    override class func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceBudgetTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try! DatabaseManager(databaseURL: directory.appendingPathComponent("budget.sqlite"))

        let words = ["alpha", "beta", "gamma", "delta", "epsilon"]
        let longTail = String(repeating: "log line with alpha and beta tokens ", count: 600)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<rowCount).map { i in
            ClipboardEntry(
                content: i % 20 == 0
                    ? "\(words[i % words.count]) dump \(i) \(longTail)"
                    : "\(words[i % words.count]) entry \(i) https://example.com/\(i)",
                contentType: i % 3 == 0 ? .url : .text,
                timestamp: base.addingTimeInterval(Double(i))
            )
        }
        try! db.insertBatch(entries, deduplicate: false)
    }

    override class func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testFirstHistoryPageWithinBudget() throws {
        let ms = try medianMilliseconds {
            let page = try Self.db.fetchHistoryPage(after: nil, limit: 200)
            XCTAssertEqual(page.entries.count, 200)
        }
        XCTAssertLessThan(ms, 25, "First 200-entry history page took \(ms) ms")
    }

    func testFullHistoryWalkWithinBudget() throws {
        let ms = try medianMilliseconds(runs: 3) {
            var loaded = 0
            var cursor: DatabaseManager.HistoryCursor?
            repeat {
                let page = try Self.db.fetchHistoryPage(after: cursor, limit: 1_000)
                loaded += page.entries.count
                cursor = page.nextCursor
            } while cursor != nil
            XCTAssertEqual(loaded, Self.rowCount)
        }
        XCTAssertLessThan(ms, 1_000, "Full 10k-entry history walk took \(ms) ms")
    }

    func testSearchWithinBudget() throws {
        for query in ["alpha", "al", "example com"] {
            let ms = try medianMilliseconds {
                XCTAssertFalse(try Self.db.searchFTS(query: query, contentType: nil, limit: 50).isEmpty)
            }
            XCTAssertLessThan(ms, 100, "Search for '\(query)' took \(ms) ms")
        }
    }

    func testSaveWithinBudget() throws {
        var index = 0
        let ms = try medianMilliseconds {
            index += 1
            try Self.db.insert(ClipboardEntry(content: "budget save \(index) \(UUID())", contentType: .text))
        }
        XCTAssertLessThan(ms, 25, "Saving one entry took \(ms) ms")
    }

    private func medianMilliseconds(runs: Int = 7, _ body: () throws -> Void) throws -> Double {
        try body()  // Warm the page cache and statement cache.
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }
}
