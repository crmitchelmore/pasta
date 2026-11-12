import Foundation
import XCTest
@testable import PastaCore
@testable import PastaUI

final class LazyHistoryRowTests: XCTestCase {
    func testRowsFromLazyHistoryNeverLoadThePayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyRow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func lazyEntry(_ content: String, metadata: String? = nil, type: ContentType = .text) throws -> ClipboardEntry {
            let database = try DatabaseManager(databaseURL: directory.appendingPathComponent("\(UUID().uuidString).sqlite"))
            _ = try database.insert(ClipboardEntry(content: content, contentType: type, metadata: metadata), deduplicate: false)
            let lazy = try XCTUnwrap(database.fetchHistoryPage(after: nil, limit: 1).entries.first)
            XCTAssertTrue(lazy.hasUnloadedPayload)
            return lazy
        }

        let content = "  first line\n" + String(repeating: "é", count: 40_000)
        let lazy = try lazyEntry(content)
        let row = ClipboardRowData(from: lazy)
        XCTAssertTrue(lazy.hasUnloadedPayload)
        XCTAssertEqual(row.contentLength, content.utf8.count)
        XCTAssertTrue(row.isLarge)
        XCTAssertEqual(row.previewText.count, 300)
        XCTAssertTrue(row.previewText.hasPrefix("first line\n"))

        // A whitespace-only stored preview falls back to the full content.
        let whitespace = try lazyEntry(String(repeating: " ", count: 70_000) + "tail text")
        XCTAssertEqual(ClipboardRowData(from: whitespace).previewText, "tail text")

        let emails = (0..<10).map { #"{"email":"u\#($0)@example.com"}"# }.joined(separator: ",")
        let emailEntry = try lazyEntry(String(repeating: "x", count: 70_000), metadata: #"{"emails":["# + emails + "]}", type: .email)
        XCTAssertEqual(emailEntry.extractedValues(for: .email).count, 10)
        XCTAssertTrue(emailEntry.hasUnloadedPayload)
    }
}
