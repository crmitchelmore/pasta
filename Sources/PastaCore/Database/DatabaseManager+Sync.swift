import Foundation
import GRDB

extension DatabaseManager {
    /// Atomically applies downloaded changes by record identity, without the
    /// content-hash deduplication or copy-count increment used for local copies.
    /// Replaying a batch is safe, and deletion wins for IDs present in both lists.
    ///
    /// Pins belong to this device: existing pins survive updates and new remote
    /// rows start unpinned. When the remote entry has no image path, a cached
    /// local path survives only if both versions are images/screenshots and their
    /// content hashes match. Missing image bytes cannot prove that match, so an
    /// incompatible or unverifiable cache is cleared instead of showing stale
    /// pixels. Raw data and all other remote fields replace their local values,
    /// except `timestamp` and `copyCount`, which keep the larger of local and
    /// remote: a remote record carries the pushing device's count and time, and
    /// a replay (notably the full re-download after the checkpoint moved into
    /// the database) must not snap this device's own copies back to their
    /// at-push values.
    /// A supplied checkpoint commits in the same transaction, including for
    /// empty batches. A nil checkpoint leaves the previous cursor unchanged.
    public func applySyncChanges(modified: [ClipboardEntry], deleted: [UUID], checkpoint: Data? = nil) throws {
        guard !modified.isEmpty || !deleted.isEmpty || checkpoint != nil else { return }
        let deletedIDs = Set(deleted)

        try dbWriter.write { db in
            for entry in modified where !deletedIDs.contains(entry.id) {
                try db.execute(
                    sql: """
                    INSERT INTO \(ClipboardEntry.databaseTableName)
                    (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp,
                     metadata, contentHash, parentEntryId, isPinned, contentTypeMask, isSynced)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 1)
                    ON CONFLICT(id) DO UPDATE SET
                        content = excluded.content,
                        contentType = excluded.contentType,
                        rawData = excluded.rawData,
                        imagePath = CASE
                            WHEN excluded.imagePath IS NOT NULL THEN excluded.imagePath
                            WHEN clipboard_entries.contentType IN ('image', 'screenshot')
                                AND excluded.contentType IN ('image', 'screenshot')
                                AND excluded.rawData IS NOT NULL
                                AND clipboard_entries.contentHash = excluded.contentHash
                            THEN clipboard_entries.imagePath
                            ELSE NULL
                        END,
                        timestamp = MAX(clipboard_entries.timestamp, excluded.timestamp),
                        copyCount = MAX(clipboard_entries.copyCount, excluded.copyCount),
                        sourceApp = excluded.sourceApp,
                        metadata = excluded.metadata,
                        contentHash = excluded.contentHash,
                        parentEntryId = excluded.parentEntryId,
                        contentTypeMask = excluded.contentTypeMask,
                        isSynced = 1
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.content,
                        entry.contentType.rawValue,
                        entry.rawData,
                        entry.imagePath,
                        entry.timestamp,
                        entry.copyCount,
                        entry.sourceApp,
                        entry.metadata,
                        entry.contentHash,
                        entry.parentEntryId?.uuidString,
                        entry.contentTypeMask,
                    ]
                )
            }

            // Chunk only the bound ID lists; every chunk remains inside the
            // same transaction as the upserts, including their FTS triggers.
            for start in stride(from: 0, to: deleted.count, by: Self.batchChunkSize) {
                let chunk = deleted[start..<min(start + Self.batchChunkSize, deleted.count)]
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk.map { $0.uuidString })
                )
            }

            if let checkpoint {
                try db.execute(
                    sql: """
                    INSERT INTO sync_checkpoints (name, token) VALUES ('cloudkit', ?)
                    ON CONFLICT(name) DO UPDATE SET token = excluded.token
                    """,
                    arguments: [checkpoint]
                )
            }
        }
    }

    public func loadSyncChangeToken() throws -> Data? {
        try dbWriter.read { db in
            try Data.fetchOne(db, sql: "SELECT token FROM sync_checkpoints WHERE name = 'cloudkit'")
        }
    }

    public func resetSyncChangeToken() throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM sync_checkpoints WHERE name = 'cloudkit'")
        }
    }

    public typealias UnsyncedEntryUploader = @Sendable (
        _ entries: [ClipboardEntry],
        _ onBatchSynced: @escaping @Sendable ([UUID]) -> Void
    ) async throws -> Int

    /// Uploads all locally pending entries and marks each confirmed batch synced.
    ///
    /// The uploader controls batching and calls `onBatchSynced` only after a
    /// batch is durably stored remotely. If a later batch fails, earlier batches
    /// remain marked while the rest stay pending for the next retry.
    @discardableResult
    public func backfillUnsynced(using uploader: UnsyncedEntryUploader) async throws -> Int {
        let pending = try fetchUnsynced()
        guard !pending.isEmpty else { return 0 }

        return try await uploader(pending) { [self] ids in
            try? markSynced(ids: ids)
        }
    }

    /// Marks entries as synced to iCloud.
    public func markSynced(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try dbWriter.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "UPDATE \(ClipboardEntry.databaseTableName) SET isSynced = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids.map { $0.uuidString })
            )
        }
    }

    /// Fetches entries that have not yet been pushed to iCloud, newest first.
    ///
    /// Backed by `idx_clipboard_entries_unsynced`, a partial index over the
    /// `isSynced = 0` rows — which shrinks to (almost) nothing once a library
    /// is fully synced, so "Sync Now" costs a keyscan rather than a full push.
    public func fetchUnsynced(limit: Int? = nil) throws -> [ClipboardEntry] {
        try dbWriter.read { db in
            var request = ClipboardEntry
                .filter(Column("isSynced") == false)
                .order(Column("timestamp").desc)

            if let limit {
                request = request.limit(limit)
            }

            return try request.fetchAll(db)
        }
    }

    /// Returns the count of entries still awaiting an iCloud push.
    public func unsyncedCount() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(ClipboardEntry.databaseTableName) WHERE isSynced = 0"
            ) ?? 0
        }
    }

    /// Returns the count of synced entries.
    public func syncedCount() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(ClipboardEntry.databaseTableName) WHERE isSynced = 1"
            ) ?? 0
        }
    }
}
