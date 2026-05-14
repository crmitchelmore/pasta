import Foundation
import GRDB

extension DatabaseManager {
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

    /// Deletes entries older than the newest `maxEntries` and returns any associated image paths.
    /// Pinned entries are never pruned and do not count against the cap.
    public func pruneToMaxEntries(_ maxEntries: Int) throws -> [String] {
        guard maxEntries > 0 else { return [] }

        return try dbQueue.write { db in
            let imagePaths = try String.fetchAll(
                db,
                sql: """
                SELECT imagePath
                FROM \(ClipboardEntry.databaseTableName)
                WHERE rowid IN (
                    SELECT rowid
                    FROM \(ClipboardEntry.databaseTableName)
                    WHERE isPinned = 0
                    ORDER BY timestamp DESC
                    LIMIT -1 OFFSET ?
                ) AND imagePath IS NOT NULL
                """,
                arguments: [maxEntries]
            )

            try db.execute(
                sql: """
                DELETE FROM \(ClipboardEntry.databaseTableName)
                WHERE rowid IN (
                    SELECT rowid
                    FROM \(ClipboardEntry.databaseTableName)
                    WHERE isPinned = 0
                    ORDER BY timestamp DESC
                    LIMIT -1 OFFSET ?
                )
                """,
                arguments: [maxEntries]
            )

            return imagePaths
        }
    }

    /// Deletes entries older than the specified number of days and returns any associated image paths.
    /// Pinned entries are preserved.
    public func pruneOlderThan(days: Int, now: Date = Date()) throws -> [String] {
        guard days > 0 else { return [] }

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

            return imagePaths
        }
    }
}
