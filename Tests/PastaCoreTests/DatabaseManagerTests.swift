import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class DatabaseManagerTests: XCTestCase {
    func testOnDiskDatabaseUsesPoolAndAllowsReadDuringWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaDatabasePoolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("pasta.sqlite"))
        XCTAssertTrue(manager.dbWriter is DatabasePool)

        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writeFinished = expectation(description: "write finished")
        DispatchQueue.global(qos: .utility).async {
            defer { writeFinished.fulfill() }
            try? manager.dbWriter.write { _ in
                writeStarted.signal()
                _ = releaseWrite.wait(timeout: .now() + 5)
            }
        }

        XCTAssertEqual(writeStarted.wait(timeout: .now() + 2), .success)

        let readFinished = expectation(description: "read was not serialized behind write")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? manager.countEntries()
            readFinished.fulfill()
        }

        let readResult = XCTWaiter.wait(for: [readFinished], timeout: 1)
        releaseWrite.signal()
        wait(for: [writeFinished], timeout: 2)
        XCTAssertEqual(readResult, .completed)
    }

    func testInMemoryDatabaseKeepsSerializedQueue() throws {
        let manager = try DatabaseManager.inMemory()
        XCTAssertTrue(manager.dbWriter is DatabaseQueue)
    }

    func testCRUD() throws {
        let db = try DatabaseManager.inMemory()

        let entry = ClipboardEntry(
            id: UUID(uuidString: "3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F")!,
            content: "hello world",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try db.insert(entry)

        let all = try db.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, entry.id)

        let results = try db.search(query: "hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, entry.id)

        let deleted = try db.delete(id: entry.id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(try db.fetchAll().count, 0)
    }

    func testInsertPreservesCloudSyncState() throws {
        let db = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(
            content: "downloaded from iCloud",
            contentType: .text,
            isSynced: true
        )

        try db.insert(entry, deduplicate: false)

        XCTAssertEqual(try db.fetch(id: entry.id)?.isSynced, true)
        XCTAssertEqual(try db.unsyncedCount(), 0)
    }

    func testBatchInsertPreservesCloudSyncState() throws {
        let db = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(
            content: "batch downloaded from iCloud",
            contentType: .text,
            isSynced: true
        )

        try db.insertBatch([entry], deduplicate: false)

        XCTAssertEqual(try db.fetch(id: entry.id)?.isSynced, true)
        XCTAssertEqual(try db.unsyncedCount(), 0)
    }

    func testFetchRecentOrdersByTimestampDesc() throws {
        let db = try DatabaseManager.inMemory()

        let older = ClipboardEntry(
            content: "older",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let newer = ClipboardEntry(
            content: "newer",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 2)
        )

        try db.insert(older)
        try db.insert(newer)

        let recent = try db.fetchRecent(limit: 2)
        XCTAssertEqual(recent.map(\.content), ["newer", "older"])
    }

    func testFetchRecentSupportsOffsetAndCountsEntries() throws {
        let db = try DatabaseManager.inMemory()

        for index in 0..<5 {
            try db.insert(ClipboardEntry(
                content: "entry \(index)",
                contentType: .text,
                timestamp: Date(timeIntervalSince1970: Double(index))
            ))
        }

        XCTAssertEqual(try db.countEntries(), 5)

        let page = try db.fetchRecent(limit: 2, offset: 2)
        XCTAssertEqual(page.map(\.content), ["entry 2", "entry 1"])
    }

    func testInsertDeduplicatesAndIncrementsCopyCount() throws {
        let db = try DatabaseManager.inMemory()

        let first = ClipboardEntry(
            id: UUID(uuidString: "3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F")!,
            content: "hello world",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let second = ClipboardEntry(
            id: UUID(uuidString: "A2A4B86B-2FBD-4BE7-8D0B-2B53E64B1E1C")!,
            content: "hello world",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 2)
        )

        try db.insert(first)
        try db.insert(second)

        let all = try db.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, first.id)
        XCTAssertEqual(all.first?.copyCount, 2)
        XCTAssertEqual(all.first?.timestamp, second.timestamp)
    }

    func testDeleteRecentDeletesNewerThanCutoffAndReturnsImagePaths() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)

        let old = ClipboardEntry(
            content: "old",
            contentType: .text,
            timestamp: now.addingTimeInterval(-600)
        )
        let recentNoImage = ClipboardEntry(
            content: "recent",
            contentType: .text,
            timestamp: now.addingTimeInterval(-60)
        )
        let recentWithImage = ClipboardEntry(
            content: "recentImage",
            contentType: .image,
            imagePath: "/tmp/fake.png",
            timestamp: now.addingTimeInterval(-30)
        )

        try db.insert(old)
        try db.insert(recentNoImage)
        try db.insert(recentWithImage)

        let result = try db.deleteRecent(minutes: 5, now: now)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.imagePaths), Set(["/tmp/fake.png"]))

        let remaining = try db.fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.content, "old")
    }

    func testDeleteAllDeletesEverythingAndReturnsImagePaths() throws {
        let db = try DatabaseManager.inMemory()

        try db.insert(ClipboardEntry(content: "a", contentType: .text))
        try db.insert(ClipboardEntry(content: "b", contentType: .image, imagePath: "/tmp/b.png"))
        try db.insert(ClipboardEntry(content: "c", contentType: .image, imagePath: "/tmp/c.png"))

        let result = try db.deleteAll()

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.imagePaths), Set(["/tmp/b.png", "/tmp/c.png"]))
        XCTAssertEqual(try db.fetchAll().count, 0)
    }

    func testFetchPrimaryEntriesExcludesExtractedChildren() throws {
        let db = try DatabaseManager.inMemory()
        let parentA = ClipboardEntry(content: "parent-a", contentType: .text)
        let parentB = ClipboardEntry(content: "parent-b", contentType: .text)
        let child = ClipboardEntry(
            content: "child",
            contentType: .email,
            parentEntryId: parentA.id
        )

        try db.insert(parentA, deduplicate: false)
        try db.insert(parentB, deduplicate: false)
        try db.insert(child, deduplicate: false)

        let primaryEntries = try db.fetchPrimaryEntries()
        XCTAssertEqual(Set(primaryEntries.map(\.id)), Set([parentA.id, parentB.id]))
    }

    func testApplyReclassificationUpdatesParentsAndRebuildsExtractedEntries() throws {
        let db = try DatabaseManager.inMemory()
        let parent = ClipboardEntry(content: "Contact me at test@example.com", contentType: .text, metadata: "{\"legacy\":true}")
        let staleExtracted = ClipboardEntry(content: "old@example.com", contentType: .email, parentEntryId: parent.id)

        try db.insert(parent, deduplicate: false)
        try db.insert(staleExtracted, deduplicate: false)

        let updates = [
            DatabaseManager.ReclassificationUpdate(
                entryID: parent.id,
                contentType: .prose,
                metadata: "{\"emails\":[{\"email\":\"test@example.com\"}]}"
            )
        ]

        let rebuiltExtracted = [
            ClipboardEntry(content: "test@example.com", contentType: .email, parentEntryId: parent.id),
            ClipboardEntry(content: "https://example.com", contentType: .url, parentEntryId: parent.id)
        ]

        let result = try db.applyReclassification(updates: updates, extractedEntries: rebuiltExtracted)
        XCTAssertEqual(result.updatedEntries, 1)
        XCTAssertEqual(result.removedExtractedEntries, 1)
        XCTAssertEqual(result.insertedExtractedEntries, 2)

        let updatedParent = try db.fetch(id: parent.id)
        XCTAssertEqual(updatedParent?.contentType, .prose)
        XCTAssertEqual(updatedParent?.metadata, "{\"emails\":[{\"email\":\"test@example.com\"}]}")

        let extractedAfter = try db.fetchExtractedEntries(parentId: parent.id)
        XCTAssertEqual(Set(extractedAfter.map(\.contentType)), Set([.email, .url]))
        XCTAssertEqual(Set(extractedAfter.map(\.content)), Set(["test@example.com", "https://example.com"]))
    }

    // MARK: - Batch insert

    func testInsertBatchImportsRowsAndSkipsDuplicates() throws {
        let db = try DatabaseManager.inMemory()

        // 3000 unique rows, with every 10th row repeated later in the batch.
        var entries: [ClipboardEntry] = []
        for index in 0..<3_000 {
            entries.append(ClipboardEntry(
                content: "entry \(index)",
                contentType: .text,
                timestamp: Date(timeIntervalSince1970: Double(index))
            ))
            if index % 10 == 0 {
                entries.append(ClipboardEntry(
                    content: "entry \(index)",
                    contentType: .text,
                    timestamp: Date(timeIntervalSince1970: Double(index) + 0.5)
                ))
            }
        }
        XCTAssertEqual(entries.count, 3_300)

        let result = try db.insertBatch(entries)
        XCTAssertEqual(result.inserted, 3_000)
        XCTAssertEqual(result.skipped, 300)
        XCTAssertEqual(try db.countEntries(), 3_000)

        // Re-importing the same source is a complete no-op.
        let rerun = try db.insertBatch(entries)
        XCTAssertEqual(rerun.inserted, 0)
        XCTAssertEqual(rerun.skipped, 3_300)
        XCTAssertEqual(try db.countEntries(), 3_000)

        // Unlike insert(_:deduplicate:), a skipped duplicate must not bump the
        // existing row — importers only ever add history they don't have.
        let existing = try db.search(query: "entry 0")
        XCTAssertEqual(existing.first?.copyCount, 1)
    }

    func testInsertBatchWithoutDeduplicationInsertsEveryRow() throws {
        let db = try DatabaseManager.inMemory()

        let entries = (0..<10).map { _ in
            ClipboardEntry(content: "same", contentType: .text)
        }

        let result = try db.insertBatch(entries, deduplicate: false)
        XCTAssertEqual(result.inserted, 10)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(try db.countEntries(), 10)
    }

    func testInsertBatchIsSearchableViaFTS() throws {
        let db = try DatabaseManager.inMemory()

        try db.insertBatch([
            ClipboardEntry(content: "batched needle content", contentType: .text)
        ])

        XCTAssertEqual(try db.searchFTS(query: "needle", contentType: nil).count, 1)
    }

    // MARK: - Bulk delete

    func testDeleteIDsRemovesRowsAndReturnsImagePaths() throws {
        let db = try DatabaseManager.inMemory()

        var entries: [ClipboardEntry] = []
        for index in 0..<1_200 {
            entries.append(ClipboardEntry(
                content: "bulk \(index)",
                contentType: index % 3 == 0 ? .image : .text,
                imagePath: index % 3 == 0 ? "/tmp/bulk-\(index).png" : nil,
                timestamp: Date(timeIntervalSince1970: Double(index))
            ))
        }
        try db.insertBatch(entries, deduplicate: false)

        // Spans more than one 500-ID chunk.
        let doomed = Array(entries.prefix(700))
        let result = try db.delete(ids: doomed.map(\.id))

        XCTAssertEqual(result.count, 700)
        XCTAssertEqual(Set(result.imagePaths), Set(doomed.compactMap(\.imagePath)))
        XCTAssertEqual(try db.countEntries(), 500)
        XCTAssertNil(try db.fetch(id: doomed[0].id))
        XCTAssertNotNil(try db.fetch(id: entries[700].id))
    }

    func testDeleteIDsDeletesPinnedEntriesLikeSingleDelete() throws {
        let db = try DatabaseManager.inMemory()

        let pinned = ClipboardEntry(content: "pinned", contentType: .text)
        let plain = ClipboardEntry(content: "plain", contentType: .text)
        try db.insert(pinned, deduplicate: false)
        try db.insert(plain, deduplicate: false)
        XCTAssertTrue(try db.setPinned(id: pinned.id, pinned: true))

        let result = try db.delete(ids: [pinned.id, plain.id])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(try db.countEntries(), 0)
    }

    func testDeleteIDsIgnoresEmptyInput() throws {
        let db = try DatabaseManager.inMemory()
        try db.insert(ClipboardEntry(content: "keep", contentType: .text))

        let result = try db.delete(ids: [])
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.imagePaths.isEmpty)
        XCTAssertEqual(try db.countEntries(), 1)
    }

    // MARK: - Sync

    func testFetchUnsyncedAndMarkSyncedRoundTrip() throws {
        let db = try DatabaseManager.inMemory()

        let entries = (0..<5).map { index in
            ClipboardEntry(
                content: "sync \(index)",
                contentType: .text,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        try db.insertBatch(entries, deduplicate: false)

        // Everything starts unsynced, newest first.
        XCTAssertEqual(try db.unsyncedCount(), 5)
        XCTAssertEqual(try db.fetchUnsynced().map(\.content), ["sync 4", "sync 3", "sync 2", "sync 1", "sync 0"])
        XCTAssertEqual(try db.fetchUnsynced(limit: 2).map(\.content), ["sync 4", "sync 3"])

        try db.markSynced(ids: [entries[3].id, entries[4].id])

        XCTAssertEqual(try db.syncedCount(), 2)
        XCTAssertEqual(try db.unsyncedCount(), 3)
        XCTAssertEqual(try db.fetchUnsynced().map(\.content), ["sync 2", "sync 1", "sync 0"])

        try db.markSynced(ids: entries.map(\.id))
        XCTAssertTrue(try db.fetchUnsynced().isEmpty)
    }

    // MARK: - FTS triggers

    func testFTSSurvivesMetadataOnlyUpdatesAndTracksContentChanges() throws {
        let db = try DatabaseManager.inMemory()

        let entry = ClipboardEntry(content: "quarterly aardvark report", contentType: .text)
        try db.insert(entry, deduplicate: false)
        XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).count, 1)

        // Metadata-only updates no longer fire the FTS trigger — the index must
        // still be intact afterwards.
        XCTAssertTrue(try db.setPinned(id: entry.id, pinned: true))
        try db.markSynced(ids: [entry.id])
        try db.insert(
            ClipboardEntry(content: "quarterly aardvark report", contentType: .text),
            deduplicate: true
        ) // dedup path: bumps copyCount + timestamp

        XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).count, 1)
        XCTAssertEqual(try db.fetch(id: entry.id)?.copyCount, 2)

        // An actual content update still reindexes.
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

    // MARK: - Retention

    func testPruneToMaxEntriesShortCircuitsWhenUnderCap() throws {
        let db = try DatabaseManager.inMemory()

        for index in 0..<10 {
            try db.insert(ClipboardEntry(
                content: "retain \(index)",
                contentType: .text,
                timestamp: Date(timeIntervalSince1970: Double(index))
            ))
        }

        let underCap = try db.pruneToMaxEntries(50)
        XCTAssertFalse(underCap.didPrune)
        XCTAssertEqual(underCap.deletedCount, 0)
        XCTAssertTrue(underCap.imagePaths.isEmpty)
        XCTAssertEqual(try db.countEntries(), 10)

        // Exactly at the cap is still a no-op.
        let atCap = try db.pruneToMaxEntries(10)
        XCTAssertFalse(atCap.didPrune)
        XCTAssertEqual(try db.countEntries(), 10)
    }

    func testPruneToMaxEntriesDropsOldestAndKeepsPinned() throws {
        let db = try DatabaseManager.inMemory()

        for index in 0..<10 {
            try db.insert(ClipboardEntry(
                content: "prune \(index)",
                contentType: index == 0 ? .image : .text,
                imagePath: index == 0 ? "/tmp/prune-0.png" : nil,
                timestamp: Date(timeIntervalSince1970: Double(index))
            ))
        }

        let oldestPinned = try XCTUnwrap(try db.fetchAll().last)
        XCTAssertTrue(try db.setPinned(id: oldestPinned.id, pinned: true))

        let result = try db.pruneToMaxEntries(4)
        XCTAssertTrue(result.didPrune)
        // 9 unpinned rows, keep the newest 4.
        XCTAssertEqual(result.deletedCount, 5)
        XCTAssertEqual(try db.countEntries(), 5)

        let remaining = try db.fetchAll()
        XCTAssertTrue(remaining.contains { $0.id == oldestPinned.id })
    }

    func testPruneOlderThanReportsWhetherAnythingWasDeleted() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date(timeIntervalSince1970: 10_000_000)

        try db.insert(ClipboardEntry(
            content: "fresh",
            contentType: .text,
            timestamp: now.addingTimeInterval(-3_600)
        ))

        let nothingToDo = try db.pruneOlderThan(days: 30, now: now)
        XCTAssertFalse(nothingToDo.didPrune)
        XCTAssertEqual(try db.countEntries(), 1)

        try db.insert(ClipboardEntry(
            content: "ancient",
            contentType: .image,
            imagePath: "/tmp/ancient.png",
            timestamp: now.addingTimeInterval(-100 * 24 * 60 * 60)
        ))

        let pruned = try db.pruneOlderThan(days: 30, now: now)
        XCTAssertTrue(pruned.didPrune)
        XCTAssertEqual(pruned.deletedCount, 1)
        XCTAssertEqual(pruned.imagePaths, ["/tmp/ancient.png"])
        XCTAssertEqual(try db.countEntries(), 1)
    }
}
