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
    case apiKey
    case envVar
    case envVarBlock
    case prose
    case image
    case screenshot
    case filePath
    case url
    case code
    case shellCommand
    case color
    case macAddress
    case creditCard
    case iban
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

public struct ClipboardEntry: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
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
    ///
    /// Assigning new metadata recomputes `contentTypeMask` so the two never
    /// drift apart.
    public var metadata: String? {
        didSet { contentTypeMask = MetadataParser.typeMask(for: metadata) }
    }
    /// Which extractable content types (`MetadataParser.extractableTypes`)
    /// appear in `metadata`. Derived from the metadata once, on creation, and
    /// persisted alongside it so type filters and counts over the history
    /// never re-parse the JSON.
    public private(set) var contentTypeMask: ContentTypeMask
    /// ID of the parent entry if this was extracted from another entry.
    public var parentEntryId: UUID?
    /// Whether this entry has been synced to iCloud.
    public var isSynced: Bool
    /// Whether this entry is pinned to the top of the list.
    /// Pinned entries are excluded from `DeleteService.deleteAll()` unless
    /// `includePinned: true` is passed, and are skipped by retention pruning.
    public var isPinned: Bool

    /// Whether this entry was extracted from a parent entry.
    public var isExtracted: Bool { parentEntryId != nil }

    public var contentHash: String {
        if contentType == .image || contentType == .screenshot {
            if let imagePath {
                let basename = URL(fileURLWithPath: imagePath)
                    .deletingPathExtension()
                    .lastPathComponent
                    .lowercased()
                if ClipboardEntry.isSHA256Hex(basename) {
                    return basename
                }
            }

            if let data = rawData {
                return ClipboardEntry.sha256Hex(data)
            }
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
        metadata: String? = nil,
        parentEntryId: UUID? = nil,
        isSynced: Bool = false,
        isPinned: Bool = false,
        contentTypeMask: ContentTypeMask? = nil
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
        self.parentEntryId = parentEntryId
        self.isSynced = isSynced
        self.isPinned = isPinned
        self.contentTypeMask = contentTypeMask ?? MetadataParser.typeMask(for: metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, contentType, rawData, imagePath, timestamp, copyCount
        case sourceApp, metadata, parentEntryId, isSynced, isPinned, contentTypeMask
    }

    /// Custom decoding so rows and JSON exports that predate `contentTypeMask`
    /// still decode, deriving the mask from the metadata they do carry.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        contentType = try c.decode(ContentType.self, forKey: .contentType)
        rawData = try c.decodeIfPresent(Data.self, forKey: .rawData)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        copyCount = try c.decode(Int.self, forKey: .copyCount)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        let metadata = try c.decodeIfPresent(String.self, forKey: .metadata)
        self.metadata = metadata
        parentEntryId = try c.decodeIfPresent(UUID.self, forKey: .parentEntryId)
        isSynced = try c.decodeIfPresent(Bool.self, forKey: .isSynced) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        contentTypeMask = try c.decodeIfPresent(ContentTypeMask.self, forKey: .contentTypeMask)
            ?? MetadataParser.typeMask(for: metadata)
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
        container["parentEntryId"] = parentEntryId?.uuidString
        container["isSynced"] = isSynced
        container["isPinned"] = isPinned
        container["contentTypeMask"] = contentTypeMask
    }

    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}
