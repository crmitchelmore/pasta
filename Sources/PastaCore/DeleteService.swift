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
}
