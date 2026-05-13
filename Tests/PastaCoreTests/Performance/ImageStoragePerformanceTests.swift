import XCTest
@testable import PastaCore

/// Write+read benchmark for ImageStorageManager using a 1MB blob.
final class ImageStoragePerformanceTests: XCTestCase {
    private static let oneMBBlob: Data = {
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        for i in 0..<bytes.count {
            bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7)
        }
        return Data(bytes)
    }()

    func testSaveAndDelete1MBImage() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasta-image-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = try ImageStorageManager(imagesDirectoryURL: tempDir)
        var counter = 0
        measure {
            counter += 1
            var blob = Self.oneMBBlob
            blob[0] = UInt8(truncatingIfNeeded: counter)
            do {
                let path = try manager.saveImage(blob)
                _ = try? Data(contentsOf: URL(fileURLWithPath: path))
                try? manager.deleteImage(path: path)
            } catch {
                XCTFail("saveImage failed: \(error)")
            }
        }
    }
}
