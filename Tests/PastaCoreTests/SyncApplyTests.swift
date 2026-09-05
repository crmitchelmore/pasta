import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class SyncApplyTests: XCTestCase {
    func testInsertAndReplayUseRecordIdentityWithoutIncrementingCopyCount() throws {
        let db = try DatabaseManager.inMemory()
        let local = ClipboardEntry(
            content: "shared content", contentType: .text,
            timestamp: Date(timeIntervalSince1970: 500), copyCount: 9
        )
        let remote = ClipboardEntry(
            content: local.content,
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1_000),
            copyCount: 4,
            isPinned: true
        )
        try db.insert(local)

        try db.applySyncChanges(modified: [remote, remote], deleted: [])
        try db.applySyncChanges(modified: [remote], deleted: [])

        var expected = remote
        expected.isSynced = true
        expected.isPinned = false
        XCTAssertEqual(try db.fetch(id: remote.id), expected)
        XCTAssertEqual(try db.fetch(id: local.id), local)
        XCTAssertEqual(try db.countEntries(), 2)
        XCTAssertEqual(try db.fetchUnsynced().map(\.id), [local.id])
    }

    func testSameIDReplacesContentMetadataAndAssetsWhilePreservingLocalPin() throws {
        let db = try DatabaseManager.inMemory()
        let local = ClipboardEntry(
            content: "old content",
            contentType: .text,
            rawData: Data([1, 2]),
            timestamp: Date(timeIntervalSince1970: 1_000),
            copyCount: 8,
            sourceApp: "old app",
            metadata: #"{"emails":[{"email":"old@example.com"}]}"#,
            isPinned: true
        )
        try db.insert(local)
        XCTAssertEqual(try db.fetch(id: local.id)?.contentTypeMask, .email)
        let remote = ClipboardEntry(
            id: local.id,
            content: "updated image caption",
            contentType: .screenshot,
            rawData: Data([3, 4, 5]),
            imagePath: "/remote/cache/new-image.png",
            timestamp: Date(timeIntervalSince1970: 2_000),
            copyCount: 3,
            sourceApp: "remote app",
            metadata: #"{"urls":[{"url":"https://example.com"}]}"#,
            parentEntryId: UUID()
        )
        XCTAssertEqual(remote.contentTypeMask, .url)

        try db.applySyncChanges(modified: [remote], deleted: [])

        var expected = remote
        expected.isPinned = true
        expected.isSynced = true
        XCTAssertEqual(try db.fetch(id: local.id), expected)
        XCTAssertEqual(try db.fetch(id: local.id)?.contentTypeMask, .url)
        XCTAssertTrue(try db.existsWithHash(remote.contentHash))
        XCTAssertFalse(try db.existsWithHash(local.contentHash))
        XCTAssertEqual(try db.unsyncedCount(), 0)

        // Nil remote fields intentionally clear the previous remote payload.
        let cleared = ClipboardEntry(
            id: local.id,
            content: "now plain text",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 3_000)
        )
        try db.applySyncChanges(modified: [cleared], deleted: [])
        var expectedCleared = cleared
        expectedCleared.isPinned = true
        expectedCleared.isSynced = true
        XCTAssertEqual(try db.fetch(id: local.id), expectedCleared)
        XCTAssertEqual(try db.fetch(id: local.id)?.contentTypeMask, [])
    }

    func testPreservesImagePathOnlyForMatchingImageContent() throws {
        for remoteType in [ContentType.image, .screenshot] {
            let db = try DatabaseManager.inMemory()
            let bytes = Data([1, 2, 3, 4])
            let hash = ClipboardEntry.sha256Hex(bytes)
            let local = ClipboardEntry(
                content: "image",
                contentType: .image,
                imagePath: "/local/images/\(hash).png"
            )
            try db.insert(local)
            let remote = ClipboardEntry(
                id: local.id,
                content: "updated caption",
                contentType: remoteType,
                rawData: bytes
            )

            try db.applySyncChanges(modified: [remote], deleted: [])
            try db.applySyncChanges(modified: [remote], deleted: [])

            let stored = try XCTUnwrap(try db.fetch(id: local.id))
            XCTAssertEqual(stored.imagePath, local.imagePath)
            XCTAssertEqual(stored.rawData, bytes)
            XCTAssertEqual(stored.content, remote.content)
            XCTAssertEqual(stored.contentHash, hash)
        }
    }

    func testClearsCachedImageWhenRemoteBytesChangeOrCannotVerifyContent() throws {
        let remotePayloads: [Data?] = [Data([9, 8, 7]), nil]
        for remoteBytes in remotePayloads {
            let db = try DatabaseManager.inMemory()
            let oldBytes = Data([1, 2, 3])
            let oldHash = ClipboardEntry.sha256Hex(oldBytes)
            let local = ClipboardEntry(
                content: "same caption",
                contentType: .image,
                rawData: oldBytes,
                imagePath: "/local/images/\(oldHash).png"
            )
            try db.insert(local)
            let remote = ClipboardEntry(
                id: local.id,
                content: local.content,
                contentType: .image,
                rawData: remoteBytes
            )

            try db.applySyncChanges(modified: [remote], deleted: [])

            let stored = try XCTUnwrap(try db.fetch(id: local.id))
            XCTAssertNil(stored.imagePath)
            XCTAssertEqual(stored.rawData, remoteBytes)
            XCTAssertEqual(stored.contentHash, remote.contentHash)
            XCTAssertFalse(try db.existsWithHash(oldHash))
        }
    }

    func testClearsImagePathWhenContentBecomesTextEvenWithMatchingHash() throws {
        let db = try DatabaseManager.inMemory()
        let content = "same caption"
        let hash = ClipboardEntry.sha256Hex(content)
        let local = ClipboardEntry(content: content, contentType: .image, imagePath: "/local/\(hash).png")
        try db.insert(local)
        let remote = ClipboardEntry(id: local.id, content: content, contentType: .text)

        try db.applySyncChanges(modified: [remote], deleted: [])

        XCTAssertNil(try db.fetch(id: local.id)?.imagePath)
    }

    func testDeletionWinsAndLeavesUnrelatedLocalRowsUnchanged() throws {
        let db = try DatabaseManager.inMemory()
        let deleted = ClipboardEntry(content: "delete pinned remote", contentType: .text, isPinned: true)
        let local = ClipboardEntry(
            content: "keep local", contentType: .text, timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let pinned = ClipboardEntry(
            content: "keep pinned", contentType: .text,
            timestamp: Date(timeIntervalSince1970: 2_000), isPinned: true
        )
        let absent = ClipboardEntry(content: "never inserted", contentType: .text)
        try db.insertBatch([deleted, local, pinned])

        for _ in 0..<2 {
            try db.applySyncChanges(modified: [deleted, absent], deleted: [deleted.id, absent.id, UUID()])
        }

        XCTAssertNil(try db.fetch(id: deleted.id))
        XCTAssertNil(try db.fetch(id: absent.id))
        XCTAssertEqual(try db.fetch(id: local.id), local)
        XCTAssertEqual(try db.fetch(id: pinned.id), pinned)
        XCTAssertEqual(try db.countEntries(), 2)
    }

    func testFTSSearchTracksRemoteUpdatesAndDeletions() throws {
        let db = try DatabaseManager.inMemory()
        let original = ClipboardEntry(content: "aardvark report", contentType: .text)
        try db.applySyncChanges(modified: [original], deleted: [])
        XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).map(\.id), [original.id])

        let update = ClipboardEntry(id: original.id, content: "pangolin report", contentType: .text)
        try db.applySyncChanges(modified: [update], deleted: [])
        XCTAssertTrue(try db.searchFTS(query: "aardvark", contentType: nil).isEmpty)
        XCTAssertEqual(try db.searchFTS(query: "pangolin", contentType: nil).map(\.id), [original.id])

        try db.applySyncChanges(modified: [], deleted: [original.id])
        XCTAssertTrue(try db.searchFTS(query: "pangolin", contentType: nil).isEmpty)
    }

    func testFailureRollsBackUpsertsDeletesAndFTSAcrossDeletionChunks() throws {
        for onDisk in [false, true] {
            let db = try makeDatabase(onDisk: onDisk)
            let original = ClipboardEntry(
                content: "aardvark original", contentType: .text,
                timestamp: Date(timeIntervalSince1970: 1_000), isPinned: true
            )
            let doomed = (0...DatabaseManager.batchChunkSize).map { index in
                ClipboardEntry(content: "deletion \(index)", contentType: .text)
            }
            try db.insertBatch([original] + doomed)
            let protectedID = try XCTUnwrap(doomed.last?.id)
            try db.dbWriter.write { connection in
                try connection.execute(sql: """
                    CREATE TRIGGER reject_sync_delete BEFORE DELETE ON clipboard_entries
                    WHEN old.id = '\(protectedID.uuidString)'
                    BEGIN SELECT RAISE(ABORT, 'injected sync apply failure'); END;
                    """)
            }
            let update = ClipboardEntry(id: original.id, content: "pangolin replacement", contentType: .text)
            let added = ClipboardEntry(content: "newly inserted", contentType: .text)

            XCTAssertThrowsError(try db.applySyncChanges(modified: [update, added], deleted: doomed.map(\.id)))

            XCTAssertEqual(try db.fetch(id: original.id), original)
            XCTAssertNil(try db.fetch(id: added.id))
            XCTAssertEqual(try db.countEntries(), doomed.count + 1)
            XCTAssertEqual(try db.unsyncedCount(), doomed.count + 1)
            XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).map(\.id), [original.id])
            XCTAssertTrue(try db.searchFTS(query: "pangolin", contentType: nil).isEmpty)
            XCTAssertEqual(try db.searchFTS(query: "deletion", contentType: nil, limit: doomed.count).count, doomed.count)

            try db.dbWriter.write { connection in
                try connection.execute(sql: "DROP TRIGGER reject_sync_delete")
            }
            try db.applySyncChanges(modified: [update, added], deleted: doomed.map(\.id))
            XCTAssertEqual(try db.countEntries(), 2)
            XCTAssertEqual(try db.syncedCount(), 2)
        }
    }

    func testAppliedRemoteEntriesAreNotUploadedByBackfill() async throws {
        let db = try DatabaseManager.inMemory()
        let remote = ClipboardEntry(content: "downloaded", contentType: .text)
        try db.applySyncChanges(modified: [remote], deleted: [])
        try db.applySyncChanges(modified: [remote], deleted: [])

        let uploaded = try await db.backfillUnsynced { _, _ in
            XCTFail("Applying or replaying a remote row must not queue another upload")
            return 0
        }
        XCTAssertEqual(uploaded, 0)
    }

    func testCheckpointWriteFailureRollsBackRowsDeletionsAndFTS() throws {
        let db = try DatabaseManager.inMemory()
        let original = ClipboardEntry(content: "aardvark original", contentType: .text)
        let deleted = ClipboardEntry(content: "keep this deletion", contentType: .text)
        try db.applySyncChanges(modified: [original, deleted], deleted: [], checkpoint: Data([1]))
        try db.dbWriter.write { connection in
            try connection.execute(sql: """
                CREATE TRIGGER reject_checkpoint BEFORE UPDATE ON sync_checkpoints
                BEGIN SELECT RAISE(ABORT, 'injected checkpoint write failure'); END;
                """)
        }
        let updated = ClipboardEntry(id: original.id, content: "pangolin replacement", contentType: .text)
        let added = ClipboardEntry(content: "new entry", contentType: .text)
        XCTAssertThrowsError(try db.applySyncChanges(
            modified: [updated, added], deleted: [deleted.id], checkpoint: Data([2])
        ))
        XCTAssertEqual(try db.loadSyncChangeToken(), Data([1]))
        XCTAssertEqual(try db.fetch(id: original.id)?.content, original.content)
        XCTAssertNotNil(try db.fetch(id: deleted.id))
        XCTAssertNil(try db.fetch(id: added.id))
        XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).map(\.id), [original.id])
        XCTAssertTrue(try db.searchFTS(query: "pangolin", contentType: nil).isEmpty)
    }

    private func makeDatabase(onDisk: Bool) throws -> DatabaseManager {
        guard onDisk else { return try DatabaseManager.inMemory() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaSyncApplyTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try DatabaseManager(databaseURL: directory.appendingPathComponent("pasta.sqlite"))
    }
}
