import Foundation
import XCTest
@testable import PastaCore

final class SharedImageCleanupTests: XCTestCase {
    private enum Deletion: CaseIterable {
        case single, bulk, recent, all, maxEntries, age
    }

    func testEveryDeletePathProtectsSharedPinnedImageUntilLastReferenceIsDeleted() throws {
        for deletion in Deletion.allCases {
            let database = try DatabaseManager.inMemory()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PastaSharedImages-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = try ImageStorageManager(imagesDirectoryURL: directory)
            let bytes = Data([0x01, 0x02, 0x03])
            let path = try storage.saveImage(bytes)
            // Identical captures intentionally use the same content-addressed file.
            XCTAssertEqual(try storage.saveImage(bytes), path)
            let now = Date(timeIntervalSince1970: 10_000_000)
            let survivor = ClipboardEntry(
                content: "", contentType: .image, imagePath: path,
                timestamp: now.addingTimeInterval(-50 * 86_400), isPinned: true
            )
            let victim = ClipboardEntry(
                content: "", contentType: .image, imagePath: path,
                timestamp: now.addingTimeInterval(deletion == .recent ? -60 : -40 * 86_400)
            )
            try database.insert(survivor, deduplicate: false)
            try database.insert(victim, deduplicate: false)
            let service = DeleteService(database: database, imageStorage: storage)

            switch deletion {
            case .single:
                XCTAssertTrue(try service.delete(id: victim.id))
            case .bulk:
                XCTAssertEqual(try service.delete(ids: [victim.id]), 1)
            case .recent:
                XCTAssertEqual(try service.deleteRecent(minutes: 5, now: now), 1)
            case .all:
                XCTAssertEqual(try service.deleteAll(), 1)
            case .maxEntries:
                try database.insert(ClipboardEntry(content: "newest", contentType: .text, timestamp: now))
                let result = try database.pruneToMaxEntries(1)
                XCTAssertEqual(result.deletedCount, 1)
                try database.deleteUnreferencedImages(paths: result.imagePaths, using: storage)
            case .age:
                let result = try database.pruneOlderThan(days: 30, now: now)
                XCTAssertEqual(result.deletedCount, 1)
                try database.deleteUnreferencedImages(paths: result.imagePaths, using: storage)
            }

            XCTAssertNil(try database.fetch(id: victim.id), "\(deletion)")
            XCTAssertEqual(try database.fetch(id: survivor.id)?.isPinned, true, "\(deletion)")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, "\(deletion)")

            XCTAssertTrue(try service.delete(id: survivor.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "\(deletion)")
        }
    }

    func testCleanupRechecksReferencesAddedAfterDeletion() throws {
        let database = try DatabaseManager.inMemory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaSharedImages-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ImageStorageManager(imagesDirectoryURL: directory)
        let bytes = Data([0x04, 0x05])
        let path = try storage.saveImage(bytes)
        let victim = ClipboardEntry(content: "", contentType: .image, imagePath: path)
        try database.insert(victim)
        let result = try database.delete(ids: [victim.id])

        let newlyCaptured = ClipboardEntry(content: "", contentType: .image, imagePath: path)
        try database.insert(newlyCaptured)
        try database.deleteUnreferencedImages(paths: result.imagePaths, using: storage)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertNotNil(try database.fetch(id: newlyCaptured.id))
    }
}
