import Foundation
import XCTest
@testable import PastaCore
@testable import PastaUI

final class LazyHistoryRowTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyRow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lazyEntry(_ content: String, metadata: String? = nil, type: ContentType = .text) throws -> ClipboardEntry {
        let database = try DatabaseManager(databaseURL: directory.appendingPathComponent("\(UUID().uuidString).sqlite"))
        let entry = ClipboardEntry(content: content, contentType: type, metadata: metadata)
        _ = try database.insert(entry, deduplicate: false)
        let lazy = try XCTUnwrap(database.fetchHistoryPage(after: nil, limit: 1).entries.first)
        XCTAssertTrue(lazy.hasUnloadedPayload)
        return lazy
    }

    func testRowFromLazyEntryDoesNotLoadThePayload() throws {
        let content = "  first line\n" + String(repeating: "é", count: 40_000)
        let lazy = try lazyEntry(content)

        let row = ClipboardRowData(from: lazy)
        XCTAssertTrue(lazy.hasUnloadedPayload)
        XCTAssertEqual(row.contentLength, content.utf8.count)
        XCTAssertTrue(row.isLarge)
        XCTAssertEqual(row.previewText.count, 300)
        XCTAssertTrue(row.previewText.hasPrefix("first line\n"))
    }

    func testWhitespacePreviewFallsBackToFullContent() throws {
        let content = String(repeating: " ", count: 70_000) + "tail text"
        let lazy = try lazyEntry(content)
        XCTAssertEqual(ClipboardRowData(from: lazy).previewText, "tail text")
    }

    func testExtractedValuesForNonContentTypesDoNotLoadContent() throws {
        let emails = (0..<10).map { #"{"email":"u\#($0)@example.com"}"# }.joined(separator: ",")
        let lazy = try lazyEntry(String(repeating: "x", count: 70_000), metadata: #"{"emails":["# + emails + "]}", type: .email)
        XCTAssertEqual(lazy.extractedValues(for: .email).count, 10)
        XCTAssertTrue(lazy.hasUnloadedPayload)
    }
}
