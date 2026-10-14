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
    /// Full text, or only its leading characters while the content is lazy
    /// (see `previewContent`).
    private var storedContent: String
    /// The entry's full text. A history row fetched lazily loads it from the
    /// database on first access (and caches it); use `previewContent` where
    /// only the leading characters are shown.
    public var content: String {
        get {
            (try? loadedContent()) ?? storedContent
        }
        set {
            storedContent = newValue
            materialize(\.contentByteCount)
        }
    }
    public var contentType: ContentType
    private var storedRawData: Data?
    public var rawData: Data? {
        get {
            try? loadedRawData()
        }
        set {
            storedRawData = newValue
            materialize(\.rawDataByteCount)
        }
    }
    public var imagePath: String?
    public var timestamp: Date
    public var copyCount: Int
    public var sourceApp: String?
    private var storedMetadata: String?
    /// JSON-encoded metadata (arbitrary shape) stored as a string.
    ///
    /// Assigning new metadata recomputes `contentTypeMask` so the two never
    /// drift apart.
    public var metadata: String? {
        get {
            try? loadedMetadata()
        }
        set {
            storedMetadata = newValue
            materialize(\.metadataByteCount)
            contentTypeMask = MetadataParser.typeMask(for: newValue)
        }
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
    /// Local policy; never infer upload consent from isSynced bookkeeping.
    public var cloudSyncAllowed: Bool
    /// Preserved through CloudKit so forwarding remains an explicit choice.
    public var receivedViaTailnet: Bool
    /// Payload columns `DatabaseManager.fetchHistoryPage` left in the
    /// database; `nil` for fully loaded entries.
    private var lazyPayload: LazyPayload?

    /// Whether this entry was extracted from a parent entry.
    public var isExtracted: Bool { parentEntryId != nil }

    public var isMixedContent: Bool { !isExtracted && contentTypeMask.contains(.mixed) }
    public var hasMultipleDetectedItems: Bool { !isExtracted && contentTypeMask.contains(.multipleItems) }

    public var allowsCloudUpload: Bool { cloudSyncAllowed && contentType != .filePath }

    public var filePaths: [String] {
        guard contentType == .filePath else { return [] }
        if let rawData, let paths = try? JSONDecoder().decode([String].self, from: rawData) { return paths }
        return content.split(separator: "\n").map(String.init)
    }

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

        // The stored column was computed from the same content on insert.
        if let storedHash = lazyPayload?.storedContentHash, lazyPayload?.contentByteCount != nil {
            return storedHash
        }
        return ClipboardEntry.sha256Hex(content)
    }

    /// The content's leading characters for display: the full text unless
    /// this history row's content is lazy, then at least
    /// `LazyPayload.previewCharacters` characters. Never loads.
    public var previewContent: String { storedContent }

    /// Whether `previewContent` stops short of the full `content`.
    public var isPreviewContentTruncated: Bool { lazyPayload?.contentByteCount != nil }

    /// UTF-8 byte length of the full content. Never loads.
    public var contentByteCount: Int { lazyPayload?.contentByteCount ?? storedContent.utf8.count }

    /// UTF-8 byte length of the full metadata, or `nil` without metadata. Never loads.
    public var metadataByteCount: Int? { lazyPayload?.metadataByteCount ?? storedMetadata?.utf8.count }

    // Full payload values, loading lazy columns. They throw when the row is
    // gone or unreadable, where the property getters fall back to the preview
    // (content) or nil; encoders use these so that never gets persisted.
    private func loadedContent() throws -> String {
        guard let lazyPayload, lazyPayload.contentByteCount != nil else { return storedContent }
        return try lazyPayload.loader.content()
    }

    private func loadedRawData() throws -> Data? {
        guard let lazyPayload, lazyPayload.rawDataByteCount != nil else { return storedRawData }
        return try lazyPayload.loader.rawData()
    }

    private func loadedMetadata() throws -> String? {
        guard let lazyPayload, lazyPayload.metadataByteCount != nil else { return storedMetadata }
        return try lazyPayload.loader.metadata()
    }

    /// Whether `other` has the same content; never loads a lazy row (see `==`).
    public func hasSameContent(as other: ClipboardEntry) -> Bool {
        LazyPayload.contentMatches(storedContent, lazyPayload, other.storedContent, other.lazyPayload)
    }

    /// Whether `other` has the same metadata; never loads a lazy row (see `==`).
    public func hasSameMetadata(as other: ClipboardEntry) -> Bool {
        LazyPayload.columnMatches(storedMetadata, lazyPayload, \.metadataByteCount,
                                  other.storedMetadata, other.lazyPayload, byteCount: \.utf8.count)
    }

    /// Whether any payload column is still waiting in the database (tests).
    var hasUnloadedPayload: Bool {
        guard let lazyPayload else { return false }
        return !lazyPayload.loader.hasLoaded(lazyPayload)
    }

    private mutating func materialize(_ column: WritableKeyPath<LazyPayload, Int?>) {
        guard lazyPayload?[keyPath: column] != nil else { return }
        lazyPayload?[keyPath: column] = nil
        if lazyPayload?.isEmpty == true { lazyPayload = nil }
    }

    /// Marks payload columns a lazy history projection left out. Each count
    /// is the full column's byte length; `nil` means the column was fetched
    /// in full.
    mutating func attachLazyPayload(
        contentByteCount: Int?,
        rawDataByteCount: Int?,
        metadataByteCount: Int?,
        storedContentHash: String?,
        reader: any DatabaseReader,
        rowKey: DatabaseValue
    ) {
        let payload = LazyPayload(
            contentByteCount: contentByteCount,
            rawDataByteCount: rawDataByteCount,
            metadataByteCount: metadataByteCount,
            storedContentHash: storedContentHash,
            loader: LazyPayloadLoader(reader: reader, key: rowKey)
        )
        lazyPayload = payload.isEmpty ? nil : payload
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
        contentTypeMask: ContentTypeMask? = nil,
        cloudSyncAllowed: Bool = true,
        receivedViaTailnet: Bool = false
    ) {
        self.cloudSyncAllowed = cloudSyncAllowed
        self.receivedViaTailnet = receivedViaTailnet
        self.id = id
        self.storedContent = content
        self.contentType = contentType
        self.storedRawData = rawData
        self.imagePath = imagePath
        self.timestamp = timestamp
        self.copyCount = copyCount
        self.sourceApp = sourceApp
        self.storedMetadata = metadata
        self.parentEntryId = parentEntryId
        self.isSynced = isSynced
        self.isPinned = isPinned
        self.contentTypeMask = contentTypeMask ?? MetadataParser.typeMask(for: metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, contentType, rawData, imagePath, timestamp, copyCount
        case sourceApp, metadata, parentEntryId, isSynced, isPinned, contentTypeMask, cloudSyncAllowed, receivedViaTailnet
    }

    /// Custom decoding so rows and JSON exports that predate `contentTypeMask`
    /// still decode, deriving the mask from the metadata they do carry.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cloudSyncAllowed = try c.decodeIfPresent(Bool.self, forKey: .cloudSyncAllowed) ?? true
        receivedViaTailnet = try c.decodeIfPresent(Bool.self, forKey: .receivedViaTailnet) ?? false
        id = try c.decode(UUID.self, forKey: .id)
        storedContent = try c.decode(String.self, forKey: .content)
        contentType = try c.decode(ContentType.self, forKey: .contentType)
        storedRawData = try c.decodeIfPresent(Data.self, forKey: .rawData)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        copyCount = try c.decode(Int.self, forKey: .copyCount)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        let metadata = try c.decodeIfPresent(String.self, forKey: .metadata)
        storedMetadata = metadata
        parentEntryId = try c.decodeIfPresent(UUID.self, forKey: .parentEntryId)
        isSynced = try c.decodeIfPresent(Bool.self, forKey: .isSynced) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        contentTypeMask = try c.decodeIfPresent(ContentTypeMask.self, forKey: .contentTypeMask)
            ?? MetadataParser.typeMask(for: metadata)
    }

    /// Hand-written row decoding with the same column conversions and legacy
    /// defaults as `init(from:)`. GRDB's synthesized `Decodable` path goes
    /// through a keyed container and dynamic casts per column, which made a
    /// full-history walk an order of magnitude slower than SQLite reading the
    /// rows.
    public init(row: Row) throws {
        cloudSyncAllowed = try row.decode(Bool?.self, forColumn: "cloudSyncAllowed") ?? true
        receivedViaTailnet = try row.decode(Bool?.self, forColumn: "receivedViaTailnet") ?? false
        id = try row.decode(UUID.self, forColumn: "id")
        storedContent = try row.decode(String.self, forColumn: "content")
        let rawType = try row.decode(String.self, forColumn: "contentType")
        guard let contentType = ContentType(rawValue: rawType) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [CodingKeys.contentType],
                debugDescription: "Cannot initialize ContentType from invalid String value \(rawType)"
            ))
        }
        self.contentType = contentType
        storedRawData = try row.decode(Data?.self, forColumn: "rawData")
        imagePath = try row.decode(String?.self, forColumn: "imagePath")
        timestamp = try row.decode(Date.self, forColumn: "timestamp")
        copyCount = try row.decode(Int.self, forColumn: "copyCount")
        sourceApp = try row.decode(String?.self, forColumn: "sourceApp")
        let metadata = try row.decode(String?.self, forColumn: "metadata")
        storedMetadata = metadata
        parentEntryId = try row.decode(UUID?.self, forColumn: "parentEntryId")
        isSynced = try row.decode(Bool?.self, forColumn: "isSynced") ?? false
        isPinned = try row.decode(Bool?.self, forColumn: "isPinned") ?? false
        contentTypeMask = try row.decode(ContentTypeMask?.self, forColumn: "contentTypeMask")
            ?? MetadataParser.typeMask(for: metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(loadedContent(), forKey: .content)
        try c.encode(contentType, forKey: .contentType)
        try c.encodeIfPresent(loadedRawData(), forKey: .rawData)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(copyCount, forKey: .copyCount)
        try c.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try c.encodeIfPresent(loadedMetadata(), forKey: .metadata)
        try c.encodeIfPresent(parentEntryId, forKey: .parentEntryId)
        try c.encode(isSynced, forKey: .isSynced)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(contentTypeMask, forKey: .contentTypeMask)
        try c.encode(cloudSyncAllowed, forKey: .cloudSyncAllowed)
        try c.encode(receivedViaTailnet, forKey: .receivedViaTailnet)
    }

    /// Compares lazy payload columns without loading them: by byte length,
    /// plus the content preview and stored hash. Payload columns do not
    /// change under a fixed `id` except through reclassification, which
    /// rewrites `contentTypeMask` alongside the metadata.
    public static func == (lhs: ClipboardEntry, rhs: ClipboardEntry) -> Bool {
        guard lhs.id == rhs.id,
              lhs.contentType == rhs.contentType,
              lhs.imagePath == rhs.imagePath,
              lhs.timestamp == rhs.timestamp,
              lhs.copyCount == rhs.copyCount,
              lhs.sourceApp == rhs.sourceApp,
              lhs.contentTypeMask == rhs.contentTypeMask,
              lhs.parentEntryId == rhs.parentEntryId,
              lhs.isSynced == rhs.isSynced,
              lhs.isPinned == rhs.isPinned,
              lhs.cloudSyncAllowed == rhs.cloudSyncAllowed,
              lhs.receivedViaTailnet == rhs.receivedViaTailnet
        else { return false }
        return lhs.hasSameContent(as: rhs)
            && LazyPayload.columnMatches(lhs.storedRawData, lhs.lazyPayload, \.rawDataByteCount,
                                         rhs.storedRawData, rhs.lazyPayload, byteCount: \.count)
            && lhs.hasSameMetadata(as: rhs)
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["cloudSyncAllowed"] = cloudSyncAllowed
        container["receivedViaTailnet"] = receivedViaTailnet
        container["id"] = id.uuidString
        container["content"] = try loadedContent()
        container["contentType"] = contentType.rawValue
        container["rawData"] = try loadedRawData()
        container["imagePath"] = imagePath
        container["timestamp"] = timestamp
        container["copyCount"] = copyCount
        container["sourceApp"] = sourceApp
        container["metadata"] = try loadedMetadata()
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
