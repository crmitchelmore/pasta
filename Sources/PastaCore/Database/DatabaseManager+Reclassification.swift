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

    /// Applies reclassification updates and rebuilds extracted child entries in a single transaction.
    public func applyReclassification(
        updates: [ReclassificationUpdate],
        extractedEntries: [ClipboardEntry]
    ) throws -> ReclassificationResult {
        try dbQueue.write { db in
            var updatedEntries = 0
            for update in updates {
                try db.execute(
                    sql: """
                    UPDATE \(ClipboardEntry.databaseTableName)
                    SET contentType = ?, metadata = ?, isSynced = 0
                    WHERE id = ?
                    """,
                    arguments: [update.contentType.rawValue, update.metadata, update.entryID.uuidString]
                )
                updatedEntries += db.changesCount
            }

            try db.execute(
                sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE parentEntryId IS NOT NULL"
            )
            let removedExtractedEntries = db.changesCount

            var insertedExtractedEntries = 0
            for entry in extractedEntries {
                try db.execute(
                    sql: """
                    INSERT INTO \(ClipboardEntry.databaseTableName)
                    (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash, parentEntryId, isSynced)
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
                        entry.contentHash,
                        entry.parentEntryId?.uuidString,
                        0
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
}
