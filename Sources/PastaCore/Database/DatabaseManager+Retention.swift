import Foundation
import GRDB

extension DatabaseManager {
    /// Outcome of a retention prune: how many rows went away, plus the image
    /// paths that now need deleting from disk. Callers use `deletedCount` to
    /// decide whether a UI reload is warranted — image paths alone can't tell
    /// them apart, since most entries are text and carry no image.
    public struct PruneResult: Sendable {
        public let deletedCount: Int
        public let imagePaths: [String]

        public init(deletedCount: Int, imagePaths: [String]) {
            self.deletedCount = deletedCount
            self.imagePaths = imagePaths
        }

        public var didPrune: Bool { deletedCount > 0 }
    }

    /// Deletes entries newer than (now - minutes) and returns the count deleted and associated image paths.
    public func deleteRecent(minutes: Int, now: Date = Date()) throws -> (count: Int, imagePaths: [String]) {
        let cutoff = now.addingTimeInterval(-Double(minutes) * 60)

        return try dbQueue.write { db in
            let imagePaths = try String.fetchAll(
                db,
                sql: "SELECT imagePath FROM \(ClipboardEntry.databaseTableName) WHERE timestamp > ? AND imagePath IS NOT NULL",
                arguments: [cutoff]
            )

            try db.execute(
                sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE timestamp > ?",
                arguments: [cutoff]
            )

            return (db.changesCount, imagePaths)
        }
    }

    /// Deletes all entries and returns the count deleted and associated image paths.
    ///
    /// - Parameter includePinned: when `false` (the default), pinned entries are
    ///   preserved. Pass `true` from explicit "wipe everything" code paths.
    public func deleteAll(includePinned: Bool = false) throws -> (count: Int, imagePaths: [String]) {
        try dbQueue.write { db in
            let pinClause = includePinned ? "" : " AND isPinned = 0"
            let imagePaths = try String.fetchAll(
                db,
                sql: "SELECT imagePath FROM \(ClipboardEntry.databaseTableName) WHERE imagePath IS NOT NULL\(pinClause)"
            )

            let deleteWhere = includePinned ? "" : " WHERE isPinned = 0"
            try db.execute(sql: "DELETE FROM \(ClipboardEntry.databaseTableName)\(deleteWhere)")

            return (db.changesCount, imagePaths)
        }
    }

    /// Deletes entries older than the newest `maxEntries`.
    /// Pinned entries are never pruned and do not count against the cap.
    ///
    /// This runs after *every* insert when a max-entries cap is configured, so
    /// the common "already under the cap" case must be cheap: a counting read
    /// short-circuits before the write lock is taken, and the victim rows are
    /// resolved by a single `ORDER BY timestamp DESC / OFFSET` scan rather than
    /// evaluating that subquery once for the image paths and again for the
    /// delete.
    public func pruneToMaxEntries(_ maxEntries: Int) throws -> PruneResult {
        guard maxEntries > 0 else { return PruneResult(deletedCount: 0, imagePaths: []) }

        let unpinnedCount = try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(ClipboardEntry.databaseTableName) WHERE isPinned = 0"
            ) ?? 0
        }
        guard unpinnedCount > maxEntries else { return PruneResult(deletedCount: 0, imagePaths: []) }

        return try dbQueue.write { db in
            let victims = try Row.fetchAll(
                db,
                sql: """
                SELECT rowid AS victimRowID, imagePath
                FROM \(ClipboardEntry.databaseTableName)
                WHERE isPinned = 0
                ORDER BY timestamp DESC
                LIMIT -1 OFFSET ?
                """,
                arguments: [maxEntries]
            )
            guard !victims.isEmpty else { return PruneResult(deletedCount: 0, imagePaths: []) }

            let rowIDs: [Int64] = victims.map { $0["victimRowID"] }
            let imagePaths: [String] = victims.compactMap { $0["imagePath"] }

            var deleted = 0
            for start in stride(from: 0, to: rowIDs.count, by: Self.batchChunkSize) {
                let chunk = Array(rowIDs[start..<min(start + Self.batchChunkSize, rowIDs.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE rowid IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                deleted += db.changesCount
            }

            return PruneResult(deletedCount: deleted, imagePaths: imagePaths)
        }
    }

    /// Deletes entries older than the specified number of days.
    /// Pinned entries are preserved.
    public func pruneOlderThan(days: Int, now: Date = Date()) throws -> PruneResult {
        guard days > 0 else { return PruneResult(deletedCount: 0, imagePaths: []) }

        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)

        return try dbQueue.write { db in
            let imagePaths = try String.fetchAll(
                db,
                sql: "SELECT imagePath FROM \(ClipboardEntry.databaseTableName) WHERE timestamp < ? AND isPinned = 0 AND imagePath IS NOT NULL",
                arguments: [cutoff]
            )

            try db.execute(
                sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE timestamp < ? AND isPinned = 0",
                arguments: [cutoff]
            )

            let deleted = db.changesCount
            if deleted > 0 {
                PastaLogger.database.info("Pruned \(deleted) entries older than \(days) days")
            }

            return PruneResult(deletedCount: deleted, imagePaths: imagePaths)
        }
    }
}
