import Foundation
import GRDB

extension DatabaseManager {
    /// Reference discovery holds only a database read lock. Slow or failed file
    /// removal must not hold the SQLite writer or abort the remaining cleanup.
    public func deleteUnreferencedImages(paths: [String], using storage: ImageStorageManager) throws {
        var deferredPaths: [String] = []
        var retryDelay: TimeInterval = 0
        try deleteUnreferencedImages(paths: paths, remove: { path in
            if let delay = try storage.deleteImageAfterGrace(path: path) {
                deferredPaths.append(path)
                retryDelay = max(retryDelay, delay)
            }
        })
        guard !deferredPaths.isEmpty else { return }
        let pending = deferredPaths
        // Batch the retry: Delete All may contain thousands of recent files.
        // Recheck references after the grace window, never keep a DB lock open.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + retryDelay + 0.05) {
            do {
                try self.deleteUnreferencedImages(paths: pending, using: storage)
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.storage, context: "Deferred image cleanup failed")
            }
        }
    }

    /// Injection point for slow/failing files in concurrency regression tests.
    func deleteUnreferencedImages(paths: [String], remove: (String) throws -> Void) throws {
        let candidates = Array(Set(paths)).sorted()
        guard !candidates.isEmpty else { return }
        let unreferenced = try dbWriter.read { db in
            var result: [String] = []
            for start in stride(from: 0, to: candidates.count, by: Self.batchChunkSize) {
                let chunk = Array(candidates[start..<min(start + Self.batchChunkSize, candidates.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let referenced = Set(try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT imagePath FROM \(ClipboardEntry.databaseTableName) WHERE imagePath IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                ))
                result.append(contentsOf: chunk.filter { !referenced.contains($0) })
            }
            return result
        }
        for path in unreferenced {
            do { try remove(path) }
            catch { PastaLogger.logError(error, logger: PastaLogger.storage, context: "Image cleanup failed") }
        }
    }
}
