import Foundation
import GRDB
import os.log

public final class DatabaseManager: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    /// Coefficient applied to `ln(1 + ageDays)` when combining BM25 with a
    /// recency penalty in FTS5 search ordering. Tuned so that an 11000-day-old
    /// entry incurs ~5.6 of penalty (enough to overcome the BM25 advantage long
    /// token-heavy documents would otherwise have over fresh exact matches).
    static let recencyPenaltyCoefficient: Double = 0.6

    /// PRAGMA tuning applied to every connection opened by the queue.
    ///
    /// - WAL: enables concurrent readers + a single writer.
    /// - synchronous=NORMAL: durable across crashes; only sacrifices the most
    ///   recent uncommitted txns on a hard power loss. Writes are several×
    ///   faster than the default FULL.
    /// - cache_size=-16384: ~16 MB page cache (negative = kibibytes).
    /// - temp_store=MEMORY: keeps sort/group temporaries off disk.
    /// - mmap_size=128 MB: lets SQLite mmap the read path on Apple platforms,
    ///   eliminating a copy for hot pages.
    private static func tunePragmas(_ db: Database) throws {
        try db.execute(sql: "PRAGMA journal_mode = WAL;")
        try db.execute(sql: "PRAGMA synchronous = NORMAL;")
        try db.execute(sql: "PRAGMA cache_size = -16384;")
        try db.execute(sql: "PRAGMA temp_store = MEMORY;")
        try db.execute(sql: "PRAGMA mmap_size = 134217728;")
    }

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
        config.prepareDatabase { db in
            try DatabaseManager.tunePragmas(db)
        }

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
        // In-memory DBs benefit from temp_store=MEMORY too; WAL is not
        // applicable but the call is harmless (returns "memory" mode).
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA temp_store = MEMORY;")
            try db.execute(sql: "PRAGMA cache_size = -16384;")
        }

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

    /// Provides access to the underlying database queue for components that
    /// need to perform their own GRDB reads/writes (e.g. `SnippetStore`).
    public var dbQueueForSnippets: DatabaseQueue { dbQueue }

    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pasta", isDirectory: true)
            .appendingPathComponent("pasta.sqlite")
    }
}
