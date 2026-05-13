import Foundation
import GRDB

/// A thin GRDB-backed CRUD wrapper around the `snippets` table.
public final class SnippetStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueueForSnippets
    }

    /// Test-only initializer that takes a raw DatabaseQueue.
    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func list() throws -> [Snippet] {
        try dbQueue.read { db in
            try Snippet
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func find(matching query: String) throws -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try list() }

        let pattern = "%\(trimmed)%"
        return try dbQueue.read { db in
            try Snippet
                .filter(
                    Column("name").like(pattern)
                    || Column("keyword").like(pattern)
                    || Column("content").like(pattern)
                )
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func get(id: UUID) throws -> Snippet? {
        try dbQueue.read { db in
            try Snippet.filter(Column("id") == id.uuidString).fetchOne(db)
        }
    }

    @discardableResult
    public func create(_ snippet: Snippet) throws -> Snippet {
        try dbQueue.write { db in
            try snippet.insert(db)
        }
        return snippet
    }

    @discardableResult
    public func update(_ snippet: Snippet) throws -> Snippet {
        var updated = snippet
        updated.updatedAt = Date()
        try dbQueue.write { db in
            try updated.update(db)
        }
        return updated
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM \(Snippet.databaseTableName) WHERE id = ?",
                arguments: [id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Inserts the snippet if no row with the same id exists, otherwise replaces it.
    /// Used by the JSON import path.
    @discardableResult
    public func upsert(_ snippet: Snippet) throws -> Snippet {
        try dbQueue.write { db in
            if try Snippet.filter(Column("id") == snippet.id.uuidString).fetchOne(db) != nil {
                try snippet.update(db)
            } else {
                try snippet.insert(db)
            }
        }
        return snippet
    }
}
