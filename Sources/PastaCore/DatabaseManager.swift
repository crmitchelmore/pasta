import Foundation
import GRDB
import os.log

public final class DatabaseManager: @unchecked Sendable {
    let dbWriter: any DatabaseWriter

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
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try DatabaseManager.tunePragmas(db)
        }

        var writer: any DatabaseWriter
        do {
            writer = try DatabaseManager.openAndMigrate(databaseURL: databaseURL, configuration: config)
            PastaLogger.database.info("Database initialized at \(databaseURL.path)")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Database initialization or migration failed")

            if DatabaseManager.isCorruptionError(error) {
                PastaLogger.database.warning("Database appears corrupted, attempting recovery")
                do {
                    try DatabaseManager.quarantineCorruptedDatabase(databaseURL: databaseURL)
                    writer = try DatabaseManager.openAndMigrate(databaseURL: databaseURL, configuration: config)
                    PastaLogger.database.info("Database recovered and re-initialized at \(databaseURL.path)")
                } catch {
                    PastaLogger.logError(error, logger: PastaLogger.database, context: "Database recovery failed")
                    throw PastaError.databaseCorrupted(underlying: error)
                }
            } else {
                throw PastaError.databaseInitializationFailed(underlying: error)
            }
        }

        self.dbWriter = writer
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

        return DatabaseManager(dbWriter: dbQueue)
    }

    /// Wraps an already-migrated writer. Internal so tests can drive migrations
    /// step by step (e.g. seed a pre-migration schema, then migrate).
    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    private static func openAndMigrate(databaseURL: URL, configuration: Configuration) throws -> DatabasePool {
        let writer = try DatabasePool(path: databaseURL.path, configuration: configuration)
        do {
            try migrator.migrate(writer)
        } catch {
            // Never move files while a failed migration's pool still holds
            // SQLite connections. If closing fails, abort recovery as well.
            try writer.close()
            throw error
        }
        return writer
    }

    static func isCorruptionError(_ error: Error) -> Bool {
        // Never replace a database on disk-full, I/O, lock, or migration errors,
        // even if their diagnostic message happens to mention corruption.
        guard let dbError = error as? DatabaseError else { return false }
        return dbError.resultCode == .SQLITE_CORRUPT || dbError.resultCode == .SQLITE_NOTADB
    }

    @discardableResult
    static func quarantineCorruptedDatabase(databaseURL: URL) throws -> URL {
        let fm = FileManager.default
        let quarantine = databaseURL.deletingLastPathComponent().appendingPathComponent(
            "\(databaseURL.lastPathComponent).corrupt-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: false)
        // SQLite uses suffixes, not extensions: pasta.sqlite-wal/-shm.
        // Move rather than delete, preserving bytes for recovery/support without
        // requiring enough free disk space to duplicate a large database.
        // If any move fails, throw before opening a replacement database; every
        // artifact remains either at its original path or in this quarantine.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if fm.fileExists(atPath: url.path) {
                try fm.moveItem(at: url, to: quarantine.appendingPathComponent(url.lastPathComponent))
            }
        }
        PastaLogger.database.warning("Preserved corrupted database at \(quarantine.path)")
        return quarantine
    }

    /// Provides access to the underlying database writer for components that
    /// need to perform their own GRDB reads/writes (e.g. `SnippetStore`).
    public var databaseWriterForSnippets: any DatabaseWriter { dbWriter }

    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pasta", isDirectory: true)
            .appendingPathComponent("pasta.sqlite")
    }
}
