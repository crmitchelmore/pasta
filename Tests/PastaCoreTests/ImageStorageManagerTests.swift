import Foundation
import XCTest
@testable import PastaCore

final class ImageStorageManagerTests: XCTestCase {
    func testFailedImageFileWriteRetainsBytesThroughDatabaseReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaImageFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("Images", isDirectory: true)
        let storage = try ImageStorageManager(imagesDirectoryURL: images)
        // Make the image destination unusable after initialization without
        // relying on permissions (the test may run with elevated privileges).
        try FileManager.default.removeItem(at: images)
        try Data("not a directory".utf8).write(to: images)

        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        var entry = ClipboardEntry(content: "", contentType: .image, rawData: bytes)

        XCTAssertThrowsError(try storage.persistImageData(in: &entry))
        XCTAssertEqual(entry.rawData, bytes)
        XCTAssertNil(entry.imagePath)
        XCTAssertFalse(entry.isSynced)

        let databaseURL = root.appendingPathComponent("pasta.sqlite")
        do {
            let database = try DatabaseManager(databaseURL: databaseURL)
            try database.insert(entry)
        }
        let reopened = try DatabaseManager(databaseURL: databaseURL)
        let pending = try XCTUnwrap(reopened.fetchUnsynced().first)
        XCTAssertEqual(pending.id, entry.id)
        XCTAssertEqual(pending.rawData, bytes)
        XCTAssertNil(pending.imagePath)
    }

    func testSuccessfulImageFileWriteClearsBytesOnlyAfterStorageSucceeds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaImageSuccess-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try ImageStorageManager(imagesDirectoryURL: root)
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        var entry = ClipboardEntry(content: "", contentType: .screenshot, rawData: bytes)

        try storage.persistImageData(in: &entry)

        XCTAssertNil(entry.rawData)
        let path = try XCTUnwrap(entry.imagePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }

    func testSaveLoadDeleteAndTotalStorage() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let manager = try ImageStorageManager(imagesDirectoryURL: tempRoot)

        // 1x1 PNG
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+kv1cAAAAASUVORK5CYII="
        let data = try XCTUnwrap(Data(base64Encoded: pngBase64))

        let path = try manager.saveImage(data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // Saving same bytes again should not duplicate data.
        let path2 = try manager.saveImage(data)
        XCTAssertEqual(path2, path)

        XCTAssertNotNil(manager.loadImage(path: path))

        let total = try manager.totalStorageBytes()
        XCTAssertGreaterThan(total, 0)

        try manager.deleteImage(path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
