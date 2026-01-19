import Foundation
import XCTest
@testable import PastaCore

final class ImageStorageManagerTests: XCTestCase {
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
