import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class SyncApplyTests: XCTestCase {
    func testRemoteChangesMergeByRecordIdentity() async throws {
        let db = try DatabaseManager.inMemory()

        // Identity, not content, decides the row; replays never bump copyCount
        // and never import the remote pin.
        let local = ClipboardEntry(content: "shared content", contentType: .text, timestamp: Date(timeIntervalSince1970: 500), copyCount: 9)
        let remote = ClipboardEntry(content: local.content, contentType: .text, timestamp: Date(timeIntervalSince1970: 1_000), copyCount: 4, isPinned: true)
        try db.insert(local)
        try db.applySyncChanges(modified: [remote, remote], deleted: [])
        try db.applySyncChanges(modified: [remote], deleted: [])
        var expectedRemote = remote
        expectedRemote.isSynced = true
        expectedRemote.isPinned = false
        XCTAssertEqual(try db.fetch(id: remote.id), expectedRemote)
        XCTAssertEqual(try db.fetch(id: local.id), local)
        XCTAssertEqual(try db.fetchUnsynced().map(\.id), [local.id])
        try db.markSynced(ids: [local.id])

        // Same id replaces content, metadata and assets but keeps the local pin.
        let pinned = ClipboardEntry(
            content: "old content", contentType: .text, rawData: Data([1, 2]),
            timestamp: Date(timeIntervalSince1970: 1_000), copyCount: 8, sourceApp: "old app",
            metadata: #"{"emails":[{"email":"old@example.com"}]}"#, isPinned: true
        )
        try db.insert(pinned)
        XCTAssertEqual(try db.fetch(id: pinned.id)?.contentTypeMask, .email)
        let replacement = ClipboardEntry(
            id: pinned.id, content: "updated image caption", contentType: .screenshot, rawData: Data([3, 4, 5]),
            imagePath: "/remote/cache/new-image.png", timestamp: Date(timeIntervalSince1970: 2_000), copyCount: 3,
            sourceApp: "remote app", metadata: #"{"urls":[{"url":"https://example.com"}]}"#, parentEntryId: UUID()
        )
        try db.applySyncChanges(modified: [replacement], deleted: [])
        var expected = replacement
        expected.isPinned = true
        expected.isSynced = true
        expected.copyCount = 8
        XCTAssertEqual(try db.fetch(id: pinned.id), expected)
        XCTAssertEqual(try db.fetch(id: pinned.id)?.contentTypeMask, .url)
        XCTAssertTrue(try db.existsWithHash(replacement.contentHash))
        XCTAssertFalse(try db.existsWithHash(pinned.contentHash))
        XCTAssertEqual(try db.unsyncedCount(), 0)

        // Nil remote fields clear the previous remote payload.
        let cleared = ClipboardEntry(id: pinned.id, content: "now plain text", contentType: .text, timestamp: Date(timeIntervalSince1970: 3_000))
        try db.applySyncChanges(modified: [cleared], deleted: [])
        var expectedCleared = cleared
        expectedCleared.isPinned = true
        expectedCleared.isSynced = true
        expectedCleared.copyCount = 8
        XCTAssertEqual(try db.fetch(id: pinned.id), expectedCleared)
        XCTAssertEqual(try db.fetch(id: pinned.id)?.contentTypeMask, [])

        // A full-zone replay must not erase copies made since the push: the
        // larger copyCount and newer timestamp win from either side.
        var stale = expectedCleared
        stale.timestamp = Date(timeIntervalSince1970: 1_000)
        stale.copyCount = 2
        try db.applySyncChanges(modified: [stale], deleted: [])
        var replayed = try XCTUnwrap(db.fetch(id: pinned.id))
        XCTAssertEqual(replayed.copyCount, 8)
        XCTAssertEqual(replayed.timestamp, Date(timeIntervalSince1970: 3_000))
        var fresher = expectedCleared
        fresher.timestamp = Date(timeIntervalSince1970: 9_000)
        fresher.copyCount = 11
        try db.applySyncChanges(modified: [fresher], deleted: [])
        replayed = try XCTUnwrap(db.fetch(id: pinned.id))
        XCTAssertEqual(replayed.copyCount, 11)
        XCTAssertEqual(replayed.timestamp, Date(timeIntervalSince1970: 9_000))

        // FTS follows remote updates and deletions.
        let searchable = ClipboardEntry(content: "aardvark report", contentType: .text)
        try db.applySyncChanges(modified: [searchable], deleted: [])
        XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).map(\.id), [searchable.id])
        try db.applySyncChanges(modified: [ClipboardEntry(id: searchable.id, content: "pangolin report", contentType: .text)], deleted: [])
        XCTAssertTrue(try db.searchFTS(query: "aardvark", contentType: nil).isEmpty)
        XCTAssertEqual(try db.searchFTS(query: "pangolin", contentType: nil).map(\.id), [searchable.id])

        // Deletion wins over a modification in the same batch, idempotently.
        let doomed = ClipboardEntry(content: "delete pinned remote", contentType: .text, isPinned: true)
        let absent = ClipboardEntry(content: "never inserted", contentType: .text)
        try db.insertBatch([doomed])
        let before = try db.countEntries()
        for _ in 0..<2 {
            try db.applySyncChanges(modified: [doomed, absent], deleted: [doomed.id, absent.id, searchable.id, UUID()])
        }
        XCTAssertNil(try db.fetch(id: doomed.id))
        XCTAssertNil(try db.fetch(id: absent.id))
        XCTAssertTrue(try db.searchFTS(query: "pangolin", contentType: nil).isEmpty)
        XCTAssertEqual(try db.countEntries(), before - 2)
        XCTAssertEqual(try db.fetch(id: local.id)?.content, local.content)

        let uploaded = try await db.backfillUnsynced { _, _ in
            XCTFail("Applying or replaying a remote row must not queue another upload")
            return 0
        }
        XCTAssertEqual(uploaded, 0)
    }

    func testCachedImagePathSurvivesOnlyForMatchingImageBytes() throws {
        let bytes = Data([1, 2, 3, 4])
        let hash = ClipboardEntry.sha256Hex(bytes)
        let oldBytes = Data([1, 2, 3])
        // The path names the hash the local row would match on.
        let cases: [(name: String, localRaw: Data?, pathHash: String, remoteType: ContentType, remoteRaw: Data?, keepsPath: Bool)] = [
            ("image with matching bytes", nil, hash, .image, bytes, true),
            ("screenshot with matching bytes", nil, hash, .screenshot, bytes, true),
            ("changed bytes", oldBytes, ClipboardEntry.sha256Hex(oldBytes), .image, Data([9, 8, 7]), false),
            ("unverifiable bytes", oldBytes, ClipboardEntry.sha256Hex(oldBytes), .image, nil, false),
            ("became text despite matching hash", nil, ClipboardEntry.sha256Hex("caption"), .text, nil, false),
        ]
        for c in cases {
            let db = try DatabaseManager.inMemory()
            let local = ClipboardEntry(content: "caption", contentType: .image, rawData: c.localRaw, imagePath: "/local/images/\(c.pathHash).png")
            try db.insert(local)
            let remote = ClipboardEntry(id: local.id, content: c.keepsPath ? "updated caption" : "caption", contentType: c.remoteType, rawData: c.remoteRaw)
            try db.applySyncChanges(modified: [remote], deleted: [])
            try db.applySyncChanges(modified: [remote], deleted: [])

            let stored = try XCTUnwrap(try db.fetch(id: local.id))
            XCTAssertEqual(stored.imagePath, c.keepsPath ? local.imagePath : nil, c.name)
            XCTAssertEqual(stored.rawData, c.remoteRaw, c.name)
            XCTAssertEqual(stored.content, remote.content, c.name)
            XCTAssertEqual(stored.contentHash, remote.contentHash, c.name)
            if let localRaw = c.localRaw {
                XCTAssertFalse(try db.existsWithHash(ClipboardEntry.sha256Hex(localRaw)), c.name)
            }
        }
    }

    func testFailuresRollBackTheWholeApply() throws {
        for onDisk in [false, true] {
            let db = try makeDatabase(onDisk: onDisk)
            let original = ClipboardEntry(content: "aardvark original", contentType: .text, timestamp: Date(timeIntervalSince1970: 1_000), isPinned: true)
            let doomed = (0...DatabaseManager.batchChunkSize).map { ClipboardEntry(content: "deletion \($0)", contentType: .text) }
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

            try db.dbWriter.write { try $0.execute(sql: "DROP TRIGGER reject_sync_delete") }
            try db.applySyncChanges(modified: [update, added], deleted: doomed.map(\.id))
            XCTAssertEqual(try db.countEntries(), 2)
            XCTAssertEqual(try db.syncedCount(), 2)
        }

        // A failed checkpoint write rolls back rows, deletions and FTS too.
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
        XCTAssertThrowsError(try db.applySyncChanges(modified: [updated, added], deleted: [deleted.id], checkpoint: Data([2])))
        XCTAssertEqual(try db.loadSyncChangeToken(), Data([1]))
        XCTAssertEqual(try db.fetch(id: original.id)?.content, original.content)
        XCTAssertNotNil(try db.fetch(id: deleted.id))
        XCTAssertNil(try db.fetch(id: added.id))
        XCTAssertEqual(try db.searchFTS(query: "aardvark", contentType: nil).map(\.id), [original.id])
        XCTAssertTrue(try db.searchFTS(query: "pangolin", contentType: nil).isEmpty)

        // An empty batch without a checkpoint is a no-op and never reaches the checkpoint write.
        XCTAssertNoThrow(try db.applySyncChanges(modified: [], deleted: []))
        XCTAssertEqual(try db.loadSyncChangeToken(), Data([1]))
    }

    private func makeDatabase(onDisk: Bool) throws -> DatabaseManager {
        guard onDisk else { return try DatabaseManager.inMemory() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaSyncApplyTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try DatabaseManager(databaseURL: directory.appendingPathComponent("pasta.sqlite"))
    }
}
