import Foundation
import XCTest
@testable import PastaCore

final class DatabaseManagerTests: XCTestCase {
    func testCRUD() throws {
        let db = try DatabaseManager.inMemory()

        let entry = ClipboardEntry(
            id: UUID(uuidString: "3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F")!,
            content: "hello world",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try db.insert(entry)

        let all = try db.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, entry.id)

        let results = try db.search(query: "hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, entry.id)

        let deleted = try db.delete(id: entry.id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(try db.fetchAll().count, 0)
    }

    func testFetchRecentOrdersByTimestampDesc() throws {
        let db = try DatabaseManager.inMemory()

        let older = ClipboardEntry(
            content: "older",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let newer = ClipboardEntry(
            content: "newer",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 2)
        )

        try db.insert(older)
        try db.insert(newer)

        let recent = try db.fetchRecent(limit: 2)
        XCTAssertEqual(recent.map(\.content), ["newer", "older"])
    }

    func testInsertDeduplicatesAndIncrementsCopyCount() throws {
        let db = try DatabaseManager.inMemory()

        let first = ClipboardEntry(
            id: UUID(uuidString: "3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F")!,
            content: "hello world",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let second = ClipboardEntry(
            id: UUID(uuidString: "A2A4B86B-2FBD-4BE7-8D0B-2B53E64B1E1C")!,
            content: "hello world",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 2)
        )

        try db.insert(first)
        try db.insert(second)

        let all = try db.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, first.id)
        XCTAssertEqual(all.first?.copyCount, 2)
        XCTAssertEqual(all.first?.timestamp, second.timestamp)
    }
}
