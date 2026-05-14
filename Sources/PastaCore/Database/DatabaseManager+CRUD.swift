import Foundation
import GRDB

extension DatabaseManager {
    public func insert(_ entry: ClipboardEntry) throws {
        try insert(entry, deduplicate: true)
    }

    /// Inserts an entry, optionally deduplicating by content hash.
    public func insert(_ entry: ClipboardEntry, deduplicate: Bool) throws {
        let contentHash = entry.contentHash

        do {
            try dbQueue.write { db in
                if deduplicate {
                    if let existingID: String = try String.fetchOne(
                        db,
                        sql: "SELECT id FROM \(ClipboardEntry.databaseTableName) WHERE contentHash = ? LIMIT 1",
                        arguments: [contentHash]
                    ) {
                        try db.execute(
                            sql: """
                            UPDATE \(ClipboardEntry.databaseTableName)
                            SET copyCount = copyCount + 1, timestamp = ?
                            WHERE id = ?
                            """,
                            arguments: [entry.timestamp, existingID]
                        )
                        PastaLogger.database.debug("Updated duplicate entry with hash \(contentHash)")
                        return
                    }
                }

                try db.execute(
                    sql: """
                    INSERT INTO \(ClipboardEntry.databaseTableName)
                    (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash, parentEntryId, isPinned)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        contentHash,
                        entry.parentEntryId?.uuidString,
                        entry.isPinned,
                    ]
                )
                PastaLogger.database.debug("Inserted new entry with type \(entry.contentType.rawValue)")
            }
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert entry")
            throw error
        }
    }

    public func fetchRecent(limit: Int = 50) throws -> [ClipboardEntry] {
        try fetchRecent(contentType: nil, limit: limit)
    }

    public func fetchRecent(contentType: ContentType?, limit: Int = 50) throws -> [ClipboardEntry] {
        try dbQueue.read { db in
            var request = ClipboardEntry
                .order(Column("timestamp").desc)

            if let contentType {
                request = request.filter(Column("contentType") == contentType.rawValue)
            }

            return try request
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchAll() throws -> [ClipboardEntry] {
        try dbQueue.read { db in
            try ClipboardEntry
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    /// Fetches only primary entries (excluding extracted child entries).
    public func fetchPrimaryEntries() throws -> [ClipboardEntry] {
        try dbQueue.read { db in
            try ClipboardEntry
                .filter(Column("parentEntryId") == nil)
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    public func fetch(id: UUID) throws -> ClipboardEntry? {
        try dbQueue.read { db in
            try ClipboardEntry
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)
        }
    }

    /// Fetches an entry by its ID.
    public func fetchEntry(id: UUID) throws -> ClipboardEntry? {
        try fetch(id: id)
    }

    /// Fetches all extracted entries for a given parent entry.
    public func fetchExtractedEntries(parentId: UUID) throws -> [ClipboardEntry] {
        try dbQueue.read { db in
            try ClipboardEntry
                .filter(Column("parentEntryId") == parentId.uuidString)
                .order(Column("contentType"))
                .fetchAll(db)
        }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE id = ?",
                arguments: [id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Efficiently checks if an entry with the given content hash exists.
    public func existsWithHash(_ hash: String) throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM \(ClipboardEntry.databaseTableName) WHERE contentHash = ? LIMIT 1",
                arguments: [hash]
            )
            return count != nil
        }
    }
}
