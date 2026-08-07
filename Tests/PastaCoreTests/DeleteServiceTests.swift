import Foundation
import XCTest
@testable import PastaCore

final class DeleteServiceTests: XCTestCase {
    func testDeleteRemovesEntryAndAssociatedImage() throws {
        let db = try DatabaseManager.inMemory()

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let imageStorage = try ImageStorageManager(imagesDirectoryURL: tempRoot)

        let imageData = Data([0x01, 0x02, 0x03])
        let imagePath = try imageStorage.saveImage(imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))

        let entryID = UUID(uuidString: "3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F")!
        let entry = ClipboardEntry(
            id: entryID,
            content: "image",
            contentType: .image,
            rawData: imageData,
            imagePath: imagePath,
            timestamp: Date(timeIntervalSince1970: 1)
        )

        try db.insert(entry)

        let service = DeleteService(database: db, imageStorage: imageStorage)
        let deleted = try service.delete(id: entryID)
        XCTAssertTrue(deleted)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath))
        XCTAssertNil(try db.fetch(id: entryID))
    }

    func testDeleteRecentRemovesEntriesAndCleansUpImages() throws {
        let db = try DatabaseManager.inMemory()

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let imageStorage = try ImageStorageManager(imagesDirectoryURL: tempRoot)
        let now = Date(timeIntervalSince1970: 1_000)

        let imageData = Data([0x01, 0x02, 0x03])
        let imagePath = try imageStorage.saveImage(imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))

        let oldEntry = ClipboardEntry(
            content: "old",
            contentType: .text,
            timestamp: now.addingTimeInterval(-600)
        )
        let recentEntry = ClipboardEntry(
            content: "recentImage",
            contentType: .image,
            rawData: imageData,
            imagePath: imagePath,
            timestamp: now.addingTimeInterval(-60)
        )

        try db.insert(oldEntry)
        try db.insert(recentEntry)

        let service = DeleteService(database: db, imageStorage: imageStorage)
        let deletedCount = try service.deleteRecent(minutes: 5, now: now)
        XCTAssertEqual(deletedCount, 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath))
        XCTAssertEqual(try db.fetchAll().count, 1)
        XCTAssertEqual(try db.fetchAll().first?.content, "old")
    }

    func testDeleteAllRemovesEntriesAndCleansUpImages() throws {
        let db = try DatabaseManager.inMemory()

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let imageStorage = try ImageStorageManager(imagesDirectoryURL: tempRoot)

        let imageData = Data([0x01, 0x02, 0x03])
        let imagePath = try imageStorage.saveImage(imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))

        try db.insert(ClipboardEntry(content: "hello", contentType: .text))
        try db.insert(ClipboardEntry(content: "", contentType: .image, rawData: imageData, imagePath: imagePath))

        let service = DeleteService(database: db, imageStorage: imageStorage)
        let deletedCount = try service.deleteAll()
        XCTAssertEqual(deletedCount, 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath))
        XCTAssertEqual(try db.fetchAll().count, 0)
    }

    func testDeleteAllPreservesPinnedByDefault() throws {
        let db = try DatabaseManager.inMemory()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let imageStorage = try ImageStorageManager(imagesDirectoryURL: tempRoot)

        let pinnedID = UUID()
        let unpinnedID = UUID()
        try db.insert(ClipboardEntry(id: pinnedID, content: "keep", contentType: .text, isPinned: true))
        try db.insert(ClipboardEntry(id: unpinnedID, content: "drop", contentType: .text))

        let service = DeleteService(database: db, imageStorage: imageStorage)
        let deletedCount = try service.deleteAll()

        XCTAssertEqual(deletedCount, 1)
        let remaining = try db.fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, pinnedID)
        XCTAssertTrue(remaining.first?.isPinned ?? false)
    }

    func testDeleteAllIncludePinnedWipesEverything() throws {
        let db = try DatabaseManager.inMemory()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let imageStorage = try ImageStorageManager(imagesDirectoryURL: tempRoot)

        try db.insert(ClipboardEntry(content: "keep", contentType: .text, isPinned: true))
        try db.insert(ClipboardEntry(content: "drop", contentType: .text))

        let service = DeleteService(database: db, imageStorage: imageStorage)
        let deletedCount = try service.deleteAll(includePinned: true)

        XCTAssertEqual(deletedCount, 2)
        XCTAssertEqual(try db.fetchAll().count, 0)
    }

    func testBulkDeleteRemovesEntriesAndCleansUpImages() throws {
        let db = try DatabaseManager.inMemory()

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let imageStorage = try ImageStorageManager(imagesDirectoryURL: tempRoot)

        let imagePathA = try imageStorage.saveImage(Data([0x01]))
        let imagePathB = try imageStorage.saveImage(Data([0x02]))

        let withImageA = ClipboardEntry(content: "a", contentType: .image, imagePath: imagePathA)
        let withImageB = ClipboardEntry(content: "b", contentType: .image, imagePath: imagePathB)
        let pinned = ClipboardEntry(content: "pinned", contentType: .text, isPinned: true)
        let survivor = ClipboardEntry(content: "survivor", contentType: .text)

        for entry in [withImageA, withImageB, pinned, survivor] {
            try db.insert(entry, deduplicate: false)
        }

        let service = DeleteService(database: db, imageStorage: imageStorage)

        // Bulk delete honours the exact selection, pinned included — matching
        // the single-ID delete rather than deleteAll's pin protection.
        let deleted = try service.delete(ids: [withImageA.id, withImageB.id, pinned.id])
        XCTAssertEqual(deleted, 3)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePathA))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePathB))

        let remaining = try db.fetchAll()
        XCTAssertEqual(remaining.map(\.id), [survivor.id])
    }

    func testBulkDeleteWithNoIDsIsANoOp() throws {
        let db = try DatabaseManager.inMemory()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let imageStorage = try ImageStorageManager(imagesDirectoryURL: tempRoot)

        try db.insert(ClipboardEntry(content: "keep", contentType: .text))

        let service = DeleteService(database: db, imageStorage: imageStorage)
        XCTAssertEqual(try service.delete(ids: []), 0)
        XCTAssertEqual(try db.fetchAll().count, 1)
    }

    func testSetPinnedPersists() throws {
        let db = try DatabaseManager.inMemory()
        let id = UUID()
        try db.insert(ClipboardEntry(id: id, content: "x", contentType: .text))

        XCTAssertEqual(try db.fetch(id: id)?.isPinned, false)

        let changed = try db.setPinned(id: id, pinned: true)
        XCTAssertTrue(changed)
        XCTAssertEqual(try db.fetch(id: id)?.isPinned, true)

        let changedBack = try db.setPinned(id: id, pinned: false)
        XCTAssertTrue(changedBack)
        XCTAssertEqual(try db.fetch(id: id)?.isPinned, false)
    }
}
