import Foundation
import os.log

public final class DeleteService {
    private let database: DatabaseManager
    private let imageStorage: ImageStorageManager

    public init(database: DatabaseManager, imageStorage: ImageStorageManager) {
        self.database = database
        self.imageStorage = imageStorage
    }

    /// Deletes a single entry by ID and cleans up any associated image file.
    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        do {
            let result = try database.delete(ids: [id])
            try database.deleteUnreferencedImages(paths: result.imagePaths, using: imageStorage)

            PastaLogger.database.debug("Deleted entry \(id.uuidString)")
            return result.count > 0
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete entry")
            throw error
        }
    }

    /// Deletes many entries at once and cleans up any associated image files.
    ///
    /// Prefer this over looping `delete(id:)`: that costs two write
    /// transactions per ID (and fires the FTS delete trigger inside each),
    /// whereas this uses a single transaction with chunked `IN` lists.
    @discardableResult
    public func delete(ids: [UUID]) throws -> Int {
        guard !ids.isEmpty else { return 0 }

        do {
            let result = try database.delete(ids: ids)

            try database.deleteUnreferencedImages(paths: result.imagePaths, using: imageStorage)

            PastaLogger.database.debug("Deleted \(result.count) entries in bulk")
            return result.count
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete entries")
            throw error
        }
    }

    /// Deletes entries from the last X minutes and cleans up any associated image files.
    @discardableResult
    public func deleteRecent(minutes: Int, now: Date = Date()) throws -> Int {
        do {
            let result = try database.deleteRecent(minutes: minutes, now: now)

            try database.deleteUnreferencedImages(paths: result.imagePaths, using: imageStorage)

            PastaLogger.database.info("Deleted \(result.count) recent entries from last \(minutes) minutes")
            return result.count
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete recent entries")
            throw error
        }
    }

    /// Deletes all entries and cleans up any associated image files.
    ///
    /// - Parameter includePinned: when `false` (the default), pinned entries are
    ///   preserved so quick-clear actions don't wipe favorites. Pass `true` from
    ///   explicit "wipe everything" UI (e.g. Settings → Clear All).
    @discardableResult
    public func deleteAll(includePinned: Bool = false) throws -> Int {
        do {
            let result = try database.deleteAll(includePinned: includePinned)

            try database.deleteUnreferencedImages(paths: result.imagePaths, using: imageStorage)

            PastaLogger.database.info("Deleted all \(result.count) entries (includePinned=\(includePinned))")
            return result.count
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete all entries")
            throw error
        }
    }
}
