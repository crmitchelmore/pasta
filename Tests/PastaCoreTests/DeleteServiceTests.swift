import Foundation
import XCTest
@testable import PastaCore

final class DeleteServiceTests: XCTestCase {
    /// Pin protection is the data-loss guard: "clear all" keeps pinned entries
    /// unless explicitly included, while explicit selections delete exactly what
    /// was chosen. Image files go with their entries.
    func testDeletePathsHonourPinsSelectionsAndRemoveImages() throws {
        let db = try DatabaseManager.inMemory()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let imageStorage = try ImageStorageManager(imagesDirectoryURL: tempRoot, cleanupGracePeriod: 0)
        let service = DeleteService(database: db, imageStorage: imageStorage)
        let now = Date(timeIntervalSince1970: 1_000)

        let imagePathA = try imageStorage.saveImage(Data([0x01]))
        let imagePathB = try imageStorage.saveImage(Data([0x02]))
        let recentImagePath = try imageStorage.saveImage(Data([0x03]))
        let withImageA = ClipboardEntry(content: "a", contentType: .image, imagePath: imagePathA, timestamp: now.addingTimeInterval(-3_000))
        let withImageB = ClipboardEntry(content: "b", contentType: .image, imagePath: imagePathB, timestamp: now.addingTimeInterval(-3_000))
        let pinnedSelected = ClipboardEntry(content: "pinned selected", contentType: .text, timestamp: now.addingTimeInterval(-3_000), isPinned: true)
        let old = ClipboardEntry(content: "old", contentType: .text, timestamp: now.addingTimeInterval(-600))
        let recentImage = ClipboardEntry(content: "recentImage", contentType: .image, rawData: Data([0x03]),
                                         imagePath: recentImagePath, timestamp: now.addingTimeInterval(-60))
        for entry in [withImageA, withImageB, pinnedSelected, old, recentImage] {
            try db.insert(entry, deduplicate: false)
        }

        XCTAssertEqual(try service.delete(ids: []), 0)
        // Bulk delete honours the exact selection, pinned included — matching
        // the single-ID delete rather than deleteAll's pin protection.
        XCTAssertEqual(try service.delete(ids: [withImageA.id, withImageB.id, pinnedSelected.id]), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePathA))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePathB))

        XCTAssertEqual(try service.deleteRecent(minutes: 5, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recentImagePath))
        XCTAssertEqual(try db.fetchAll().map(\.id), [old.id])

        let singleImagePath = try imageStorage.saveImage(Data([0x04]))
        let single = ClipboardEntry(content: "image", contentType: .image, imagePath: singleImagePath)
        try db.insert(single)
        XCTAssertTrue(try service.delete(id: single.id))
        XCTAssertNil(try db.fetch(id: single.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: singleImagePath))

        let pinned = ClipboardEntry(content: "keep", contentType: .text)
        try db.insert(pinned)
        XCTAssertTrue(try db.setPinned(id: pinned.id, pinned: true))
        XCTAssertEqual(try db.fetch(id: pinned.id)?.isPinned, true)
        let allImagePath = try imageStorage.saveImage(Data([0x05]))
        try db.insert(ClipboardEntry(content: "", contentType: .image, imagePath: allImagePath), deduplicate: false)

        XCTAssertEqual(try service.deleteAll(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: allImagePath))
        XCTAssertEqual(try db.fetchAll().map(\.id), [pinned.id])

        XCTAssertTrue(try db.setPinned(id: pinned.id, pinned: false))
        XCTAssertEqual(try db.fetch(id: pinned.id)?.isPinned, false)
        XCTAssertTrue(try db.setPinned(id: pinned.id, pinned: true))
        XCTAssertEqual(try service.deleteAll(includePinned: true), 1)
        XCTAssertEqual(try db.fetchAll().count, 0)
    }
}
