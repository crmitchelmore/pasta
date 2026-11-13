import CloudKit
import Foundation
import PastaCore

/// Maps between ClipboardEntry and CKRecord.
public struct RecordMapper {
    public static let recordType = "ClipboardEntry"

    /// Clipboard text, source app and detector metadata are written only to
    /// `encryptedValues` (end-to-end encrypted when the user has Advanced Data
    /// Protection). CloudKit cannot change an existing field's encryption, so
    /// these use new keys; the legacy plaintext keys are read as a fallback
    /// for records written by older builds and cleared whenever a record is
    /// re-saved. Encrypted fields can't be queried, sorted or indexed, so
    /// `contentType`, `contentHash`, `timestamp` and the other bookkeeping
    /// fields stay plaintext.
    enum EncryptedKey {
        static let content = "encContent"
        static let sourceApp = "encSourceApp"
        static let metadata = "encMetadata"
    }

    enum LegacyPlaintextKey {
        static let content = "content"
        static let sourceApp = "sourceApp"
        static let metadata = "metadata"
        static let all = [content, sourceApp, metadata]
    }

    /// Reads a sensitive string field, preferring the encrypted value over the
    /// legacy plaintext one.
    static func sensitiveString(_ record: CKRecord, encrypted: String, legacy: String) -> String? {
        record.encryptedValues[encrypted] as? String ?? record[legacy] as? String
    }
    
    // Size threshold for including raw data inline vs as asset
    private static let inlineDataThreshold = 50_000 // 50KB
    
    public init() {}
    private struct TailnetMetadata: Codable {
        var pastaTailnetVersion: Int
        var originalMetadata: String?
    }
    private func cloudMetadata(_ entry: ClipboardEntry) -> String? {
        guard entry.receivedViaTailnet else { return entry.metadata }
        return (try? JSONEncoder().encode(TailnetMetadata(pastaTailnetVersion: 1, originalMetadata: entry.metadata)))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A record ready to push, plus the temporary asset file backing it (if
    /// any). CKAsset only references the file, so it must stay on disk until
    /// the save operation has completed — call `cleanupTemporaryAsset()` then
    /// (success or failure), otherwise every pushed record with rawData leaks
    /// a `.dat` file in the temporary directory.
    public struct PreparedRecord {
        public let record: CKRecord
        public let temporaryAssetURL: URL?

        public func cleanupTemporaryAsset() {
            guard let temporaryAssetURL else { return }
            try? FileManager.default.removeItem(at: temporaryAssetURL)
        }
    }

    /// Creates a CKRecord (and its temporary asset file, when the entry has
    /// raw data or a persisted image) from a ClipboardEntry.
    ///
    /// Throws when a referenced image cannot be read or the temporary asset
    /// file cannot be written. Callers must
    /// let that failure keep the entry unsynced: pushing the record without
    /// its asset and then marking it synced would silently lose the image
    /// bytes on every other device, with no retry.
    public func preparedRecord(from entry: ClipboardEntry, zoneID: CKRecordZone.ID) throws -> PreparedRecord {
        guard entry.allowsCloudUpload else { throw CocoaError(.fileReadNoPermission) }
        let recordID = CKRecord.ID(recordName: entry.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)

        record.encryptedValues[EncryptedKey.content] = entry.content
        record.encryptedValues[EncryptedKey.sourceApp] = entry.sourceApp
        record.encryptedValues[EncryptedKey.metadata] = cloudMetadata(entry)
        // Explicit nils make `.changedKeys` saves remove any plaintext copy a
        // legacy build left on an existing server record.
        for key in LegacyPlaintextKey.all { record[key] = nil }
        record["contentType"] = entry.contentType.rawValue as CKRecordValue
        record["contentHash"] = entry.contentHash as CKRecordValue
        record["timestamp"] = entry.timestamp as CKRecordValue
        record["copyCount"] = entry.copyCount as CKRecordValue
        record["parentEntryId"] = entry.parentEntryId?.uuidString as CKRecordValue?

        // macOS moves captured images to imagePath and clears rawData before
        // persistence. Keep inline bytes authoritative when both are present.
        var assetData = entry.rawData
        if assetData == nil,
           entry.contentType == .image || entry.contentType == .screenshot,
           let imagePath = entry.imagePath {
            assetData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        }
        // No data and no path is intentional when image storage is disabled.

        // Store content size for download-on-demand decisions
        let contentSize = (assetData?.count ?? entry.content.utf8.count)
        record["contentSize"] = contentSize as CKRecordValue

        // Handle image data as CKAsset for large blobs
        var temporaryAssetURL: URL? = nil
        if let assetData, !assetData.isEmpty {
            // Unique per prepared record so concurrent pushes of the same
            // entry can't clean up a file another operation still references.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(entry.id.uuidString)-\(UUID().uuidString)")
                .appendingPathExtension("dat")
            try assetData.write(to: tempURL)
            record["imageAsset"] = CKAsset(fileURL: tempURL)
            temporaryAssetURL = tempURL
        }

        return PreparedRecord(record: record, temporaryAssetURL: temporaryAssetURL)
    }
    
    /// Creates a ClipboardEntry from a CKRecord (without downloading assets).
    public func entry(from record: CKRecord) -> ClipboardEntry? {
        guard let idString = record.recordID.recordName as String?,
              let id = UUID(uuidString: idString),
              let content = Self.sensitiveString(record, encrypted: EncryptedKey.content, legacy: LegacyPlaintextKey.content),
              let contentTypeRaw = record["contentType"] as? String,
              let contentType = ContentType(rawValue: contentTypeRaw),
              let timestamp = record["timestamp"] as? Date else {
            return nil
        }
        
        let copyCount = record["copyCount"] as? Int ?? 1
        let sourceApp = Self.sensitiveString(record, encrypted: EncryptedKey.sourceApp, legacy: LegacyPlaintextKey.sourceApp)
        let storedMetadata = Self.sensitiveString(record, encrypted: EncryptedKey.metadata, legacy: LegacyPlaintextKey.metadata)
        let envelope = storedMetadata.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(TailnetMetadata.self, from: $0) }
        let metadata = envelope?.pastaTailnetVersion == 1 ? envelope?.originalMetadata : storedMetadata
        let parentEntryId: UUID? = {
            guard let str = record["parentEntryId"] as? String else { return nil }
            return UUID(uuidString: str)
        }()
        
        // Load asset data if available and small enough
        var rawData: Data?
        if let asset = record["imageAsset"] as? CKAsset,
           let fileURL = asset.fileURL {
            rawData = try? Data(contentsOf: fileURL)
        }
        
        // `contentTypeMask` is deliberately not a CloudKit field: the
        // initializer derives it locally from `metadata`, so records from
        // devices that never wrote the mask import correctly.
        return ClipboardEntry(
            id: id,
            content: content,
            contentType: contentType,
            rawData: rawData,
            imagePath: nil,
            timestamp: timestamp,
            copyCount: copyCount,
            sourceApp: sourceApp,
            metadata: metadata,
            parentEntryId: parentEntryId,
            isSynced: true,
            receivedViaTailnet: envelope?.pastaTailnetVersion == 1
        )
    }
    
    /// Returns the content size from a record without downloading assets.
    public func contentSize(from record: CKRecord) -> Int {
        record["contentSize"] as? Int ?? 0
    }
}
