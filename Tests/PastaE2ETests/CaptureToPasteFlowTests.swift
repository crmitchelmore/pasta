import Foundation
import XCTest

import PastaDetectors
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

    func testTextCopiesAreClassifiedPersistedSearchedSplitAndPasted() throws {
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
        XCTAssertEqual(try database.searchFTS(query: "runbooks", contentType: nil, mixedOnly: true).map(\.id), [captured.id],
                       "the mixed filter keeps the parent and drops its extracted children")

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

        // A bare URL is typed as a URL and is filterable, with nothing to extract.
        let link = try XCTUnwrap(harness.capture(.text("https://github.com/crmitchelmore/pasta/pull/42"), in: self))
        try pipeline.ingest(link)
        let storedLink = try XCTUnwrap(database.fetch(id: link.id))
        XCTAssertEqual(storedLink.contentType, .url)
        XCTAssertTrue(storedLink.contentTypeMask.contains(.url))
        XCTAssertEqual(try database.fetchExtractedEntries(parentId: link.id).count, 0, "a bare URL has nothing to extract from itself")
        XCTAssertEqual(try database.fetchRecent(contentType: .url, limit: 10).first?.id, link.id)
        XCTAssertFalse(try database.fetchRecent(contentType: .email, limit: 10).contains { $0.id == link.id })
        XCTAssertEqual(try search.search(query: "github.com", contentType: .url).map(\.entry.id), [link.id])

        // An env var block is split into one row per variable; the block itself is not stored.
        let block = """
        export DATABASE_URL=postgres://localhost/pasta
        API_TIMEOUT=30
        """
        let envCapture = try XCTUnwrap(harness.capture(.text(block), in: self))
        let envResult = try pipeline.ingest(envCapture)
        XCTAssertEqual(envResult.envVarSplit.count, 2)
        XCTAssertNil(try database.fetch(id: envCapture.id), "the block itself is not stored; its variables are")
        let rows = try database.fetchRecent(contentType: .envVar, limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.content)), ["export DATABASE_URL=postgres://localhost/pasta", "API_TIMEOUT=30"])
        XCTAssertEqual(Set(rows.map(\.content)), Set(envResult.envVarSplit.map(\.content)))
        XCTAssertEqual(
            Set(rows.compactMap { e2eJSONDictionary($0.metadata)?["key"] as? String }),
            ["DATABASE_URL", "API_TIMEOUT"],
            "each split row keeps its variable name in metadata"
        )

        // Opting in to authoritative capture keeps the original block intact.
        let preserved = ClipboardEntry(content: "FOO=one\nBAR=two", contentType: .text)
        XCTAssertGreaterThan(try pipeline.enrich(preserved).envVarSplit.count, 0)
        pipeline.preserveEnvVarBlock = true
        let preservedResult = try pipeline.ingest(preserved)
        XCTAssertTrue(preservedResult.envVarSplit.isEmpty)
        XCTAssertEqual(preservedResult.primary.contentType, .envVarBlock)
        XCTAssertEqual(preservedResult.persisted.first?.content, preserved.content)
    }

    // MARK: - Monitor guards

    func testConcealedCopiesAreDroppedAndRecopiesFoldIntoTheCanonicalRow() throws {
        harness.pasteboard.transient = true
        XCTAssertNil(harness.captureExpectingSilence(.text("hunter2"), in: self), "concealed pasteboard contents must not be emitted")
        XCTAssertEqual(try database.countEntries(), 0)

        // Positive control: the same pipeline captures once the flag clears.
        harness.pasteboard.transient = false
        let visible = try XCTUnwrap(harness.capture(.text("not a secret"), in: self))
        try pipeline.ingest(visible)
        XCTAssertEqual(try database.countEntries(), 1)

        let first = try XCTUnwrap(harness.capture(.text("same thing"), in: self))
        let firstResult = try pipeline.ingest(first)
        XCTAssertEqual(firstResult.persisted.map(\.id), [first.id])
        // Pretend the first copy was uploaded, as BackgroundService would.
        try database.markSynced(ids: [first.id])

        // The monitor dedups consecutive identical contents by fingerprint, so
        // copy something else in between (as a user would).
        let other = try XCTUnwrap(harness.capture(.text("something else"), in: self))
        try pipeline.ingest(other)

        let again = try XCTUnwrap(harness.capture(.text("same thing"), in: self))
        XCTAssertNotEqual(again.id, first.id)
        let againResult = try pipeline.ingest(again)

        XCTAssertEqual(try database.countEntries(), 3)
        let stored = try XCTUnwrap(database.fetch(id: first.id))
        XCTAssertEqual(stored.copyCount, 2)
        XCTAssertNil(try database.fetch(id: again.id), "the duplicate must fold into the existing row")
        XCTAssertEqual(try database.fetchRecent(limit: 1).first?.id, first.id, "a re-copy moves the row back to the head")

        // Capture identity (pasta-109): what gets refreshed/uploaded/marked
        // synced is the CANONICAL row, and it is pending upload again because
        // its copyCount changed. `again.id` never existed remotely or locally.
        XCTAssertEqual(againResult.persisted.map(\.id), [first.id], "the persisted row is the existing one, not the discarded capture")
        XCTAssertFalse(stored.isSynced, "the canonical row must be re-uploaded with its new copyCount")
        let pending = try database.fetchUnsynced().map(\.id)
        XCTAssertTrue(pending.contains(first.id))
        XCTAssertFalse(pending.contains(again.id))
    }

    // MARK: - File paths

    func testFinderCopiesStayFilePathsAndPasteBackAsFileURLs() throws {
        let notes = env.root.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)

        let single = try XCTUnwrap(harness.capture(.filePaths([notes.path]), in: self))
        XCTAssertEqual(single.contentType, .filePath)
        XCTAssertEqual(single.content, notes.path)

        try pipeline.ingest(single)
        let storedSingle = try XCTUnwrap(database.fetch(id: single.id))
        XCTAssertEqual(storedSingle.contentType, .filePath)
        XCTAssertTrue(storedSingle.contentTypeMask.contains(.filePath))
        let paths = try XCTUnwrap(e2eJSONDictionary(storedSingle.metadata)?["filePaths"] as? [[String: Any]])
        XCTAssertEqual(paths.compactMap { $0["path"] as? String }, [notes.path])
        XCTAssertEqual(paths.first?["exists"] as? Bool, true)

        let writer = E2EPasteboardWriter()
        let paste = PasteService(pasteboard: writer, simulator: E2EPasteSimulator())
        XCTAssertTrue(paste.paste(storedSingle))
        guard case .fileURLs(let singleURLs)? = writer.lastWrite else {
            return XCTFail("file path entries must be pasted as file URLs, got \(String(describing: writer.lastWrite))")
        }
        XCTAssertEqual(singleURLs.map(\.path), [notes.path])

        XCTAssertTrue(paste.pastePlainText(storedSingle))
        XCTAssertEqual(writer.lastWrite, .text(storedSingle.content))

        // Two files: no single path covers most of the joined text, so the
        // text detectors alone re-type this as prose. The pasteboard carried
        // real file URLs, and that must win end to end (pasta-af5).
        let report = env.root.appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: report)

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

        XCTAssertTrue(paste.paste(stored))
        guard case .fileURLs(let urls)? = writer.lastWrite else {
            return XCTFail("multi-file entries must be pasted as file URLs, got \(String(describing: writer.lastWrite))")
        }
        XCTAssertEqual(urls.map(\.path), [report.path, notes.path])
    }

    // MARK: - Images

    func testImageAndScreenshotCopiesAreSpilledToDiskAndPastedBackAsTIFF() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<2 {
            for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) }
        }
        let bytes = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))

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

        // Read the real pasteboard representation a receiving app gets, not
        // merely an enum recorded by the fake writer. A unique board keeps
        // parallel tests independent and does not disturb the user's clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let paste = PasteService(pasteboard: SystemPasteboardWriter(pasteboard: pasteboard), simulator: E2EPasteSimulator())
        XCTAssertTrue(paste.paste(stored))
        let received = try XCTUnwrap(pasteboard.data(forType: .tiff))
        XCTAssertEqual(received, bytes, "paste must reload the bytes from the image file")
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: received), "A receiving app must be able to decode the pasted TIFF")
        XCTAssertEqual(decoded.pixelsWide, 2)
        XCTAssertEqual(decoded.pixelsHigh, 2)
        XCTAssertFalse(paste.pastePlainText(stored), "an image has no plain-text form")

        // A copy from the screenshot tool is typed as a screenshot.
        let screenshotHarness = E2EMonitorHarness(sourceApp: "com.apple.screencaptureui", suite: "PastaE2E.flow.screenshot")
        defer { screenshotHarness.stop() }

        let screenshot = try XCTUnwrap(screenshotHarness.capture(.image(Data([1, 2, 3, 4])), in: self))
        XCTAssertEqual(screenshot.contentType, .screenshot)
        try pipeline.ingest(screenshot)
        XCTAssertEqual(try database.fetch(id: screenshot.id)?.contentType, .screenshot)
    }

    // MARK: - Pinning, retention and deletion

    /// Mirrors BackgroundService's retention pass (prune by age, then by cap,
    /// then image cleanup) and the delete/clear actions behind the UI.
    func testPinningRetentionAndDeletionKeepFavouritesAndCleanUpImages() throws {
        let storage = try ImageStorageManager(imagesDirectoryURL: env.imagesURL, cleanupGracePeriod: 0)
        let deleter = DeleteService(database: database, imageStorage: storage)
        let now = Date()
        func insert(_ content: String, _ type: ContentType = .text, age: TimeInterval, imagePath: String? = nil) throws -> ClipboardEntry {
            try database.insert(ClipboardEntry(content: content, contentType: type, imagePath: imagePath,
                                               timestamp: now.addingTimeInterval(-age)), deduplicate: false).entry
        }
        let day: TimeInterval = 86_400
        let sharedPath = try storage.saveImage(Data([1, 1, 2, 3, 5, 8]))
        let uniquePath = try storage.saveImage(Data([2, 7, 1, 8, 2, 8]))
        _ = try insert("ancient shared image", .image, age: 40 * day, imagePath: sharedPath)
        _ = try insert("ancient unique image", .image, age: 50 * day, imagePath: uniquePath)
        let recentImage = try insert("recent shared image", .image, age: 1 * day, imagePath: sharedPath)
        let favourite = try insert("ancient pinned recipe", age: 45 * day)
        let older = try insert("older note", age: 4 * day)
        let middle = try insert("middle note", age: 3 * day)
        let newer = try insert("newer note", age: 2 * day)
        let fresh = try insert("fresh note", age: 60)

        XCTAssertTrue(try database.setPinned(id: favourite.id, pinned: true))
        XCTAssertFalse(try database.setPinned(id: UUID(), pinned: true), "pinning an unknown row reports failure")
        XCTAssertEqual(try database.pinnedCount(), 1)
        XCTAssertEqual(try database.fetchRecent(contentType: nil, limit: 10, pinnedOnly: true).map(\.id), [favourite.id])
        XCTAssertEqual(try database.searchFTS(query: "ancient", contentType: nil, pinnedOnly: true).map(\.id), [favourite.id])
        XCTAssertEqual(try database.searchFTS(query: "ancient", contentType: .image).count, 2)
        let counts = try database.quickSearchCounts()
        XCTAssertEqual(counts, QuickSearchCounts(types: [.image: 3, .text: 5], total: 8, pinned: 1))

        // Age-based retention keeps pins and only deletes images nothing else references.
        XCTAssertFalse(try database.pruneOlderThan(days: 0, now: now).didPrune, "a zero-day policy is disabled")
        let aged = try database.pruneOlderThan(days: 30, now: now)
        XCTAssertEqual(aged.deletedCount, 2)
        XCTAssertTrue(aged.didPrune)
        XCTAssertEqual(Set(aged.imagePaths), [sharedPath, uniquePath])
        try database.deleteUnreferencedImages(paths: aged.imagePaths, using: storage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedPath), "a file still referenced by a newer row must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: uniquePath))
        XCTAssertNotNil(try database.fetch(id: favourite.id), "pinned rows outlive the retention window")

        // The max-entries cap ignores pins and drops the oldest unpinned rows.
        XCTAssertEqual(try database.pruneToMaxEntries(0).deletedCount, 0, "a zero cap is disabled")
        XCTAssertEqual(try database.pruneToMaxEntries(10).deletedCount, 0, "under the cap nothing is pruned")
        let capped = try database.pruneToMaxEntries(4)
        XCTAssertEqual(capped.deletedCount, 1)
        XCTAssertNil(try database.fetch(id: older.id))
        XCTAssertNotNil(try database.fetch(id: favourite.id))

        // Explicit deletes from the UI.
        XCTAssertEqual(try deleter.delete(ids: []), 0)
        XCTAssertTrue(try deleter.delete(id: middle.id))
        XCTAssertFalse(try deleter.delete(id: middle.id), "a second delete of the same row is a no-op")
        XCTAssertEqual(try deleter.deleteRecent(minutes: 10, now: now), 1)
        XCTAssertNil(try database.fetch(id: fresh.id))
        XCTAssertEqual(try deleter.delete(ids: [newer.id, UUID()]), 1)

        // Clear keeps favourites unless the user asks to wipe everything.
        XCTAssertEqual(try deleter.deleteAll(), 1)
        XCTAssertNil(try database.fetch(id: recentImage.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedPath), "the last reference is gone, so the file is removed")
        XCTAssertEqual(try database.fetchRecent(limit: 10).map(\.id), [favourite.id])
        XCTAssertEqual(try deleter.deleteAll(includePinned: true), 1)
        XCTAssertEqual(try database.countEntries(), 0)
        XCTAssertEqual(try database.quickSearchCounts(), QuickSearchCounts())
    }
}
