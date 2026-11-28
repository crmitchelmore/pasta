import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class DatabaseManagerTests: XCTestCase {
    func testInsertDeduplicationAndSyncState() throws {
        for deduplicate in [true, false] {
            let db = try DatabaseManager.inMemory()
            let remote = ClipboardEntry(content: "downloaded", contentType: .text, isSynced: true)
            let local = ClipboardEntry(content: "captured locally", contentType: .text)
            try db.insert(remote, deduplicate: deduplicate)
            try db.insert(local, deduplicate: deduplicate)
            XCTAssertEqual(try db.fetch(id: remote.id)?.isSynced, true)
            XCTAssertEqual(try db.fetchUnsynced().map(\.id), [local.id])
            XCTAssertEqual(try db.syncedCount(), 1)
        }

        let db = try DatabaseManager.inMemory()
        // Whole-second timestamps: the column stores millisecond precision.
        let first = ClipboardEntry(content: "same thing", contentType: .text, timestamp: Date(timeIntervalSince1970: 1_000))
        guard case .inserted(let persisted) = try db.insert(first, deduplicate: true) else {
            return XCTFail("a fresh row must be reported as inserted")
        }
        XCTAssertEqual(persisted.id, first.id)
        try db.markSynced(ids: [first.id])
        XCTAssertEqual(try db.unsyncedCount(), 0)

        // Identical content folds into the existing row and the caller learns
        // which row that is: uploading `again.id` would create a phantom remote
        // record (pasta-109).
        let again = ClipboardEntry(content: "same thing", contentType: .text, timestamp: first.timestamp.addingTimeInterval(60))
        let outcome = try db.insert(again, deduplicate: true)
        guard case .deduplicated(let canonical) = outcome else {
            return XCTFail("identical content must deduplicate, got \(outcome)")
        }
        XCTAssertEqual(canonical.id, first.id)
        XCTAssertEqual(canonical.copyCount, 2)
        XCTAssertEqual(canonical.timestamp, again.timestamp)
        XCTAssertFalse(canonical.isSynced, "the canonical row changed (copyCount), so it must upload again")
        XCTAssertEqual(outcome.entry.id, first.id)
        XCTAssertFalse(outcome.isNewRow)
        XCTAssertNil(try db.fetch(id: again.id))
        XCTAssertEqual(try db.fetchUnsynced().map(\.id), [first.id])
        XCTAssertEqual(try db.countEntries(), 1)

        let distinct = ClipboardEntry(content: "same thing", contentType: .text)
        XCTAssertEqual(try db.insert(distinct, deduplicate: false), .inserted(distinct))
        XCTAssertEqual(try db.countEntries(), 2)

        let mixed = (0..<1_001).map { index in
            ClipboardEntry(content: "entry \(index)", contentType: .text, isSynced: index.isMultiple(of: 2))
        }
        let batchDB = try DatabaseManager.inMemory()
        try batchDB.insertBatch(mixed)
        XCTAssertEqual(try batchDB.syncedCount(), 501)
        XCTAssertEqual(try batchDB.unsyncedCount(), 500)
        XCTAssertEqual(Set(try batchDB.fetchUnsynced().map(\.id)), Set(mixed.filter { !$0.isSynced }.map(\.id)))
    }

    func testFTSSurvivesMetadataOnlyUpdatesAndTracksContentChanges() throws {
        let db = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(content: "quarterly aardvark report", contentType: .text)
        try db.insert(entry, deduplicate: false)
        XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).count, 1)

        XCTAssertTrue(try db.setPinned(id: entry.id, pinned: true))
        try db.markSynced(ids: [entry.id])
        try db.insert(ClipboardEntry(content: "quarterly aardvark report", contentType: .text), deduplicate: true)
        XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).count, 1)
        XCTAssertEqual(try db.fetch(id: entry.id)?.copyCount, 2)

        try db.databaseWriterForSnippets.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE clipboard_entries
                SET content = 'quarterly pangolin report'
                WHERE id = '\(entry.id.uuidString)'
                """)
        }
        XCTAssertTrue(try db.searchFTS(query: "aardvark", contentType: nil).isEmpty)
        XCTAssertEqual(try db.searchFTS(query: "pangolin", contentType: nil).count, 1)
    }

    func testInsertBatchSkipsDuplicatesWithoutBumpingThem() throws {
        let db = try DatabaseManager.inMemory()
        var entries: [ClipboardEntry] = []
        for index in 0..<3_000 {
            entries.append(ClipboardEntry(content: "entry \(index)", contentType: .text, timestamp: Date(timeIntervalSince1970: Double(index))))
            if index % 10 == 0 {
                entries.append(ClipboardEntry(content: "entry \(index)", contentType: .text, timestamp: Date(timeIntervalSince1970: Double(index) + 0.5)))
            }
        }
        let result = try db.insertBatch(entries)
        XCTAssertEqual(result.inserted, 3_000)
        XCTAssertEqual(result.skipped, 300)

        let rerun = try db.insertBatch(entries)
        XCTAssertEqual(rerun.inserted, 0)
        XCTAssertEqual(rerun.skipped, 3_300)
        XCTAssertEqual(try db.countEntries(), 3_000)
        // Importers only add history they don't have; they never bump copyCount.
        XCTAssertEqual(try db.search(query: "entry 0").first?.copyCount, 1)

        let plain = try DatabaseManager.inMemory()
        let same = (0..<10).map { _ in ClipboardEntry(content: "same needle", contentType: .text) }
        let undeduplicated = try plain.insertBatch(same, deduplicate: false)
        XCTAssertEqual(undeduplicated.inserted, 10)
        XCTAssertEqual(undeduplicated.skipped, 0)
        XCTAssertEqual(try plain.searchFTS(query: "needle", contentType: nil).count, 10)
    }

    func testOnDiskConnections() throws {
        XCTAssertTrue(try DatabaseManager.inMemory().dbWriter is DatabaseQueue)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaDatabasePoolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pasta.sqlite")
        let app = try DatabaseManager(databaseURL: url)
        XCTAssertTrue(app.dbWriter is DatabasePool)

        XCTContext.runActivity(named: "reads are not serialised behind a write") { _ in
            let writeStarted = DispatchSemaphore(value: 0)
            let releaseWrite = DispatchSemaphore(value: 0)
            let writeFinished = expectation(description: "write finished")
            DispatchQueue.global(qos: .utility).async {
                defer { writeFinished.fulfill() }
                try? app.dbWriter.write { _ in
                    writeStarted.signal()
                    _ = releaseWrite.wait(timeout: .now() + 5)
                }
            }
            XCTAssertEqual(writeStarted.wait(timeout: .now() + 2), .success)
            let readFinished = expectation(description: "read finished")
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? app.countEntries()
                readFinished.fulfill()
            }
            let readResult = XCTWaiter.wait(for: [readFinished], timeout: 1)
            releaseWrite.signal()
            wait(for: [writeFinished], timeout: 2)
            XCTAssertEqual(readResult, .completed)
        }

        // The main window skips its reopen reload unless dataVersion() moved:
        // it must ignore the manager's own writes yet see other connections.
        let settings = try DatabaseManager(databaseURL: url)
        let initial = try app.dataVersion()
        let own = ClipboardEntry(content: "own write", contentType: .text)
        _ = try app.insert(own)
        _ = try app.setPinned(id: own.id, pinned: true)
        _ = try app.delete(id: own.id)
        XCTAssertEqual(try app.dataVersion(), initial)

        let foreign = ClipboardEntry(content: "foreign write", contentType: .text)
        _ = try settings.insert(foreign)
        let afterForeignInsert = try app.dataVersion()
        XCTAssertNotEqual(afterForeignInsert, initial)
        XCTAssertEqual(try app.dataVersion(), afterForeignInsert)
        XCTAssertTrue(try settings.delete(id: foreign.id))
        XCTAssertNotEqual(try app.dataVersion(), afterForeignInsert)
    }

    func testHistoryPagingAndOrdering() throws {
        let db = try DatabaseManager.inMemory()
        let hello = ClipboardEntry(content: "hello world", contentType: .text, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        try db.insert(hello)
        XCTAssertEqual(try db.fetchAll().map(\.id), [hello.id])
        XCTAssertEqual(try db.search(query: "hello").map(\.id), [hello.id])
        XCTAssertTrue(try db.delete(id: hello.id))
        XCTAssertEqual(try db.fetchAll().count, 0)

        for index in 0..<5 {
            try db.insert(ClipboardEntry(content: "entry \(index)", contentType: .text, timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        XCTAssertEqual(try db.fetchRecent(limit: 2).map(\.content), ["entry 4", "entry 3"])
        let first = try db.fetchHistoryPage(after: nil, limit: 2)
        XCTAssertEqual(first.entries.map(\.content), ["entry 4", "entry 3"])
        let second = try db.fetchHistoryPage(after: first.nextCursor, limit: 2)
        XCTAssertEqual(second.entries.map(\.content), ["entry 2", "entry 1"])
        let third = try db.fetchHistoryPage(after: second.nextCursor, limit: 2)
        XCTAssertEqual(third.entries.map(\.content), ["entry 0"])
        let fourth = try db.fetchHistoryPage(after: third.nextCursor, limit: 2)
        XCTAssertTrue(fourth.entries.isEmpty)
        XCTAssertNil(fourth.nextCursor)
        XCTAssertTrue(try db.fetchHistoryPage(after: nil, limit: 0).entries.isEmpty)

        // Equal timestamps: rowid breaks the tie so nothing repeats or is skipped.
        let ties = try DatabaseManager.inMemory()
        let shared = Date(timeIntervalSince1970: 100)
        try ties.insertBatch((0..<7).map { ClipboardEntry(content: "tie \($0)", contentType: .text, timestamp: shared) }, deduplicate: false)
        var seen: [UUID] = []
        var cursor: DatabaseManager.HistoryCursor?
        repeat {
            let page = try ties.fetchHistoryPage(after: cursor, limit: 3)
            seen.append(contentsOf: page.entries.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(Set(seen).count, 7)
        XCTAssertEqual(try ties.fetchRecent(limit: 7).map(\.id), seen)

        let plan: [String] = try ties.dbWriter.read { conn in
            try Row.fetchAll(
                conn,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT rowid, * FROM clipboard_entries
                WHERE (timestamp, rowid) < (?, ?)
                ORDER BY timestamp DESC, rowid DESC
                LIMIT ?
                """,
                arguments: [Date(), 1, 10]
            ).map { $0["detail"] as String }
        }
        XCTAssertTrue(plan.contains { $0.contains("idx_clipboard_entries_timestamp") }, "\(plan)")
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
    }

    func testDeletesReturnImagePaths() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        try db.insert(ClipboardEntry(content: "old", contentType: .text, timestamp: now.addingTimeInterval(-600)))
        try db.insert(ClipboardEntry(content: "recent", contentType: .text, timestamp: now.addingTimeInterval(-60)))
        try db.insert(ClipboardEntry(content: "recentImage", contentType: .image, imagePath: "/tmp/fake.png", timestamp: now.addingTimeInterval(-30)))
        let recent = try db.deleteRecent(minutes: 5, now: now)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.imagePaths, ["/tmp/fake.png"])
        XCTAssertEqual(try db.fetchAll().map(\.content), ["old"])

        try db.insert(ClipboardEntry(content: "b", contentType: .image, imagePath: "/tmp/b.png"))
        let all = try db.deleteAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.imagePaths, ["/tmp/b.png"])
        XCTAssertEqual(try db.countEntries(), 0)

        let entries: [ClipboardEntry] = (0..<1_200).map { (index: Int) -> ClipboardEntry in
            let isImage = index % 3 == 0
            return ClipboardEntry(
                content: "bulk \(index)",
                contentType: isImage ? ContentType.image : ContentType.text,
                imagePath: isImage ? "/tmp/bulk-\(index).png" : nil,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        try db.insertBatch(entries, deduplicate: false)
        XCTAssertTrue(try db.setPinned(id: entries[0].id, pinned: true))
        // Spans more than one 500-ID chunk, and pinned rows go like single deletes.
        let doomed = Array(entries.prefix(700))
        let bulk = try db.delete(ids: doomed.map(\.id))
        XCTAssertEqual(bulk.count, 700)
        XCTAssertEqual(Set(bulk.imagePaths), Set(doomed.compactMap(\.imagePath)))
        XCTAssertEqual(try db.countEntries(), 500)
        XCTAssertNil(try db.fetch(id: doomed[0].id))
        XCTAssertNotNil(try db.fetch(id: entries[700].id))

        let none = try db.delete(ids: [])
        XCTAssertEqual(none.count, 0)
        XCTAssertTrue(none.imagePaths.isEmpty)
        XCTAssertEqual(try db.countEntries(), 500)
    }

    func testExtractedEntriesAndReclassification() throws {
        let db = try DatabaseManager.inMemory()
        let parent = ClipboardEntry(content: "Contact me at test@example.com", contentType: .text, metadata: "{\"legacy\":true}")
        let staleExtracted = ClipboardEntry(content: "old@example.com", contentType: .email, parentEntryId: parent.id)
        let otherParent = ClipboardEntry(content: "other", contentType: .text)
        let otherChild = ClipboardEntry(content: "keep@example.com", contentType: .email, parentEntryId: otherParent.id)
        let orphan = ClipboardEntry(content: "orphan", contentType: .email, parentEntryId: UUID())
        for entry in [parent, staleExtracted, otherParent, otherChild, orphan] {
            try db.insert(entry, deduplicate: false)
        }
        XCTAssertEqual(Set(try db.fetchPrimaryEntries().map(\.id)), [parent.id, otherParent.id])

        let metadata = "{\"emails\":[{\"email\":\"test@example.com\"}]}"
        let result = try db.applyReclassificationChunk(
            updates: [DatabaseManager.ReclassificationUpdate(entryID: parent.id, contentType: .prose, metadata: metadata)],
            parentIDs: [parent.id],
            extractedEntries: [
                ClipboardEntry(content: "test@example.com", contentType: .email, parentEntryId: parent.id),
                ClipboardEntry(content: "https://example.com", contentType: .url, parentEntryId: parent.id),
            ]
        )
        XCTAssertEqual(result.updatedEntries, 1)
        XCTAssertEqual(result.removedExtractedEntries, 1)
        XCTAssertEqual(result.insertedExtractedEntries, 2)
        let updatedParent = try db.fetch(id: parent.id)
        XCTAssertEqual(updatedParent?.contentType, .prose)
        XCTAssertEqual(updatedParent?.metadata, metadata)
        XCTAssertEqual(Set(try db.fetchExtractedEntries(parentId: parent.id).map(\.content)), ["test@example.com", "https://example.com"])
        XCTAssertEqual(try db.fetchExtractedEntries(parentId: otherParent.id).map(\.content), ["keep@example.com"])

        XCTAssertEqual(try db.deleteOrphanedExtractedEntries(), 1)
        XCTAssertNil(try db.fetch(id: orphan.id))
        XCTAssertNotNil(try db.fetch(id: otherChild.id))

        // Keyset pages visit every primary once even when rows land mid-walk.
        let paged = try DatabaseManager.inMemory()
        var expected: Set<UUID> = []
        for index in 0..<25 {
            let entry = ClipboardEntry(content: "primary \(index)", contentType: .text, timestamp: Date(timeIntervalSince1970: Double(1_000 + index)))
            expected.insert(entry.id)
            try paged.insert(entry, deduplicate: false)
            try paged.insert(ClipboardEntry(content: "child \(index)", contentType: .email, parentEntryId: entry.id), deduplicate: false)
        }
        var seen: [UUID] = []
        var cursor: DatabaseManager.PrimaryEntryCursor?
        var pages = 0
        while true {
            let page = try paged.fetchPrimaryEntries(after: cursor, limit: 10)
            guard !page.isEmpty else { break }
            pages += 1
            seen.append(contentsOf: page.map(\.id))
            cursor = DatabaseManager.PrimaryEntryCursor(after: page[page.count - 1])
            try paged.insert(
                ClipboardEntry(content: "captured during walk \(pages)", contentType: .text, timestamp: Date(timeIntervalSince1970: 10_000 + Double(pages))),
                deduplicate: false
            )
        }
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(seen.count, 25)
        XCTAssertEqual(Set(seen), expected)
    }

    func testSyncBookkeeping() async throws {
        let db = try DatabaseManager.inMemory()
        let skipped = try await db.backfillUnsynced { _, _ in 99 }
        XCTAssertEqual(skipped, 0, "nothing pending skips the uploader")

        let entries = (0..<5).map { ClipboardEntry(content: "sync \($0)", contentType: .text, timestamp: Date(timeIntervalSince1970: Double($0))) }
        try db.insertBatch(entries, deduplicate: false)
        XCTAssertEqual(try db.fetchUnsynced().map(\.content), ["sync 4", "sync 3", "sync 2", "sync 1", "sync 0"])
        XCTAssertEqual(try db.fetchUnsynced(limit: 2).map(\.content), ["sync 4", "sync 3"])
        try db.markSynced(ids: [entries[3].id, entries[4].id])
        XCTAssertEqual(try db.syncedCount(), 2)
        XCTAssertEqual(try db.fetchUnsynced().map(\.content), ["sync 2", "sync 1", "sync 0"])

        struct UploadFailure: Error {}
        do {
            _ = try await db.backfillUnsynced { pending, onBatchSynced in
                onBatchSynced([pending[0].id])
                throw UploadFailure()
            }
            XCTFail("Expected the later upload batch to fail")
        } catch is UploadFailure {}
        XCTAssertEqual(try db.unsyncedCount(), 2, "the confirmed batch is durable; the rest stay pending")

        let uploaded = try await db.backfillUnsynced { pending, onBatchSynced in
            XCTAssertEqual(pending.count, 2)
            onBatchSynced([pending[0].id])
            onBatchSynced(Array(pending.dropFirst()).map(\.id))
            return pending.count
        }
        XCTAssertEqual(uploaded, 2)
        XCTAssertEqual(try db.unsyncedCount(), 0)

        try db.insert(ClipboardEntry(content: "downloaded", contentType: .text, isSynced: true))
        let none = try await db.backfillUnsynced { _, _ in
            XCTFail("Downloaded entries must not enter the upload queue")
            return 0
        }
        XCTAssertEqual(none, 0)
    }

    func testRetentionPruning() throws {
        let db = try DatabaseManager.inMemory()
        for index in 0..<10 {
            try db.insert(ClipboardEntry(
                content: "prune \(index)",
                contentType: index == 0 ? .image : .text,
                imagePath: index == 0 ? "/tmp/prune-0.png" : nil,
                timestamp: Date(timeIntervalSince1970: Double(index))
            ))
        }
        for cap in [50, 10] {
            let result = try db.pruneToMaxEntries(cap)
            XCTAssertFalse(result.didPrune, "cap \(cap)")
            XCTAssertEqual(result.deletedCount, 0)
            XCTAssertTrue(result.imagePaths.isEmpty)
        }
        let oldestPinned = try XCTUnwrap(try db.fetchAll().last)
        XCTAssertTrue(try db.setPinned(id: oldestPinned.id, pinned: true))
        let pruned = try db.pruneToMaxEntries(4)
        XCTAssertTrue(pruned.didPrune)
        XCTAssertEqual(pruned.deletedCount, 5, "9 unpinned rows, keep the newest 4")
        XCTAssertTrue(try db.fetchAll().contains { $0.id == oldestPinned.id })

        let aged = try DatabaseManager.inMemory()
        let now = Date(timeIntervalSince1970: 10_000_000)
        try aged.insert(ClipboardEntry(content: "fresh", contentType: .text, timestamp: now.addingTimeInterval(-3_600)))
        XCTAssertFalse(try aged.pruneOlderThan(days: 30, now: now).didPrune)
        try aged.insert(ClipboardEntry(content: "ancient", contentType: .image, imagePath: "/tmp/ancient.png", timestamp: now.addingTimeInterval(-100 * 86_400)))
        let old = try aged.pruneOlderThan(days: 30, now: now)
        XCTAssertTrue(old.didPrune)
        XCTAssertEqual(old.deletedCount, 1)
        XCTAssertEqual(old.imagePaths, ["/tmp/ancient.png"])
        XCTAssertEqual(try aged.countEntries(), 1)
    }
}
