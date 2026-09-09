import Foundation
import GRDB

extension DatabaseManager {
    /// A consistent, content-free snapshot for comparing device/cloud membership.
    public func syncDiagnosticSnapshot() throws -> SyncLocalSnapshot {
        try dbWriter.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM clipboard_entries")
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_entries WHERE isSynced = 0 AND cloudSyncAllowed = 1 AND contentType != 'filePath'") ?? 0
            let hasCheckpoint = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_checkpoints WHERE name = 'cloudkit')") ?? false
            return SyncLocalSnapshot(recordIDs: Set(ids.map { $0.uppercased() }), pendingCount: pending, hasCheckpoint: hasCheckpoint)
        }
    }

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
                     metadata, contentHash, parentEntryId, isPinned, contentTypeMask, receivedViaTailnet, isSynced)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 1)
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
                        receivedViaTailnet = MAX(clipboard_entries.receivedViaTailnet, excluded.receivedViaTailnet),
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
                        entry.receivedViaTailnet,
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
    /// A partial return (including failed asset staging) also throws while any
    /// durable row remains pending, so callers cannot pull older cloud payloads
    /// over local changes that have not reached the server.
    @discardableResult
    public func backfillUnsynced(using uploader: UnsyncedEntryUploader) async throws -> Int {
        let pending = try fetchUnsynced()
        guard !pending.isEmpty else { return 0 }

        let uploaded = try await uploader(pending) { [self] ids in
            try? markSynced(ids: ids)
        }
        try Task.checkCancellation()
        let remaining = try unsyncedCount()
        guard remaining == 0 else { throw PendingSyncUploadsError(count: remaining) }
        return uploaded
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
                .filter(Column("isSynced") == false && Column("cloudSyncAllowed") == true && Column("contentType") != "filePath")
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
                sql: "SELECT COUNT(*) FROM \(ClipboardEntry.databaseTableName) WHERE isSynced = 0 AND cloudSyncAllowed = 1 AND contentType != 'filePath'"
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

public struct SyncLocalSnapshot: Sendable {
    public let recordIDs: Set<String>
    public let pendingCount: Int
    public let hasCheckpoint: Bool
}

/// Safe, content-free guidance shared by macOS and iOS sync orchestration.
public struct PendingSyncUploadsError: LocalizedError, Equatable, Sendable {
    public let count: Int

    public init(count: Int) { self.count = count }

    public var errorDescription: String? {
        let records = count == 1 ? "record is" : "records are"
        return "\(count) local \(records) still waiting to upload. Downloads are paused to preserve your history. Open Sync Diagnostics, then retry sync."
    }
}
