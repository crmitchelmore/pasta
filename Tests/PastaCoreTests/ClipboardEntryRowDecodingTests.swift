import Foundation
import GRDB
import XCTest
@testable import PastaCore

/// `ClipboardEntry.init(row:)` replaces GRDB's synthesized `Decodable` row
/// decoding for speed; these pin it to the exact same results.
final class ClipboardEntryRowDecodingTests: XCTestCase {
    private func codableDecode(_ row: Row) throws -> ClipboardEntry {
        try FetchableRecordDecoder().decode(ClipboardEntry.self, from: row)
    }

    func testStoredRowsDecodeIdenticallyToCodablePath() throws {
        let db = try DatabaseManager.inMemory()
        let parent = UUID()
        var entries: [ClipboardEntry] = ContentType.allCases.enumerated().map { index, type in
            ClipboardEntry(
                content: "entry \(index) ✓",
                contentType: type,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) + 0.123),
                copyCount: index + 1,
                sourceApp: index.isMultiple(of: 2) ? "com.apple.Safari" : nil
            )
        }
        entries.append(ClipboardEntry(
            content: "rich", contentType: .text, rawData: Data("{\\rtf1 hello}".utf8),
            imagePath: "/tmp/image.png", sourceApp: "Notes",
            metadata: #"{"urls":[{"url":"https://example.com"}],"emails":[{"email":"a@b.co"}]}"#,
            parentEntryId: parent, isSynced: true, isPinned: true,
            cloudSyncAllowed: false, receivedViaTailnet: true
        ))
        entries.append(ClipboardEntry(content: "", contentType: .image, rawData: Data()))
        _ = try db.insertBatch(entries, deduplicate: false)

        let rows = try db.dbWriter.read { try Row.fetchAll($0, sql: "SELECT rowid, * FROM clipboard_entries") }
        XCTAssertEqual(rows.count, entries.count)
        for row in rows {
            XCTAssertEqual(try ClipboardEntry(row: row), try codableDecode(row))
        }
        let rich = try XCTUnwrap(db.fetch(id: entries[entries.count - 2].id))
        XCTAssertEqual(rich.rawData, Data("{\\rtf1 hello}".utf8))
        XCTAssertEqual(rich.parentEntryId, parent)
        XCTAssertEqual(rich.contentTypeMask, [.url, .email])
        XCTAssertTrue(rich.isPinned && rich.isSynced && rich.receivedViaTailnet)
        XCTAssertFalse(rich.cloudSyncAllowed)
    }

    func testLegacyRowWithoutOptionalColumnsUsesSameDefaults() throws {
        let id = UUID()
        let row: Row = [
            "id": id.uuidString,
            "content": "legacy",
            "contentType": "url",
            "rawData": nil,
            "imagePath": nil,
            "timestamp": "2024-01-02 03:04:05.678",
            "copyCount": 3,
            "sourceApp": nil,
            "metadata": #"{"urls":[{"url":"https://example.com"}]}"#,
            "parentEntryId": nil,
            "contentTypeMask": nil,
        ]

        let decoded = try ClipboardEntry(row: row)
        XCTAssertEqual(decoded, try codableDecode(row))
        XCTAssertEqual(decoded.id, id)
        XCTAssertTrue(decoded.cloudSyncAllowed)
        XCTAssertFalse(decoded.receivedViaTailnet)
        XCTAssertFalse(decoded.isSynced)
        XCTAssertFalse(decoded.isPinned)
        XCTAssertEqual(decoded.contentTypeMask, .url)
    }

    func testUnknownContentTypeThrowsLikeCodablePath() {
        let row: Row = [
            "id": UUID().uuidString, "content": "x", "contentType": "hologram",
            "timestamp": "2024-01-02 03:04:05.678", "copyCount": 1,
        ]
        XCTAssertThrowsError(try codableDecode(row))
        XCTAssertThrowsError(try ClipboardEntry(row: row))
    }
}
