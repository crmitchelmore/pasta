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
            try dbWriter.write { db in
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
                    (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash, parentEntryId, isPinned, contentTypeMask, isSynced)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        entry.contentTypeMask,
                        entry.isSynced,
                    ]
                )
                PastaLogger.database.debug("Inserted new entry with type \(entry.contentType.rawValue)")
            }
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert entry")
            throw error
        }
    }

    /// Outcome of a batched insert.
    public struct BatchInsertResult: Sendable {
        public let inserted: Int
        public let skipped: Int

        public init(inserted: Int, skipped: Int) {
            self.inserted = inserted
            self.skipped = skipped
        }
    }

    /// Rows written per transaction, and IDs per `IN (...)` list. Keeps bound
    /// argument counts well under SQLite's default 999-variable limit while
    /// still amortising transaction (and fsync) overhead across many rows.
    static let batchChunkSize = 500

    /// Inserts many entries using one write transaction per chunk instead of
    /// one transaction (plus one dedup read) per row.
    ///
    /// - Parameter deduplicate: when `true`, entries whose `contentHash`
    ///   already exists are skipped rather than inserted. The lookup happens
    ///   inside the same transaction and uses `idx_clipboard_entries_contentHash`,
    ///   so duplicates *within* the batch are skipped too. This matches the
    ///   importers' previous "check then skip" semantics — unlike
    ///   `insert(_:deduplicate:)`, which bumps `copyCount` on a hash hit.
    @discardableResult
    public func insertBatch(_ entries: [ClipboardEntry], deduplicate: Bool = true) throws -> BatchInsertResult {
        guard !entries.isEmpty else { return BatchInsertResult(inserted: 0, skipped: 0) }

        var inserted = 0
        var skipped = 0

        do {
            for start in stride(from: 0, to: entries.count, by: Self.batchChunkSize) {
                let chunk = entries[start..<min(start + Self.batchChunkSize, entries.count)]

                try dbWriter.write { db in
                    for entry in chunk {
                        let contentHash = entry.contentHash

                        if deduplicate {
                            let existing = try String.fetchOne(
                                db,
                                sql: "SELECT id FROM \(ClipboardEntry.databaseTableName) WHERE contentHash = ? LIMIT 1",
                                arguments: [contentHash]
                            )
                            if existing != nil {
                                skipped += 1
                                continue
                            }
                        }

                        try db.execute(
                            sql: """
                            INSERT INTO \(ClipboardEntry.databaseTableName)
                            (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash, parentEntryId, isPinned, contentTypeMask, isSynced)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                                entry.contentTypeMask,
                                entry.isSynced,
                            ]
                        )
                        inserted += 1
                    }
                }
            }
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert entry batch")
            throw error
        }

        PastaLogger.database.debug("Batch inserted \(inserted) entries (\(skipped) duplicates skipped)")
        return BatchInsertResult(inserted: inserted, skipped: skipped)
    }

    public func fetchRecent(limit: Int = 50) throws -> [ClipboardEntry] {
        try fetchRecent(contentType: nil, limit: limit)
    }

    /// Newest-first head of the history. Ties on `timestamp` are broken by
    /// rowid so the order agrees with `fetchHistoryPage(after:limit:)`.
    public func fetchRecent(contentType: ContentType?, limit: Int = 50) throws -> [ClipboardEntry] {
        try dbWriter.read { db in
            var request = ClipboardEntry
                .order(Column("timestamp").desc, Column.rowID.desc)

            if let contentType {
                request = request.filter(Column("contentType") == contentType.rawValue)
            }

            return try request
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Keyset cursor for paging the whole history newest-first without
    /// `OFFSET`. `(timestamp, rowid)` is exactly the key order of
    /// `idx_clipboard_entries_timestamp` (an index on `timestamp` is stored
    /// as `(timestamp, rowid)`), so each page is a single index seek plus
    /// `limit` steps instead of a re-walk of every skipped row.
    public struct HistoryCursor: Sendable, Equatable {
        public let timestamp: Date
        public let rowID: Int64

        public init(timestamp: Date, rowID: Int64) {
            self.timestamp = timestamp
            self.rowID = rowID
        }
    }

    /// One page of history plus the cursor for the page after it (`nil` once
    /// the page came back empty, i.e. the walk is complete).
    public struct HistoryPage: Sendable {
        public let entries: [ClipboardEntry]
        public let nextCursor: HistoryCursor?

        public init(entries: [ClipboardEntry], nextCursor: HistoryCursor?) {
            self.entries = entries
            self.nextCursor = nextCursor
        }
    }

    /// Fetches one page of entries strictly older than `cursor` (newest first,
    /// ties broken by rowid). Pass `nil` for the first page and feed each
    /// page's `nextCursor` back in until it is `nil`.
    ///
    /// Replaces the old `fetchRecent(limit:offset:)` loop, whose `OFFSET n`
    /// made SQLite walk and discard `n` index entries per page (O(n²/pageSize)
    /// over the full library). Stable while rows are inserted mid-walk: new
    /// rows land at the head, above every cursor already issued.
    public func fetchHistoryPage(after cursor: HistoryCursor?, limit: Int) throws -> HistoryPage {
        guard limit > 0 else { return HistoryPage(entries: [], nextCursor: cursor) }

        return try dbWriter.read { db in
            // The row-value comparison compiles to a single index SEARCH; the
            // equivalent `ts < ? OR (ts = ? AND rowid < ?)` degrades to a SCAN.
            let rows: RowCursor
            if let cursor {
                rows = try Row.fetchCursor(
                    db,
                    sql: """
                    SELECT rowid, * FROM \(ClipboardEntry.databaseTableName)
                    WHERE (timestamp, rowid) < (:ts, :rowid)
                    ORDER BY timestamp DESC, rowid DESC
                    LIMIT :limit
                    """,
                    arguments: ["ts": cursor.timestamp, "rowid": cursor.rowID, "limit": limit]
                )
            } else {
                rows = try Row.fetchCursor(
                    db,
                    sql: """
                    SELECT rowid, * FROM \(ClipboardEntry.databaseTableName)
                    ORDER BY timestamp DESC, rowid DESC
                    LIMIT :limit
                    """,
                    arguments: ["limit": limit]
                )
            }

            // Decode straight off the cursor: materialising `[Row]` first and
            // decoding the copies was ~2.5x slower over a 50k walk. The cursor
            // timestamp comes from the decoded entry (already a `Date`; it
            // round-trips to the identical stored string) so only rowid is
            // read per row.
            var entries: [ClipboardEntry] = []
            entries.reserveCapacity(limit)
            var lastRowID: Int64?
            while let row = try rows.next() {
                entries.append(try ClipboardEntry(row: row))
                lastRowID = row["rowid"]
            }

            let nextCursor = entries.last.flatMap { last in
                lastRowID.map { HistoryCursor(timestamp: last.timestamp, rowID: $0) }
            }
            return HistoryPage(entries: entries, nextCursor: nextCursor)
        }
    }

    public func countEntries() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(ClipboardEntry.databaseTableName)"
            ) ?? 0
        }
    }

    public func fetchAll() throws -> [ClipboardEntry] {
        try dbWriter.read { db in
            try ClipboardEntry
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    /// Fetches only primary entries (excluding extracted child entries).
    public func fetchPrimaryEntries() throws -> [ClipboardEntry] {
        try dbWriter.read { db in
            try ClipboardEntry
                .filter(Column("parentEntryId") == nil)
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    public func fetch(id: UUID) throws -> ClipboardEntry? {
        try dbWriter.read { db in
            try ClipboardEntry
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)
        }
    }

    /// Fetches all extracted entries for a given parent entry.
    public func fetchExtractedEntries(parentId: UUID) throws -> [ClipboardEntry] {
        try dbWriter.read { db in
            try ClipboardEntry
                .filter(Column("parentEntryId") == parentId.uuidString)
                .order(Column("contentType"))
                .fetchAll(db)
        }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE id = ?",
                arguments: [id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Deletes many entries in a single write transaction (chunked `IN` lists)
    /// instead of one fetch + one delete transaction per ID.
    ///
    /// Like `delete(id:)`, this ignores `isPinned` — the caller decides what to
    /// select.
    ///
    /// - Returns: the number of rows deleted and the image paths of the deleted
    ///   entries, so the caller can clean up the files.
    @discardableResult
    public func delete(ids: [UUID]) throws -> (count: Int, imagePaths: [String]) {
        guard !ids.isEmpty else { return (0, []) }

        return try dbWriter.write { db in
            var deleted = 0
            var imagePaths: [String] = []

            for start in stride(from: 0, to: ids.count, by: Self.batchChunkSize) {
                let chunk = Array(ids[start..<min(start + Self.batchChunkSize, ids.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let arguments = StatementArguments(chunk.map { $0.uuidString })

                imagePaths.append(contentsOf: try String.fetchAll(
                    db,
                    sql: """
                    SELECT imagePath FROM \(ClipboardEntry.databaseTableName)
                    WHERE id IN (\(placeholders)) AND imagePath IS NOT NULL
                    """,
                    arguments: arguments
                ))

                try db.execute(
                    sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE id IN (\(placeholders))",
                    arguments: arguments
                )
                deleted += db.changesCount
            }

            return (deleted, imagePaths)
        }
    }

    /// Efficiently checks if an entry with the given content hash exists.
    public func existsWithHash(_ hash: String) throws -> Bool {
        try dbWriter.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM \(ClipboardEntry.databaseTableName) WHERE contentHash = ? LIMIT 1",
                arguments: [hash]
            )
            return count != nil
        }
    }
}
