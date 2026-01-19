import Foundation

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
        let entry = try database.fetch(id: id)
        let deleted = try database.delete(id: id)

        if deleted, let imagePath = entry?.imagePath {
            try imageStorage.deleteImage(path: imagePath)
        }

        return deleted
    }

    /// Deletes entries from the last X minutes and cleans up any associated image files.
    @discardableResult
    public func deleteRecent(minutes: Int, now: Date = Date()) throws -> Int {
        let result = try database.deleteRecent(minutes: minutes, now: now)

        for imagePath in result.imagePaths {
            try imageStorage.deleteImage(path: imagePath)
        }

        return result.count
    }

    /// Deletes all entries and cleans up any associated image files.
    @discardableResult
    public func deleteAll() throws -> Int {
        let result = try database.deleteAll()

        for imagePath in result.imagePaths {
            try imageStorage.deleteImage(path: imagePath)
        }

        return result.count
    }
}
