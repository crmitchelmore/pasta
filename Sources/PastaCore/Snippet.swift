import Foundation
import GRDB

/// A user-saved text template that may contain placeholder tokens
/// such as `{date}`, `{clipboard}`, `{uuid}`, `{cursor}`.
///
/// Snippets live alongside but separate from clipboard history. They are
/// evaluated at paste time by `SnippetPlaceholderEvaluator`.
public struct Snippet: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "snippets"

    public let id: UUID
    public var name: String
    /// Raw template content. May contain `{placeholder}` tokens that are
    /// substituted at paste time.
    public var content: String
    /// Optional shortname used by the picker for filtering.
    public var keyword: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        content: String,
        keyword: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.keyword = keyword
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["name"] = name
        container["content"] = content
        container["keyword"] = keyword
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }

    public init(row: Row) throws {
        let idString: String = row["id"]
        guard let parsedID = UUID(uuidString: idString) else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "Invalid snippet id: \(idString)")
        }
        self.id = parsedID
        self.name = row["name"]
        self.content = row["content"]
        self.keyword = row["keyword"]
        self.createdAt = row["createdAt"]
        self.updatedAt = row["updatedAt"]
    }

    /// First N characters of the content with newlines collapsed,
    /// suitable for one-line previews.
    public func previewLine(maxLength: Int = 60) -> String {
        let collapsed = content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if collapsed.count <= maxLength { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<endIndex]) + "…"
    }
}
