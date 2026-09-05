import CloudKit
import Foundation
import XCTest

import PastaDetectors
import PastaSync
import PastaUI
@testable import PastaCore

/// Drives the whole capture path a real copy takes — fake pasteboard →
/// `ClipboardMonitor` → detectors → on-disk `DatabaseManager` →
/// `SearchService` → `PasteService` — and asserts what lands at each stage.
final class CaptureToPasteFlowTests: XCTestCase {
    private var env: E2ETempEnvironment!
    private var database: DatabaseManager!
    private var pipeline: E2ECapturePipeline!
    private var harness: E2EMonitorHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        env = try E2ETempEnvironment(name: "flow")
        database = try env.openDatabase()
        pipeline = E2ECapturePipeline(
            database: database,
            imageStorage: try env.openImageStorage(),
            detector: ContentTypeDetector()
        )
        let clock = E2EClock()
        harness = E2EMonitorHarness(suite: "PastaE2E.flow.\(name)", now: clock.now)
    }

    override func tearDownWithError() throws {
        harness.stop()
        harness = nil
        pipeline = nil
        database = nil
        env.destroy()
        env = nil
        try super.tearDownWithError()
    }

    // MARK: - Text

    func testMixedTextCopyIsClassifiedPersistedSearchedAndPasted() throws {
        let text = "Deploy notes: ping ops@example.com and read https://docs.example.com/runbooks/deploy before Friday."

        let captured = try XCTUnwrap(harness.capture(.text(text), in: self))
        XCTAssertEqual(captured.contentType, .text, "the monitor hands raw text over untyped; the detectors decide")
        XCTAssertEqual(captured.sourceApp, "com.example.Editor")
        XCTAssertEqual(captured.timestamp, Date(timeIntervalSince1970: 1_700_000_001), "the monitor stamps copy time from the injected clock")

        let result = try pipeline.ingest(captured)

        // Persisted primary entry: type, metadata and derived mask all agree.
        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.content, text)
        XCTAssertEqual(stored.contentType, result.primary.contentType)
        XCTAssertTrue([.prose, .text].contains(stored.contentType), "mixed prose must not be mis-typed as one of its embedded items, got \(stored.contentType)")
        let metadata = try XCTUnwrap(e2eJSONDictionary(stored.metadata), "detector metadata must be persisted")
        XCTAssertNotNil(metadata["emails"])
        XCTAssertNotNil(metadata["urls"])
        XCTAssertTrue(stored.contentTypeMask.contains(.email))
        XCTAssertTrue(stored.contentTypeMask.contains(.url))
        XCTAssertEqual(stored.contentTypeMask, MetadataParser.typeMask(for: stored.metadata), "stored mask must be derived from the stored metadata")

        let rawMask: Int? = try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT contentTypeMask FROM clipboard_entries WHERE id = ?", arguments: [captured.id.uuidString])
        }
        XCTAssertEqual(rawMask, stored.contentTypeMask.rawValue, "the mask column must hold the same bits the model exposes")

        // Extracted children link back to the parent and carry their own type.
        let children = try database.fetchExtractedEntries(parentId: captured.id)
        XCTAssertEqual(children.count, result.extracted.count)
        XCTAssertTrue(Set(children.map(\.contentType)).isSuperset(of: [.email, .url]), "got \(children.map(\.contentType))")
        XCTAssertTrue(children.allSatisfy { $0.parentEntryId == captured.id })
        XCTAssertEqual(try database.fetchPrimaryEntries().map(\.id), [captured.id])

        // FTS finds the parent by a word only it contains; type filters narrow to the children.
        let search = SearchService(database: database)
        let byWord = try search.search(query: "runbooks")
        XCTAssertTrue(byWord.contains { $0.entry.id == captured.id }, "FTS must index the captured content")
        XCTAssertFalse(try XCTUnwrap(byWord.first { $0.entry.id == captured.id }).ranges.isEmpty, "matches must carry highlight ranges")

        let emailsOnly = try search.search(query: "ops", contentType: .email)
        XCTAssertEqual(emailsOnly.map(\.entry.content), ["ops@example.com"])
        XCTAssertTrue(emailsOnly.allSatisfy { $0.entry.contentType == .email })

        let urlsOnly = try search.search(query: "docs example", contentType: .url)
        XCTAssertEqual(urlsOnly.map(\.entry.content), ["https://docs.example.com/runbooks/deploy"])

        XCTAssertTrue(try search.search(query: "runbooks", contentType: .image).isEmpty, "type filter must exclude non-matching types")
        XCTAssertTrue(try search.search(query: "zzqxv").isEmpty)

        // Paste writes the primary as plain text and simulates ⌘V; the URL child pastes as text too.
        let writer = E2EPasteboardWriter()
        let simulator = E2EPasteSimulator()
        let paste = PasteService(pasteboard: writer, simulator: simulator)
        XCTAssertTrue(paste.paste(stored))
        XCTAssertEqual(writer.lastWrite, .text(text))

        let urlChild = try XCTUnwrap(children.first { $0.contentType == .url })
        XCTAssertTrue(paste.copy(urlChild))
        XCTAssertEqual(writer.lastWrite, .text("https://docs.example.com/runbooks/deploy"))
        XCTAssertEqual(writer.writes.count, 2)
    }

    func testSingleURLCopyIsTypedAsURLAndFilterable() throws {
        let captured = try XCTUnwrap(harness.capture(.text("https://github.com/crmitchelmore/pasta/pull/42"), in: self))
        try pipeline.ingest(captured)

        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.contentType, .url)
        XCTAssertTrue(stored.contentTypeMask.contains(.url))
        XCTAssertEqual(try database.fetchExtractedEntries(parentId: captured.id).count, 0, "a bare URL has nothing to extract from itself")

        XCTAssertEqual(try database.fetchRecent(contentType: .url, limit: 10).map(\.id), [captured.id])
        XCTAssertTrue(try database.fetchRecent(contentType: .email, limit: 10).isEmpty)

        let hits = try SearchService(database: database).search(query: "github.com", contentType: .url)
        XCTAssertEqual(hits.map(\.entry.id), [captured.id])
    }

    // MARK: - Duplicate copies

    func testRecopyingIdenticalTextBumpsCopyCountInsteadOfAddingARow() throws {
        let first = try XCTUnwrap(harness.capture(.text("same thing"), in: self))
        try pipeline.ingest(first)

        // The monitor dedups consecutive identical contents by fingerprint, so
        // copy something else in between (as a user would).
        let other = try XCTUnwrap(harness.capture(.text("something else"), in: self))
        try pipeline.ingest(other)

        let again = try XCTUnwrap(harness.capture(.text("same thing"), in: self))
        XCTAssertNotEqual(again.id, first.id)
        try pipeline.ingest(again)

        XCTAssertEqual(try database.countEntries(), 2)
        let stored = try XCTUnwrap(database.fetch(id: first.id))
        XCTAssertEqual(stored.copyCount, 2)
        XCTAssertNil(try database.fetch(id: again.id), "the duplicate must fold into the existing row")
        XCTAssertEqual(try database.fetchRecent(limit: 1).first?.id, first.id, "a re-copy moves the row back to the head")
    }

    // MARK: - File paths

    func testMultiFileFinderCopyStaysFilePathAndPastesAllURLs() throws {
        // Two files: no single path covers most of the joined text, so the
        // text detectors alone re-type this as prose. The pasteboard carried
        // real file URLs, and that must win end to end (pasta-af5).
        let report = env.root.appendingPathComponent("report.pdf")
        let notes = env.root.appendingPathComponent("notes.txt")
        try Data("pdf".utf8).write(to: report)
        try "hello".write(to: notes, atomically: true, encoding: .utf8)

        let captured = try XCTUnwrap(harness.capture(.filePaths([report.path, notes.path]), in: self))
        XCTAssertEqual(captured.contentType, .filePath)
        XCTAssertEqual(captured.content, "\(report.path)\n\(notes.path)")

        // Precondition that makes this test meaningful: the detectors on their
        // own would NOT call this content a file path.
        let verdict = pipeline.detector.detect(in: captured.content, configuration: .default).primaryType
        XCTAssertNotEqual(verdict, .filePath, "detector verdict changed; this test no longer exercises the override")

        try pipeline.ingest(captured)
        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.contentType, .filePath, "enrichment must keep the monitor's file-path type")
        XCTAssertTrue(stored.contentTypeMask.contains(.filePath))

        let writer = E2EPasteboardWriter()
        let paste = PasteService(pasteboard: writer, simulator: E2EPasteSimulator())
        XCTAssertTrue(paste.paste(stored))
        guard case .fileURLs(let urls)? = writer.lastWrite else {
            return XCTFail("multi-file entries must be pasted as file URLs, got \(String(describing: writer.lastWrite))")
        }
        XCTAssertEqual(urls.map(\.path), [report.path, notes.path])
    }

    func testFilePathCopyRoundTripsAsFileURLs() throws {
        let file = env.root.appendingPathComponent("notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let captured = try XCTUnwrap(harness.capture(.filePaths([file.path]), in: self))
        XCTAssertEqual(captured.contentType, .filePath)
        XCTAssertEqual(captured.content, file.path)

        try pipeline.ingest(captured)
        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.contentType, .filePath)
        XCTAssertTrue(stored.contentTypeMask.contains(.filePath))
        let paths = try XCTUnwrap(e2eJSONDictionary(stored.metadata)?["filePaths"] as? [[String: Any]])
        XCTAssertEqual(paths.compactMap { $0["path"] as? String }, [file.path])
        XCTAssertEqual(paths.first?["exists"] as? Bool, true)

        let writer = E2EPasteboardWriter()
        let paste = PasteService(pasteboard: writer, simulator: E2EPasteSimulator())
        XCTAssertTrue(paste.paste(stored))
        guard case .fileURLs(let urls)? = writer.lastWrite else {
            return XCTFail("file path entries must be pasted as file URLs, got \(String(describing: writer.lastWrite))")
        }
        XCTAssertEqual(urls.map(\.path), [file.path])

        XCTAssertTrue(paste.pastePlainText(stored))
        XCTAssertEqual(writer.lastWrite, .text(stored.content))
    }

    // MARK: - Images

    func testImageCopyIsSpilledToDiskAndPastedBackAsTIFF() throws {
        let bytes = Data((0..<64_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        let captured = try XCTUnwrap(harness.capture(.image(bytes), in: self))
        XCTAssertEqual(captured.contentType, .image)
        XCTAssertEqual(captured.rawData, bytes)

        let result = try pipeline.ingest(captured)
        XCTAssertNil(result.primary.rawData, "image bytes must not be kept in the row")
        let imagePath = try XCTUnwrap(result.primary.imagePath)
        XCTAssertTrue(imagePath.hasPrefix(env.imagesURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)), bytes)

        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.contentType, .image)
        XCTAssertEqual(stored.imagePath, imagePath)
        XCTAssertNil(stored.rawData)
        XCTAssertEqual(stored.contentTypeMask, [])

        let row = ClipboardRowData(from: stored)
        XCTAssertTrue(row.prefersImageThumbnail)
        XCTAssertEqual(row.imagePath, imagePath)

        let writer = E2EPasteboardWriter()
        let paste = PasteService(pasteboard: writer, simulator: E2EPasteSimulator())
        XCTAssertTrue(paste.paste(stored))
        XCTAssertEqual(writer.lastWrite, .imageTIFF(bytes), "paste must reload the bytes from the image file")
        XCTAssertFalse(paste.pastePlainText(stored), "an image has no plain-text form")
    }

    func testScreenshotSourceAppTypesTheImageAsScreenshot() throws {
        let screenshotHarness = E2EMonitorHarness(sourceApp: "com.apple.screencaptureui", suite: "PastaE2E.flow.screenshot")
        defer { screenshotHarness.stop() }

        let captured = try XCTUnwrap(screenshotHarness.capture(.image(Data([1, 2, 3, 4])), in: self))
        XCTAssertEqual(captured.contentType, .screenshot)
        try pipeline.ingest(captured)
        XCTAssertEqual(try database.fetch(id: captured.id)?.contentType, .screenshot)
    }

    // MARK: - Env var blocks

    func testEnvVarBlockIsSplitIntoOneRowPerVariable() throws {
        let block = """
        export DATABASE_URL=postgres://localhost/pasta
        API_TIMEOUT=30
        """
        let captured = try XCTUnwrap(harness.capture(.text(block), in: self))
        let result = try pipeline.ingest(captured)

        XCTAssertEqual(result.envVarSplit.count, 2)
        XCTAssertNil(try database.fetch(id: captured.id), "the block itself is not stored; its variables are")
        let rows = try database.fetchRecent(limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.contentType == .envVar })
        XCTAssertEqual(Set(rows.map(\.content)), ["export DATABASE_URL=postgres://localhost/pasta", "API_TIMEOUT=30"])
        XCTAssertEqual(Set(rows.map(\.content)), Set(result.envVarSplit.map(\.content)))
        XCTAssertEqual(
            Set(rows.compactMap { e2eJSONDictionary($0.metadata)?["key"] as? String }),
            ["DATABASE_URL", "API_TIMEOUT"],
            "each split row keeps its variable name in metadata"
        )
    }

    // MARK: - Privacy and sync guards

    func testTransientPasteboardNeverReachesTheDatabase() throws {
        harness.pasteboard.transient = true
        let captured = harness.captureExpectingSilence(.text("hunter2"), in: self)
        XCTAssertNil(captured, "concealed pasteboard contents must not be emitted")
        XCTAssertEqual(try database.countEntries(), 0)

        // Positive control: the same pipeline captures once the flag clears.
        harness.pasteboard.transient = false
        let visible = try XCTUnwrap(harness.capture(.text("not a secret"), in: self))
        try pipeline.ingest(visible)
        XCTAssertEqual(try database.countEntries(), 1)
    }

    func testDisabledSyncManagerLeavesEntriesUnsyncedWithoutTouchingCloudKit() async throws {
        let captured = try XCTUnwrap(harness.capture(.text("stays local"), in: self))
        try pipeline.ingest(captured)

        let sync = SyncManager(containerIdentifier: "iCloud.com.pasta.e2e", syncEnabled: false)
        do {
            // Mirror the capture path: acknowledge only a successful upload.
            try await sync.pushEntry(captured)
            try database.markSynced(ids: [captured.id])
            XCTFail("Unavailable CloudKit must not acknowledge an upload")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .notAuthenticated)
        }

        XCTAssertEqual(try database.unsyncedCount(), 1)
        XCTAssertEqual(try database.fetchUnsynced().map(\.id), [captured.id])
        XCTAssertEqual(try database.syncedCount(), 0)
    }
}
