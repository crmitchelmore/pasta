#if os(macOS)
import XCTest
import Darwin
import PastaCore
@testable import PastaSync

final class TailnetFilesTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TailnetFilesTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func manifest(path: String = "0/file", size: Int64 = 3) -> TailnetManifest {
        TailnetManifest(entry: ClipboardEntry(content: "", contentType: .filePath),
                        files: [TailnetFile(path: path, size: size, sha256: TailnetFiles.hash(Data([1, 2, 3])))],
                        directories: [], roots: [path], changedSinceCapture: false, backfill: false)
    }
    func testTraversalAbsolutePathsDuplicateNamesAndOverflowAreRejected() throws {
        for path in ["../escape", "/absolute", "0/../escape", "0//file", "0/./file", "0/file\0", "0/file:stream", "0\\file"] {
            XCTAssertThrowsError(try manifest(path: path).validate(limit: 100), path)
        }
        var duplicate = manifest()
        duplicate.files.append(TailnetFile(path: "0/FILE", size: 1, sha256: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try duplicate.validate(limit: 100))
        var overflow = manifest(size: Int64.max)
        overflow.files.append(TailnetFile(path: "other", size: 1, sha256: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try overflow.validate(limit: Int64.max))
        var conflict = manifest()
        conflict.directories = ["0/file/subfolder"]
        XCTAssertThrowsError(try conflict.validate(limit: 100))
    }
    func testSymlinksAreRejectedAndNewlineNamesAreStructured() throws {
        let files = try TailnetFiles(root: root.appendingPathComponent("holding"))
        let original = root.appendingPathComponent("real\nfile.txt")
        try Data([1, 2, 3]).write(to: original)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try files.prepare(ClipboardEntry(content: link.path, contentType: .filePath), backfill: false))
        let captured = ClipboardEntry(content: original.path, contentType: .filePath, rawData: try JSONEncoder().encode([original.path]))
        let prepared = try files.prepare(captured, backfill: false); defer { prepared.cleanup() }
        XCTAssertEqual(prepared.manifest.roots, ["0/real\nfile.txt"])
        XCTAssertNotEqual(prepared.sources, [original])
        XCTAssertEqual(try Data(contentsOf: prepared.sources[0]), Data([1, 2, 3]))
        XCTAssertEqual(prepared.manifest.totalBytes, 3)
    }
    func testPreparedSnapshotSurvivesSourceReplacementWithOutsideSymlinkAndCleansUp() throws {
        let files = try TailnetFiles(root: root.appendingPathComponent("holding"))
        let source = root.appendingPathComponent("original")
        let outside = root.appendingPathComponent("outside")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        try Data([7, 8, 9]).write(to: outside)
        let prepared = try files.prepare(ClipboardEntry(content: source.path, contentType: .filePath), backfill: false)
        defer { prepared.cleanup() }
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertEqual(try Data(contentsOf: prepared.sources[0]), bytes)
        XCTAssertEqual(try TailnetFiles.hashFile(prepared.sources[0]), prepared.manifest.files[0].sha256)
        prepared.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.sources[0].path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([7, 8, 9]))
    }
    func testNestedSymlinksAndSpecialFilesFailWithoutLeavingSnapshots() throws {
        let files = try TailnetFiles(root: root.appendingPathComponent("holding"))
        let source = root.appendingPathComponent("selection")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([1]).write(to: source.appendingPathComponent("first"))
        let outside = root.appendingPathComponent("outside")
        try Data([9]).write(to: outside)
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let entry = ClipboardEntry(content: source.path, contentType: .filePath)
        XCTAssertThrowsError(try files.prepare(entry, backfill: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.root.path), [])
        try FileManager.default.removeItem(at: link)
        let fifo = source.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try files.prepare(entry, backfill: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.root.path), [])
    }
    func testAggregateSizeEmptyFoldersAndSourceChange() throws {
        let files = try TailnetFiles(root: root.appendingPathComponent("holding"))
        let directory = root.appendingPathComponent("selection")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 20).write(to: directory.appendingPathComponent("first"))
        try Data(repeating: 2, count: 31).write(to: directory.appendingPathComponent("second"))
        let prepared = try files.prepare(ClipboardEntry(content: directory.path, contentType: .filePath, timestamp: .distantPast), backfill: false)
        defer { prepared.cleanup() }
        XCTAssertEqual(prepared.manifest.totalBytes, 51)
        XCTAssertTrue(prepared.manifest.changedSinceCapture)
        XCTAssertTrue(prepared.manifest.directories.contains("0/selection/empty"))
        XCTAssertThrowsError(try prepared.manifest.validate(limit: 50))
        XCTAssertNoThrow(try prepared.manifest.validate(limit: 51))
    }
    func testChunkBoundsAndCorruptionCannotCommitHistory() throws {
        let files = try TailnetFiles(root: root.appendingPathComponent("holding"))
        let value = manifest()
        XCTAssertEqual(try files.begin(value, limit: 10), [0])
        XCTAssertThrowsError(try files.appendChunk(Data([1]), index: -1, offset: 0, manifest: value))
        XCTAssertThrowsError(try files.appendChunk(Data([1]), index: 0, offset: -1, manifest: value))
        XCTAssertThrowsError(try files.appendChunk(Data([1, 2, 3, 4]), index: 0, offset: 0, manifest: value))
        try files.appendChunk(Data([9, 9, 9]), index: 0, offset: 0, manifest: value)
        XCTAssertThrowsError(try files.finish(value))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.final(value.entry.id).path))
    }
    func testResumeAfterRecreatingReceiverKeepsVerifiedBytes() throws {
        let directory = root.appendingPathComponent("holding")
        let first = try TailnetFiles(root: directory)
        let value = manifest()
        _ = try first.begin(value, limit: 10)
        try first.appendChunk(Data([1, 2]), index: 0, offset: 0, manifest: value)
        let reopened = try TailnetFiles(root: directory)
        XCTAssertEqual(try reopened.begin(value, limit: 10), [2])
        try reopened.appendChunk(Data([3]), index: 0, offset: 2, manifest: value)
        let received = try reopened.finish(value)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: received.filePaths[0])), Data([1, 2, 3]))
    }
    func testCompletedFileRenameRecoversBeforeReceiptCommit() throws {
        let files = try TailnetFiles(root: root.appendingPathComponent("holding"))
        let value = manifest()
        _ = try files.begin(value, limit: 10)
        try files.appendChunk(Data([1, 2, 3]), index: 0, offset: 0, manifest: value)
        let first = try files.finish(value)
        // Simulate process death here: SQLite has not received the entry yet.
        let reopened = try TailnetFiles(root: root.appendingPathComponent("holding"))
        let db = try DatabaseManager.inMemory()
        try reopened.cleanup(database: db, active: [])
        XCTAssertEqual(try reopened.begin(value, limit: 10), [3])
        let restored = try reopened.finish(value)
        XCTAssertEqual(first.filePaths, restored.filePaths)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restored.filePaths[0])), Data([1, 2, 3]))
    }
    func testImagesCannotCarryFilePathsOrUnboundedAttachments() throws {
        var value = manifest()
        value.entry.contentType = .image
        XCTAssertThrowsError(try value.validate(limit: 100))
        value.roots = []; value.files[0].path = "data"; value.files[0].size = 64_000_001
        XCTAssertThrowsError(try value.validate(limit: 1_000_000_000))
        value.files[0].size = 3; value.entry.imagePath = "/private/data"
        XCTAssertThrowsError(try value.validate(limit: 100))
    }
}
#endif
