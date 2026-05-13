import XCTest
@testable import PastaCore

/// Throughput benchmark for ClipboardEntry inserts.
final class DatabaseInsertPerformanceTests: XCTestCase {
    func testInsertHundredEntriesTempFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasta-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        measure {
            let dbURL = tempDir.appendingPathComponent("\(UUID().uuidString).sqlite")
            guard let db = try? DatabaseManager(databaseURL: dbURL) else {
                XCTFail("Could not create DB")
                return
            }
            for i in 0..<100 {
                let entry = ClipboardEntry(
                    content: "benchmark insert \(i) \(UUID().uuidString)",
                    contentType: .text,
                    timestamp: Date().addingTimeInterval(Double(i))
                )
                try? db.insert(entry)
            }
        }
    }

    func testInsertHundredEntriesInMemory() throws {
        measure {
            guard let db = try? DatabaseManager.inMemory() else {
                XCTFail("Could not create in-memory DB")
                return
            }
            for i in 0..<100 {
                let entry = ClipboardEntry(
                    content: "in-memory insert \(i) \(UUID().uuidString)",
                    contentType: .text,
                    timestamp: Date().addingTimeInterval(Double(i))
                )
                try? db.insert(entry)
            }
        }
    }
}
