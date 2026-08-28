import Foundation
import GRDB

extension DatabaseManager {
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
