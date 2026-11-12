import Foundation
import XCTest
@testable import PastaCore

/// Coarse latency budgets for the paths users feel: first history page,
/// full history walk, search, entry save and image save. They run on an on-disk 10k-entry
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
        var entries: [ClipboardEntry] = []
        entries.reserveCapacity(rowCount)
        for i in 0..<rowCount {
            let word: String = words[i % words.count]
            let content: String
            if i % 20 == 0 {
                content = "\(word) dump \(i) \(longTail)"
            } else {
                content = "\(word) entry \(i) https://example.com/\(i)"
            }
            let type: ContentType = i % 3 == 0 ? .url : .text
            let timestamp: Date = base.addingTimeInterval(Double(i))
            entries.append(ClipboardEntry(content: content, contentType: type, timestamp: timestamp))
        }
        try! db.insertBatch(entries, deduplicate: false)
    }

    override class func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testHistoryPagingWithinBudget() throws {
        let firstPage = try medianMilliseconds {
            let page = try Self.db.fetchHistoryPage(after: nil, limit: 200)
            XCTAssertEqual(page.entries.count, 200)
        }
        XCTAssertLessThan(firstPage, 25, "First 200-entry history page took \(firstPage) ms")

        let fullWalk = try medianMilliseconds(runs: 3) {
            var loaded = 0
            var cursor: DatabaseManager.HistoryCursor?
            repeat {
                let page = try Self.db.fetchHistoryPage(after: cursor, limit: 1_000)
                loaded += page.entries.count
                cursor = page.nextCursor
            } while cursor != nil
            XCTAssertEqual(loaded, Self.rowCount)
        }
        XCTAssertLessThan(fullWalk, 1_000, "Full 10k-entry history walk took \(fullWalk) ms")
    }

    func testSearchAndSaveWithinBudget() throws {
        for query in ["alpha", "al", "example com"] {
            let ms = try medianMilliseconds {
                XCTAssertFalse(try Self.db.searchFTS(query: query, contentType: nil, limit: 50).isEmpty)
            }
            XCTAssertLessThan(ms, 100, "Search for '\(query)' took \(ms) ms")
        }
        let service = SearchService(database: Self.db)
        for (query, type) in [("alpha entry", nil), ("example.com", nil), ("alpha", ContentType.url)] as [(String, ContentType?)] {
            let ms = try medianMilliseconds(runs: 3) {
                let results = try service.search(query: query, contentType: type, limit: 50)
                XCTAssertFalse(results.isEmpty)
                if let type { XCTAssertTrue(results.allSatisfy { $0.entry.contentType == type }) }
            }
            XCTAssertLessThan(ms, 250, "SearchService query '\(query)' took \(ms) ms")
        }

        var index = 0
        let save = try medianMilliseconds {
            index += 1
            try Self.db.insert(ClipboardEntry(content: "budget save \(index) \(UUID())", contentType: .text))
        }
        XCTAssertLessThan(save, 25, "Saving one entry took \(save) ms")

        let images = try ImageStorageManager(imagesDirectoryURL: Self.directory.appendingPathComponent("images", isDirectory: true))
        var blob = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let imageSave = try medianMilliseconds {
            index += 1
            blob[0] = UInt8(truncatingIfNeeded: index)
            let path = try images.saveImage(blob)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), blob)
            try images.deleteImage(path: path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertLessThan(imageSave, 250, "Saving and deleting a 1 MB image took \(imageSave) ms")
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
