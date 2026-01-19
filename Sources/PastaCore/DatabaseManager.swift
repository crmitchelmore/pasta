import Foundation
import GRDB

public final class DatabaseManager {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL = DatabaseManager.defaultDatabaseURL()) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.foreignKeysEnabled = true

        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try DatabaseManager.migrator.migrate(dbQueue)
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
        }
    }

    public func fetchRecent(limit: Int = 50) throws -> [ClipboardEntry] {
        try dbQueue.read { db in
            try ClipboardEntry
                .order(Column("timestamp").desc)
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

}
