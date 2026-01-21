import CryptoKit
import Foundation
import GRDB

public enum ContentType: String, Codable, CaseIterable, Sendable {
    case text
    case email
    case phoneNumber
    case ipAddress
    case uuid
    case hash
    case jwt
    case envVar
    case envVarBlock
    case prose
    case image
    case screenshot
    case filePath
    case url
    case code
    case shellCommand
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

public struct ClipboardEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
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

    public var contentHash: String {
        if (contentType == .image || contentType == .screenshot), let data = rawData {
            return ClipboardEntry.sha256Hex(data)
        }
        return ClipboardEntry.sha256Hex(content)
    }

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

    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
