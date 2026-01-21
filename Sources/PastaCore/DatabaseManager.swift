import Foundation
import GRDB
import os.log

public final class DatabaseManager {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL = DatabaseManager.defaultDatabaseURL()) throws {
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to create database directory")
            throw PastaError.storageUnavailable(path: databaseURL.deletingLastPathComponent().path)
        }

        var config = Configuration()
        config.foreignKeysEnabled = true

        var queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
            try DatabaseManager.migrator.migrate(queue)
            PastaLogger.database.info("Database initialized at \(databaseURL.path)")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Database initialization or migration failed")

            if DatabaseManager.isCorruptionError(error) {
                PastaLogger.database.warning("Database appears corrupted, attempting recovery")
                do {
                    try DatabaseManager.attemptRecovery(databaseURL: databaseURL)
                    queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
                    try DatabaseManager.migrator.migrate(queue)
                    PastaLogger.database.info("Database recovered and re-initialized at \(databaseURL.path)")
                } catch {
                    PastaLogger.logError(error, logger: PastaLogger.database, context: "Database recovery failed")
                    throw PastaError.databaseCorrupted(underlying: error)
                }
            } else {
                throw PastaError.databaseInitializationFailed(underlying: error)
            }
        }

        self.dbQueue = queue
    }

    public static func inMemory() throws -> DatabaseManager {
        var config = Configuration()
        config.foreignKeysEnabled = true

        let dbQueue = try DatabaseQueue(configuration: config)
        try migrator.migrate(dbQueue)

        return DatabaseManager(dbQueue: dbQueue)
    }

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    private static func isCorruptionError(_ error: Error) -> Bool {
        if let dbError = error as? DatabaseError {
            return dbError.resultCode == .SQLITE_CORRUPT || dbError.resultCode == .SQLITE_NOTADB
        }

        let msg = error.localizedDescription.lowercased()
        return msg.contains("corrupt") || msg.contains("malformed") || msg.contains("not a database")
    }

    private static func attemptRecovery(databaseURL: URL) throws {
        let fm = FileManager.default
        for url in [databaseURL, databaseURL.appendingPathExtension("wal"), databaseURL.appendingPathExtension("shm")] {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createClipboardEntries") { db in
            try db.create(table: ClipboardEntry.databaseTableName) { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("content", .text).notNull()
                t.column("contentType", .text).notNull()
                t.column("rawData", .blob)
                t.column("imagePath", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("copyCount", .integer).notNull().defaults(to: 1)
                t.column("sourceApp", .text)
                t.column("metadata", .text)
                t.column("contentHash", .text).notNull()
            }

            try db.create(index: "idx_clipboard_entries_timestamp", on: ClipboardEntry.databaseTableName, columns: ["timestamp"])
            try db.create(index: "idx_clipboard_entries_contentType", on: ClipboardEntry.databaseTableName, columns: ["contentType"])
            try db.create(index: "idx_clipboard_entries_contentHash", on: ClipboardEntry.databaseTableName, columns: ["contentHash"])
            // Common query: WHERE contentType = ? ORDER BY timestamp DESC LIMIT ?
            try db.create(index: "idx_clipboard_entries_contentType_timestamp", on: ClipboardEntry.databaseTableName, columns: ["contentType", "timestamp"])
        }

        migrator.registerMigration("createClipboardEntriesFTS") { db in
            try db.execute(sql: """
            CREATE VIRTUAL TABLE clipboard_entries_fts USING fts5(
                content,
                contentType,
                content='clipboard_entries',
                content_rowid='rowid'
            );
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_ai AFTER INSERT ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(rowid, content, contentType)
                VALUES (new.rowid, new.content, new.contentType);
            END;
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_ad AFTER DELETE ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(clipboard_entries_fts, rowid, content, contentType)
                VALUES('delete', old.rowid, old.content, old.contentType);
            END;
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_au AFTER UPDATE ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(clipboard_entries_fts, rowid, content, contentType)
                VALUES('delete', old.rowid, old.content, old.contentType);
                INSERT INTO clipboard_entries_fts(rowid, content, contentType)
                VALUES (new.rowid, new.content, new.contentType);
            END;
            """)

            // Index any existing rows (important for existing on-disk databases).
            try db.execute(sql: "INSERT INTO clipboard_entries_fts(clipboard_entries_fts) VALUES('rebuild');")
        }

        return migrator
    }

    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pasta", isDirectory: true)
            .appendingPathComponent("pasta.sqlite")
    }

    public func insert(_ entry: ClipboardEntry) throws {
        let contentHash = entry.contentHash

        do {
            try dbQueue.write { db in
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

                try db.execute(
                    sql: """
                    INSERT INTO \(ClipboardEntry.databaseTableName)
                    (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

    public func fetch(id: UUID) throws -> ClipboardEntry? {
        try dbQueue.read { db in
            try ClipboardEntry
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)
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
    public func deleteAll() throws -> (count: Int, imagePaths: [String]) {
        try dbQueue.write { db in
            let imagePaths = try String.fetchAll(
                db,
                sql: "SELECT imagePath FROM \(ClipboardEntry.databaseTableName) WHERE imagePath IS NOT NULL"
            )

            try db.execute(sql: "DELETE FROM \(ClipboardEntry.databaseTableName)")

            return (db.changesCount, imagePaths)
        }
    }

    public func search(query: String, limit: Int = 50) throws -> [ClipboardEntry] {
        let pattern = "%\(query)%"
        return try dbQueue.read { db in
            try ClipboardEntry
                .filter(Column("content").like(pattern))
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Exact full-text search using the FTS5 virtual table.
    ///
    /// - Returns: Tuples of (ClipboardEntry, rank) where lower rank is better.
    public func searchExact(query: String, contentType: ContentType?, limit: Int = 50) throws -> [(ClipboardEntry, Double)] {
        try dbQueue.read { db in
            var sql = """
            SELECT e.*, bm25(clipboard_entries_fts) AS rank
            FROM clipboard_entries_fts
            JOIN clipboard_entries e ON e.rowid = clipboard_entries_fts.rowid
            WHERE clipboard_entries_fts MATCH ?
            """

            var args: [DatabaseValueConvertible] = [query]

            if let contentType {
                sql += " AND e.contentType = ?"
                args.append(contentType.rawValue)
            }

            sql += " ORDER BY rank ASC, e.timestamp DESC LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard let entry = try? ClipboardEntry(row: row) else { return nil }
                return (entry, row["rank"] ?? 0.0)
            }
        }
    }

    /// Deletes entries older than the newest `maxEntries` and returns any associated image paths.
    public func pruneToMaxEntries(_ maxEntries: Int) throws -> [String] {
        guard maxEntries > 0 else { return [] }

        return try dbQueue.write { db in
            let imagePaths = try String.fetchAll(
                db,
                sql: """
                SELECT imagePath
                FROM clipboard_entries
                WHERE rowid IN (
                    SELECT rowid
                    FROM clipboard_entries
                    ORDER BY timestamp DESC
                    LIMIT -1 OFFSET ?
                ) AND imagePath IS NOT NULL
                """,
                arguments: [maxEntries]
            )

            try db.execute(
                sql: """
                DELETE FROM clipboard_entries
                WHERE rowid IN (
                    SELECT rowid
                    FROM clipboard_entries
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
    public func pruneOlderThan(days: Int, now: Date = Date()) throws -> [String] {
        guard days > 0 else { return [] }

        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)

        return try dbQueue.write { db in
            let imagePaths = try String.fetchAll(
                db,
                sql: "SELECT imagePath FROM \(ClipboardEntry.databaseTableName) WHERE timestamp < ? AND imagePath IS NOT NULL",
                arguments: [cutoff]
            )

            try db.execute(
                sql: "DELETE FROM \(ClipboardEntry.databaseTableName) WHERE timestamp < ?",
                arguments: [cutoff]
            )

            let deleted = db.changesCount
            if deleted > 0 {
                PastaLogger.database.info("Pruned \(deleted) entries older than \(days) days")
            }

            return imagePaths
        }
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
                    (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    ]
                )
                PastaLogger.database.debug("Inserted new entry with type \(entry.contentType.rawValue)")
            }
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert entry")
            throw error
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
