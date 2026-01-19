import Foundation
import GRDB

public enum ContentType: String, Codable, CaseIterable {
    case text
    case email
    case jwt
    case envVar
    case envVarBlock
    case prose
    case image
    case filePath
    case url
    case code
    case unknown
}

public enum CodeLanguage: String, Codable, CaseIterable {
    case swift
    case python
    case javaScript
    case typeScript
    case go
    case rust
    case java
    case cCpp
    case ruby
    case sql
    case json
    case yaml
    case html
    case css
    case shell
    case unknown
}

public struct ClipboardEntry: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "clipboard_entries"

    public let id: UUID
    public var content: String
    public var contentType: ContentType
    public var rawData: Data?
    public var imagePath: String?
    public var timestamp: Date
    public var copyCount: Int
    public var sourceApp: String?
    /// JSON-encoded metadata (arbitrary shape) stored as a string.
    public var metadata: String?

    public init(
        id: UUID = UUID(),
        content: String,
        contentType: ContentType,
        rawData: Data? = nil,
        imagePath: String? = nil,
        timestamp: Date = Date(),
        copyCount: Int = 1,
        sourceApp: String? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.rawData = rawData
        self.imagePath = imagePath
        self.timestamp = timestamp
        self.copyCount = copyCount
        self.sourceApp = sourceApp
        self.metadata = metadata
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["content"] = content
        container["contentType"] = contentType.rawValue
        container["rawData"] = rawData
        container["imagePath"] = imagePath
        container["timestamp"] = timestamp
        container["copyCount"] = copyCount
        container["sourceApp"] = sourceApp
        container["metadata"] = metadata
    }
