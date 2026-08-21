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
        XCTAssertEqual(results[0].exists, true)
        XCTAssertGreaterThanOrEqual(results[0].confidence, 0.85)
    }

    func testDedupesSamePath() {
        let detector = FilePathDetector()
        let text = "/tmp/a /tmp/a"
        let results = detector.detect(in: text)
        XCTAssertEqual(results.map(\.path), ["/tmp/a"])
    }

    func testExistenceChecksAreCappedForPathHeavyText() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let realFile = temp.appendingPathComponent("real.txt")
        try "hi".data(using: .utf8)?.write(to: realFile)

        // A build-log-style paste: the cap's worth of unique paths first, then
        // the real file just beyond it.
        let limit = FilePathDetector.defaultExistenceCheckLimit
        var lines = (0..<limit).map { "/nonexistent/pasta-cap-test/file-\($0).log" }
        lines.append(realFile.path)

        let detector = FilePathDetector()
        let results = detector.detect(in: lines.joined(separator: "\n"))

        XCTAssertEqual(results.count, limit + 1, "every path is still detected")
        XCTAssertNil(
            results[limit].exists,
            "paths beyond the existence-check cap must be 'not checked', never 'missing'"
        )
        XCTAssertEqual(results[limit].confidence, 0.7, accuracy: 0.001)

        // The same real file within the cap does get checked.
        let headResults = detector.detect(in: "Path: \(realFile.path)")
        XCTAssertEqual(headResults.count, 1)
        XCTAssertEqual(headResults[0].exists, true)
    }

    func testDuplicatePathsDoNotConsumeTheExistenceCheckBudget() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let realFile = temp.appendingPathComponent("real.txt")
        try "hi".data(using: .utf8)?.write(to: realFile)

        // 50 repeats of one bogus path collapse to a single unique candidate,
        // so the real file is the SECOND unique path — well within the cap.
        var lines = Array(repeating: "/nonexistent/pasta-dup-test/same.log", count: 50)
        lines.append(realFile.path)

        let results = FilePathDetector().detect(in: lines.joined(separator: "\n"))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[1].exists, true)
    }

    func testWindowsCandidatesDoNotStarveUnixExistenceChecks() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let realFile = temp.appendingPathComponent("real.txt")
        try "hi".data(using: .utf8)?.write(to: realFile)

        // A Windows-flavoured CI log: more C:\ tokens than the whole stat
        // budget, followed by one genuine local path. The Unix path must
        // still get its existence check.
        let limit = FilePathDetector.defaultExistenceCheckLimit
        var lines = (0..<(limit + 5)).map { "C:\\build\\out\\module-\($0)\\artifact.dll" }
        lines.append(realFile.path)

        let results = FilePathDetector().detect(in: lines.joined(separator: "\n"))
        XCTAssertEqual(results.count, limit + 6)

        // Output order is unchanged (Windows matches first, Unix last)...
        let unixResult = try XCTUnwrap(results.last)
        XCTAssertEqual(unixResult.path, realFile.path)
        // ...but the budget is spent Unix-first, so the real path is checked.
        XCTAssertEqual(unixResult.exists, true)
        XCTAssertEqual(unixResult.confidence, 0.9, accuracy: 0.001)

        // Windows candidates consume only the leftover budget; the tail
        // beyond it is "not checked", not "missing".
        let checkedWindows = results.dropLast().filter { $0.exists != nil }
        XCTAssertEqual(checkedWindows.count, limit - 1)
        XCTAssertNil(results[limit].exists)
    }
}
