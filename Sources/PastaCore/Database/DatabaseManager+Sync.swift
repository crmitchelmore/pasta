import Foundation
import GRDB

extension DatabaseManager {
    /// Marks entries as synced to iCloud.
    public func markSynced(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "UPDATE \(ClipboardEntry.databaseTableName) SET isSynced = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids.map { $0.uuidString })
            )
        }
    }

    /// Returns the count of synced entries.
    public func syncedCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(ClipboardEntry.databaseTableName) WHERE isSynced = 1"
            ) ?? 0
        }
    }
}
