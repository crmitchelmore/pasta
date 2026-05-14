import Foundation
import GRDB

extension DatabaseManager {
    /// Sets the pinned state for an entry. Returns true if a row was updated.
    @discardableResult
    public func setPinned(id: UUID, pinned: Bool) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(ClipboardEntry.databaseTableName) SET isPinned = ? WHERE id = ?",
                arguments: [pinned, id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Returns the total number of pinned entries.
    public func pinnedCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(ClipboardEntry.databaseTableName) WHERE isPinned = 1"
            ) ?? 0
        }
    }
}
