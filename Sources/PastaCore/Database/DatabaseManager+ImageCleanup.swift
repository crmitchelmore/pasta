import Foundation
import GRDB

extension DatabaseManager {
    /// Delete candidate image files only after their final database reference
    /// disappears. Content-addressed files may be shared by several rows,
    /// including pinned entries that survive a retention or bulk delete.
    public func deleteUnreferencedImages(paths: [String], using storage: ImageStorageManager) throws {
        let candidates = Array(Set(paths))
        guard !candidates.isEmpty else { return }

        // Recheck after the delete commits, under the writer lock: a row added
        // since the caller collected candidates must also protect its image.
        // Keep the lock through removal so database writers cannot introduce
        // a reference between this check and the filesystem operation.
        try dbWriter.write { db in
            for start in stride(from: 0, to: candidates.count, by: Self.batchChunkSize) {
                let chunk = Array(candidates[start..<min(start + Self.batchChunkSize, candidates.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let referenced = Set(try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT imagePath FROM \(ClipboardEntry.databaseTableName) WHERE imagePath IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                ))
                for path in chunk where !referenced.contains(path) {
                    try storage.deleteImage(path: path)
                }
            }
        }
    }
}
