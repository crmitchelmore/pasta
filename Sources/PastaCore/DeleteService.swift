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
            let entry = try database.fetch(id: id)
            let deleted = try database.delete(id: id)

            if deleted, let imagePath = entry?.imagePath {
                try imageStorage.deleteImage(path: imagePath)
            }

            PastaLogger.database.debug("Deleted entry \(id.uuidString)")
            return deleted
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete entry")
            throw error
        }
    }

    /// Deletes entries from the last X minutes and cleans up any associated image files.
    @discardableResult
    public func deleteRecent(minutes: Int, now: Date = Date()) throws -> Int {
        do {
            let result = try database.deleteRecent(minutes: minutes, now: now)

            for imagePath in result.imagePaths {
                try imageStorage.deleteImage(path: imagePath)
            }

            PastaLogger.database.info("Deleted \(result.count) recent entries from last \(minutes) minutes")
            return result.count
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete recent entries")
            throw error
        }
    }

    /// Deletes all entries and cleans up any associated image files.
    @discardableResult
    public func deleteAll() throws -> Int {
        do {
            let result = try database.deleteAll()

            for imagePath in result.imagePaths {
                try imageStorage.deleteImage(path: imagePath)
            }

            PastaLogger.database.info("Deleted all \(result.count) entries")
            return result.count
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete all entries")
            throw error
        }
    }
}
