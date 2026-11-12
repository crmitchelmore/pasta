import Foundation
import XCTest
@testable import PastaCore

final class ImageStorageManagerTests: XCTestCase {
    /// Image bytes are dropped from the entry only once the file write has
    /// succeeded; a failed write keeps them in the row so nothing is lost.
    func testImageBytesMoveToDiskOnlyAfterASuccessfulWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaImageStorage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("Images", isDirectory: true)
        let storage = try ImageStorageManager(imagesDirectoryURL: images)

        // 1x1 PNG
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+kv1cAAAAASUVORK5CYII="))
        let path = try storage.saveImage(png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try storage.saveImage(png), path, "identical bytes must reuse the content-addressed file")
        XCTAssertNotNil(storage.loadImage(path: path))
        XCTAssertGreaterThan(try storage.totalStorageBytes(), 0)
        try storage.deleteImage(path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        var stored = ClipboardEntry(content: "", contentType: .screenshot, rawData: bytes)
        try storage.persistImageData(in: &stored)
        XCTAssertNil(stored.rawData)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(stored.imagePath))), bytes)

        // Make the image destination unusable without relying on permissions
        // (the test may run with elevated privileges).
        try FileManager.default.removeItem(at: images)
        try Data("not a directory".utf8).write(to: images)
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
}
