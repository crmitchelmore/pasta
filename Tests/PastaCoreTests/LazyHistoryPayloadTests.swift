import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class LazyHistoryPayloadTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!

    // Multi-byte text so byte counts, code-point previews and grapheme
    // counts all differ.
    private let largeContent = String(repeating: "Log line é ✓ 🍝 with detail\n", count: 4_000)
    private let largeRawData = Data(String(repeating: "<p>rich</p>", count: 10_000).utf8)
    private lazy var largeMetadata: String = {
        let emails = (0..<3_000).map { #"{"email":"user\#($0)@example.com"}"# }.joined(separator: ",")
        return #"{"emails":["# + emails + "]}"
    }()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try makeDatabase()
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// On-disk pool, as in the app: lazy loads must work from pool readers
    /// and from inside the writer.
    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager(databaseURL: directory.appendingPathComponent("pasta-\(UUID().uuidString).sqlite"))
    }

    private func insertLargeEntry() throws -> ClipboardEntry {
        XCTAssertGreaterThan(largeContent.utf8.count, LazyPayload.thresholdBytes)
        XCTAssertGreaterThan(largeMetadata.utf8.count, LazyPayload.thresholdBytes)
        let entry = ClipboardEntry(content: largeContent, contentType: .prose, rawData: largeRawData, metadata: largeMetadata)
        _ = try database.insert(entry, deduplicate: false)
        return entry
    }

    private func historyEntry(_ id: UUID, in db: DatabaseManager? = nil) throws -> ClipboardEntry {
        try XCTUnwrap((db ?? database).fetchHistoryPage(after: nil, limit: 100).entries.first { $0.id == id })
    }

    func testLazyPayloadLifecycle() throws {
        let original = try insertLargeEntry()
        let lazy = try historyEntry(original.id)
        XCTAssertTrue(lazy.hasUnloadedPayload)
        XCTAssertTrue(lazy.isPreviewContentTruncated)
        XCTAssertEqual(lazy.previewContent.unicodeScalars.count, LazyPayload.previewCharacters)
        XCTAssertTrue(largeContent.utf8.starts(with: lazy.previewContent.utf8))
        XCTAssertEqual(lazy.contentByteCount, largeContent.utf8.count)
        XCTAssertEqual(lazy.metadataByteCount, largeMetadata.utf8.count)
        // Derived from columns fetched in full, never the lazy metadata.
        XCTAssertEqual(lazy.contentTypeMask, original.contentTypeMask)
        XCTAssertEqual(lazy.contentHash, original.contentHash)
        XCTAssertTrue(lazy.hasUnloadedPayload, "contentHash must use the stored hash")

        // Copies share one load.
        let copy = lazy
        XCTAssertEqual(copy.content, largeContent)
        XCTAssertEqual(copy.rawData, largeRawData)
        XCTAssertEqual(copy.metadata, largeMetadata)
        XCTAssertFalse(lazy.hasUnloadedPayload)

        // Getters work inside reader and writer access.
        let readLazy = try historyEntry(original.id)
        let writeLazy = try historyEntry(original.id)
        XCTAssertEqual(try database.dbWriter.read { _ in readLazy.content }, largeContent)
        XCTAssertEqual(try database.dbWriter.write { _ in writeLazy.metadata }, largeMetadata)

        // Every fetch other than the history page stays full.
        XCTAssertFalse(try XCTUnwrap(database.fetch(id: original.id)).hasUnloadedPayload)
        XCTAssertFalse(try XCTUnwrap(database.fetchAll().first).hasUnloadedPayload)
        XCTAssertFalse(try XCTUnwrap(database.fetchRecent(limit: 1).first).hasUnloadedPayload)

        // Small rows and image rows (which thumbnail their raw data) are never deferred.
        let small = ClipboardEntry(content: "hello", contentType: .text, metadata: #"{"emails":[]}"#)
        let image = ClipboardEntry(content: "image", contentType: .image, rawData: largeRawData)
        _ = try database.insert(small, deduplicate: false)
        _ = try database.insert(image, deduplicate: false)
        let fetchedSmall = try historyEntry(small.id)
        XCTAssertFalse(fetchedSmall.hasUnloadedPayload)
        XCTAssertFalse(fetchedSmall.isPreviewContentTruncated)
        XCTAssertEqual(fetchedSmall.previewContent, "hello")
        XCTAssertEqual(fetchedSmall, try database.fetch(id: small.id))
        let fetchedImage = try historyEntry(image.id)
        XCTAssertFalse(fetchedImage.hasUnloadedPayload)
        XCTAssertEqual(fetchedImage.rawData, largeRawData)

        let paged = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var expected: [UUID] = []
        for i in 0..<9 {
            let content = i.isMultiple(of: 3) ? largeContent + "\(i)" : "small \(i)"
            let entry = ClipboardEntry(content: content, contentType: .text, timestamp: base.addingTimeInterval(Double(i)))
            _ = try paged.insert(entry, deduplicate: false)
            expected.insert(entry.id, at: 0)
        }
        var ids: [UUID] = []
        var cursor: DatabaseManager.HistoryCursor?
        repeat {
            let page = try paged.fetchHistoryPage(after: cursor, limit: 2)
            ids += page.entries.map(\.id)
            cursor = page.entries.isEmpty ? nil : page.nextCursor
        } while cursor != nil
        XCTAssertEqual(ids, expected)

        let retaining = try makeDatabase()
        for i in 0..<20 {
            _ = try retaining.insert(ClipboardEntry(content: largeContent + "\(i)", contentType: .text), deduplicate: false)
        }
        let entries = try retaining.fetchHistoryPage(after: nil, limit: 100).entries
        let retained = entries.reduce(0) { $0 + $1.previewContent.utf8.count }
        let full = entries.reduce(0) { $0 + $1.contentByteCount }
        XCTAssertEqual(entries.count, 20)
        XCTAssertLessThan(retained * 3, full, "retained \(retained) of \(full) bytes")
        XCTAssertTrue(entries.allSatisfy(\.hasUnloadedPayload))
    }

    func testEqualityNeverLoadsAndSettersReplaceLazyColumns() throws {
        let original = try insertLargeEntry()
        let lazy = try historyEntry(original.id)
        let refetched = try historyEntry(original.id)
        let full = try XCTUnwrap(database.fetch(id: original.id))
        XCTAssertEqual(lazy, refetched)
        XCTAssertEqual(lazy, full)
        XCTAssertEqual(full, lazy)
        XCTAssertTrue(lazy.hasSameContent(as: full))
        XCTAssertTrue(lazy.hasSameMetadata(as: refetched))

        let content = largeContent
        let edits: [(String, (inout ClipboardEntry) -> Void)] = [
            ("pinned", { $0.isPinned = true }),
            ("edited tail", { $0.content = content + "!" }),
            ("edited head", { $0.content = "X" + content.dropFirst() }),
            ("shorter metadata", { $0.metadata = #"{"emails":[]}"# }),
        ]
        for (name, edit) in edits {
            var changed = full
            edit(&changed)
            XCTAssertNotEqual(lazy, changed, name)
        }
        XCTAssertTrue(lazy.hasUnloadedPayload)
        XCTAssertTrue(refetched.hasUnloadedPayload)

        var entry = refetched
        entry.content = "replaced"
        XCTAssertEqual(entry.content, "replaced")
        XCTAssertEqual(entry.previewContent, "replaced")
        XCTAssertFalse(entry.isPreviewContentTruncated)
        XCTAssertEqual(entry.contentByteCount, 8)
        XCTAssertEqual(entry.contentHash, ClipboardEntry.sha256Hex("replaced"))
        entry.metadata = nil
        XCTAssertNil(entry.metadata)
        XCTAssertNil(entry.metadataByteCount)
        XCTAssertEqual(entry.contentTypeMask, [])
        entry.rawData = nil
        XCTAssertNil(entry.rawData)
        XCTAssertFalse(entry.hasUnloadedPayload)
    }

    func testPersistenceAndPasteUseTheFullPayload() throws {
        let original = try insertLargeEntry()
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(try historyEntry(original.id)))
        XCTAssertEqual(decoded.content, largeContent)
        XCTAssertEqual(decoded.rawData, largeRawData)
        XCTAssertEqual(decoded.metadata, largeMetadata)

        // PersistableRecord encoding reads the lazy columns on the writer
        // connection inside the write.
        var pinned = try historyEntry(original.id)
        pinned.isPinned = true
        try database.dbWriter.write { db in try pinned.update(db) }
        let stored = try XCTUnwrap(database.fetch(id: original.id))
        XCTAssertTrue(stored.isPinned)
        XCTAssertEqual(stored.content, largeContent)
        XCTAssertEqual(stored.rawData, largeRawData)
        XCTAssertEqual(stored.metadata, largeMetadata)

        #if canImport(AppKit) && canImport(ApplicationServices)
        final class Pasteboard: PasteboardWriting {
            var written: PasteService.Contents?
            func write(_ contents: PasteService.Contents) { written = contents }
            func saveCurrentContents() -> PasteService.SavedContents? { nil }
            func restore(_ contents: PasteService.SavedContents) {}
        }
        final class Simulator: PasteEventSimulating {
            func simulateCommandV() {}
        }
        let text = ClipboardEntry(content: largeContent, contentType: .text)
        _ = try database.insert(text, deduplicate: false)
        let lazyText = try historyEntry(text.id)
        XCTAssertTrue(lazyText.hasUnloadedPayload)
        let pasteboard = Pasteboard()
        let service = PasteService(pasteboard: pasteboard, simulator: Simulator(), isAccessibilityTrusted: { true })
        XCTAssertTrue(service.copy(lazyText))
        XCTAssertEqual(pasteboard.written, .text(largeContent))
        #endif

        // A deleted row falls back to its preview but never persists it.
        let lazy = try historyEntry(original.id)
        XCTAssertTrue(try database.delete(id: original.id))
        XCTAssertEqual(lazy.content, lazy.previewContent)
        XCTAssertNil(lazy.metadata)
        XCTAssertThrowsError(try JSONEncoder().encode(lazy))
        XCTAssertThrowsError(try database.dbWriter.write { db in try lazy.insert(db) })
        XCTAssertNil(try database.fetch(id: original.id))
    }
}
