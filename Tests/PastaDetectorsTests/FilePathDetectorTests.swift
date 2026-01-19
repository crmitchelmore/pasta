import XCTest
@testable import PastaDetectors

final class FilePathDetectorTests: XCTestCase {
    func testDetectsUnixPathsAndExpandsTilde() {
        let detector = FilePathDetector()
        let text = "Open ~/Library/Preferences/com.apple.Finder.plist and /tmp/test.txt"
        let results = detector.detect(in: text)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertEqual(results[0].filename, "com.apple.Finder.plist")
        XCTAssertEqual(results[0].fileExtension, "plist")
        XCTAssertEqual(results[1].filename, "test.txt")
        XCTAssertEqual(results[1].fileExtension, "txt")
    }

    func testDetectsWindowsPaths() {
        let detector = FilePathDetector()
        let text = "See C:\\Users\\me\\file.txt and also C:/Windows/System32/drivers/etc/hosts"
        let results = detector.detect(in: text)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].filename, "file.txt")
        XCTAssertEqual(results[0].fileExtension, "txt")
        XCTAssertEqual(results[1].filename, "hosts")
        XCTAssertNil(results[1].fileExtension)
    }

    func testReportsExistenceForRealTempFile() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let fileURL = temp.appendingPathComponent("exists.txt")
        try "hi".data(using: .utf8)?.write(to: fileURL)

        let detector = FilePathDetector()
        let results = detector.detect(in: "Path: \(fileURL.path)")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].path, fileURL.path)
        XCTAssertTrue(results[0].exists)
        XCTAssertGreaterThanOrEqual(results[0].confidence, 0.85)
    }

    func testDedupesSamePath() {
        let detector = FilePathDetector()
        let text = "/tmp/a /tmp/a"
        let results = detector.detect(in: text)
        XCTAssertEqual(results.map(\.path), ["/tmp/a"])
    }
}
