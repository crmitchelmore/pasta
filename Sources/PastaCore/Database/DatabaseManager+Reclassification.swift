import Foundation
import GRDB

extension DatabaseManager {
    public struct ReclassificationUpdate: Sendable {
        public let entryID: UUID
        public let contentType: ContentType
        public let metadata: String?

        public init(entryID: UUID, contentType: ContentType, metadata: String?) {
            self.entryID = entryID
            self.contentType = contentType
            self.metadata = metadata
        }
    }

    public struct ReclassificationResult: Sendable {
        public let updatedEntries: Int
        public let removedExtractedEntries: Int
        public let insertedExtractedEntries: Int

        public init(updatedEntries: Int, removedExtractedEntries: Int, insertedExtractedEntries: Int) {
            self.updatedEntries = updatedEntries
            self.removedExtractedEntries = removedExtractedEntries
            self.insertedExtractedEntries = insertedExtractedEntries
        }
    }

    /// Keyset cursor for paging primary entries newest-first without OFFSET
    /// (stable even while rows are inserted or updated mid-walk).
    public struct PrimaryEntryCursor: Sendable {
        public let timestamp: Date
        public let id: UUID

        public init(timestamp: Date, id: UUID) {
            self.timestamp = timestamp
            self.id = id
        }

        public init(after entry: ClipboardEntry) {
            self.init(timestamp: entry.timestamp, id: entry.id)
        }
    }

    public func countPrimaryEntries() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(ClipboardEntry.databaseTableName) WHERE parentEntryId IS NULL"
            ) ?? 0
        }
    }

    /// Fetches one page of primary entries strictly older than `cursor`
    /// (newest-first, ties broken by id). Pass `nil` for the first page; build
    /// the next cursor from the last returned entry.
    public func fetchPrimaryEntries(after cursor: PrimaryEntryCursor?, limit: Int) throws -> [ClipboardEntry] {
        try dbWriter.read { db in
            if let cursor {
                return try ClipboardEntry.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM \(ClipboardEntry.databaseTableName)
                    WHERE parentEntryId IS NULL
                      AND (timestamp < :ts OR (timestamp = :ts AND id < :id))
                    ORDER BY timestamp DESC, id DESC
                    LIMIT :limit
                    """,
                    arguments: ["ts": cursor.timestamp, "id": cursor.id.uuidString, "limit": limit]
                )
            }
            return try ClipboardEntry.fetchAll(
                db,
                sql: """
                SELECT * FROM \(ClipboardEntry.databaseTableName)
                WHERE parentEntryId IS NULL
                ORDER BY timestamp DESC, id DESC
                LIMIT :limit
                """,
                arguments: ["limit": limit]
            )
        }
    }

    /// Applies reclassification for one page of primary entries in a single
    /// transaction: updates the changed rows, then rebuilds the extracted
    /// children of every entry in `parentIDs` (delete + fresh inserts).
    ///
    /// Unlike the previous whole-library variant, this touches only the given
    /// parents, so Reparse History can walk a 100k library in bounded memory
    /// with one write transaction per page.
    public func applyReclassificationChunk(
        updates: [ReclassificationUpdate],
        parentIDs: [UUID],
        extractedEntries: [ClipboardEntry]
    ) throws -> ReclassificationResult {
        guard !updates.isEmpty || !parentIDs.isEmpty || !extractedEntries.isEmpty else {
            return ReclassificationResult(updatedEntries: 0, removedExtractedEntries: 0, insertedExtractedEntries: 0)
        }

        return try dbWriter.write { db in
            var updatedEntries = 0
            for update in updates {
                try db.execute(
                    sql: """
                    UPDATE \(ClipboardEntry.databaseTableName)
                    SET contentType = ?, metadata = ?, contentTypeMask = ?, isSynced = 0
                    WHERE id = ?
                    """,
                    arguments: [
                        update.contentType.rawValue,
                        update.metadata,
                        MetadataParser.typeMask(for: update.metadata),
                        update.entryID.uuidString,
                    ]
                )
                updatedEntries += db.changesCount
            }

            var removedExtractedEntries = 0
            let idChunkSize = 500
            for start in stride(from: 0, to: parentIDs.count, by: idChunkSize) {
                let chunk = parentIDs[start..<min(start + idChunkSize, parentIDs.count)]
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE parentEntryId IN (\(placeholders))",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                )
                removedExtractedEntries += db.changesCount
            }

            var insertedExtractedEntries = 0
            for entry in extractedEntries {
                try db.execute(
                    sql: """
                    INSERT INTO \(ClipboardEntry.databaseTableName)
                    (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash, parentEntryId, isSynced, contentTypeMask)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        0,
                        entry.contentTypeMask,
                    ]
                )
                insertedExtractedEntries += 1
            }

            return ReclassificationResult(
                updatedEntries: updatedEntries,
                removedExtractedEntries: removedExtractedEntries,
                insertedExtractedEntries: insertedExtractedEntries
            )
        }
    }

    /// Removes extracted children whose parent entry no longer exists. The old
    /// whole-library reparse implicitly cleared these (it deleted every child);
    /// the paged variant rebuilds children per-parent, so orphans are swept
    /// once at the end instead.
    @discardableResult
    public func deleteOrphanedExtractedEntries() throws -> Int {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                DELETE FROM \(ClipboardEntry.databaseTableName)
                WHERE parentEntryId IS NOT NULL
                  AND parentEntryId NOT IN (
                      SELECT id FROM \(ClipboardEntry.databaseTableName)
                  )
                """
            )
            return db.changesCount
        }
    }
}
