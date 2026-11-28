import GRDB

struct QuickSearchCounts: Equatable, Sendable {
    var types: [ContentType: Int] = [:]
    var total: Int = 0
    var pinned: Int = 0
}

extension DatabaseManager {
    /// Aggregate count inputs without hydrating clipboard content or metadata.
    func quickSearchCounts() throws -> QuickSearchCounts {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT contentType, isPinned, COUNT(*) AS count
                FROM clipboard_entries
                GROUP BY contentType, isPinned
                """)
            var counts = QuickSearchCounts()
            for row in rows {
                let count: Int = row["count"]
                let rawType: String = row["contentType"]
                if let type = ContentType(rawValue: rawType) {
                    counts.types[type, default: 0] += count
                }
                counts.total += count
                let pinned: Bool = row["isPinned"]
                if pinned { counts.pinned += count }
            }
            return counts
        }
    }
}
