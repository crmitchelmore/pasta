import Foundation
import GRDB

/// An entry that still needs a semantic vector under the current index key.
public struct SemanticEmbeddingCandidate: Sendable, Equatable {
    public let id: UUID
    /// The `id` column exactly as stored, so writes match imported rows
    /// whose UUID text is not in canonical upper case.
    let storageID: String
    public let content: String
    public let contentType: ContentType
    public let sourceApp: String?
    public let contentHash: String
    public let contentTypeMask: ContentTypeMask
    let cloudSyncAllowed: Bool
    let receivedViaTailnet: Bool

    /// False for entries that must never reach a remote provider: those kept
    /// off iCloud, file paths, and anything received over Tailnet.
    public var allowsCloudUpload: Bool {
        cloudSyncAllowed && !receivedViaTailnet && contentType != .filePath
    }
}

public struct SemanticEmbeddingRecord: Sendable, Equatable {
    public let id: UUID
    let storageID: String
    public let contentHash: String
    public let contentType: ContentType
    let contentTypeMask: ContentTypeMask
    let sourceApp: String?
    let cloudSyncAllowed: Bool
    let receivedViaTailnet: Bool
    /// `nil` records an entry deliberately left out of the index.
    public let vector: [Float]?

    public init(candidate: SemanticEmbeddingCandidate, vector: [Float]?) {
        self.id = candidate.id
        self.storageID = candidate.storageID
        self.contentHash = candidate.contentHash
        self.contentType = candidate.contentType
        self.contentTypeMask = candidate.contentTypeMask
        self.sourceApp = candidate.sourceApp
        self.cloudSyncAllowed = candidate.cloudSyncAllowed
        self.receivedViaTailnet = candidate.receivedViaTailnet
        self.vector = vector
    }
}

public struct SemanticIndexCounts: Sendable, Equatable {
    public var indexed: Int
    public var skipped: Int
    public var total: Int

    public init(indexed: Int = 0, skipped: Int = 0, total: Int = 0) {
        self.indexed = indexed
        self.skipped = skipped
        self.total = total
    }

    public var pending: Int { max(0, total - indexed - skipped) }
}

extension DatabaseManager {
    /// Characters of content read per candidate; the document builder only
    /// embeds the head of an entry.
    static let semanticCandidateContentCharacters = SemanticDocument.maxContentCharacters * 2

    /// True when row `s` was built from entry `e` as it is now: same text,
    /// type, detections, source app and sharing policy. Any change to these
    /// can alter the document or whether the entry may be sent at all.
    static let semanticRowIsCurrentSQL = """
        s.contentHash = e.contentHash AND s.contentType = e.contentType
          AND s.contentTypeMask = e.contentTypeMask AND s.sourceApp IS e.sourceApp
          AND s.cloudSyncAllowed = e.cloudSyncAllowed AND s.receivedViaTailnet = e.receivedViaTailnet
        """

    /// Most recent primary entries with no current vector under `indexKey`.
    public func pendingSemanticCandidates(indexKey: String, limit: Int) throws -> [SemanticEmbeddingCandidate] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id, substr(e.content, 1, ?) AS content, e.contentType, e.sourceApp,
                       e.contentHash, e.contentTypeMask, e.cloudSyncAllowed, e.receivedViaTailnet
                FROM clipboard_entries e
                LEFT JOIN semantic_embeddings s ON s.entryId = e.id
                WHERE e.parentEntryId IS NULL
                  AND (s.entryId IS NULL OR s.indexKey != ? OR NOT (\(Self.semanticRowIsCurrentSQL)))
                ORDER BY e.timestamp DESC
                LIMIT ?
                """, arguments: [Self.semanticCandidateContentCharacters, indexKey, limit])
            return rows.compactMap { row -> SemanticEmbeddingCandidate? in
                guard let idString: String = row["id"], let id = UUID(uuidString: idString) else { return nil }
                let type = ContentType(rawValue: row["contentType"] ?? "") ?? .unknown
                return SemanticEmbeddingCandidate(
                    id: id,
                    storageID: idString,
                    content: row["content"] ?? "",
                    contentType: type,
                    sourceApp: row["sourceApp"],
                    contentHash: row["contentHash"] ?? "",
                    contentTypeMask: ContentTypeMask(rawValue: row["contentTypeMask"] ?? 0),
                    cloudSyncAllowed: row["cloudSyncAllowed"] ?? true,
                    receivedViaTailnet: row["receivedViaTailnet"] ?? false
                )
            }
        }
    }

    /// Stores vectors (or skip markers) and returns how many rows were
    /// written. Entries deleted meanwhile are ignored so no orphan rows
    /// outlive the delete trigger.
    @discardableResult
    public func saveSemanticEmbeddings(_ records: [SemanticEmbeddingRecord], indexKey: String) throws -> Int {
        guard !records.isEmpty else { return 0 }
        return try dbWriter.write { db in
            var written = 0
            for record in records {
                let id = record.storageID
                try db.execute(sql: """
                    INSERT OR REPLACE INTO semantic_embeddings
                        (entryId, indexKey, contentHash, contentType, contentTypeMask, sourceApp,
                         cloudSyncAllowed, receivedViaTailnet, vector)
                    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM clipboard_entries WHERE id = ?)
                    """, arguments: [id, indexKey, record.contentHash, record.contentType.rawValue,
                                     record.contentTypeMask.rawValue, record.sourceApp,
                                     record.cloudSyncAllowed, record.receivedViaTailnet,
                                     record.vector.map(VectorMath.data(from:)), id])
                written += db.changesCount
            }
            return written
        }
    }

    /// Current vectors under `indexKey`, skipping stale rows.
    public func fetchSemanticVectors(indexKey: String) throws -> [(id: UUID, vector: [Float])] {
        try dbWriter.read { db in
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT s.entryId, s.vector FROM semantic_embeddings s
                JOIN clipboard_entries e ON e.id = s.entryId
                WHERE s.indexKey = ? AND s.vector IS NOT NULL
                  AND \(Self.semanticRowIsCurrentSQL)
                """, arguments: [indexKey])
            var result: [(id: UUID, vector: [Float])] = []
            while let row = try cursor.next() {
                guard let idString: String = row["entryId"], let id = UUID(uuidString: idString),
                      let data: Data = row["vector"], let vector = VectorMath.vector(from: data) else { continue }
                result.append((id, vector))
            }
            return result
        }
    }

    public func semanticIndexCounts(indexKey: String) throws -> SemanticIndexCounts {
        try dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    (SELECT COUNT(*) FROM clipboard_entries WHERE parentEntryId IS NULL) AS total,
                    (SELECT COUNT(*) FROM semantic_embeddings s JOIN clipboard_entries e ON e.id = s.entryId
                       WHERE s.indexKey = ? AND s.vector IS NOT NULL
                         AND \(Self.semanticRowIsCurrentSQL)) AS indexed,
                    (SELECT COUNT(*) FROM semantic_embeddings s JOIN clipboard_entries e ON e.id = s.entryId
                       WHERE s.indexKey = ? AND s.vector IS NULL
                         AND \(Self.semanticRowIsCurrentSQL)) AS skipped
                """, arguments: [indexKey, indexKey])
            return SemanticIndexCounts(indexed: row?["indexed"] ?? 0, skipped: row?["skipped"] ?? 0, total: row?["total"] ?? 0)
        }
    }

    /// Drops vectors from other models or document versions.
    @discardableResult
    public func deleteSemanticEmbeddings(notMatching indexKey: String) throws -> Int {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM semantic_embeddings WHERE indexKey != ?", arguments: [indexKey])
            return db.changesCount
        }
    }

    public func deleteAllSemanticEmbeddings() throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM semantic_embeddings")
        }
    }

    /// Entries for `ids`, in the order given. Missing IDs are dropped.
    public func fetchEntries(ids: [UUID]) throws -> [ClipboardEntry] {
        guard !ids.isEmpty else { return [] }
        let keys = Set(ids.flatMap { [$0.uuidString, $0.uuidString.lowercased()] })
        let entries = try dbWriter.read { db in
            try ClipboardEntry.filter(keys.contains(Column("id"))).fetchAll(db)
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}
