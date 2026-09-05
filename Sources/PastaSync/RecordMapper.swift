import CloudKit
import Foundation
import PastaCore

/// Maps between ClipboardEntry and CKRecord.
public struct RecordMapper {
    public static let recordType = "ClipboardEntry"
    
    // Size threshold for including raw data inline vs as asset
    private static let inlineDataThreshold = 50_000 // 50KB
    
    public init() {}

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
        let recordID = CKRecord.ID(recordName: entry.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)

        record["content"] = entry.content as CKRecordValue
        record["contentType"] = entry.contentType.rawValue as CKRecordValue
        record["contentHash"] = entry.contentHash as CKRecordValue
        record["timestamp"] = entry.timestamp as CKRecordValue
        record["copyCount"] = entry.copyCount as CKRecordValue
        record["sourceApp"] = entry.sourceApp as CKRecordValue?
        record["metadata"] = entry.metadata as CKRecordValue?
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
              let content = record["content"] as? String,
              let contentTypeRaw = record["contentType"] as? String,
              let contentType = ContentType(rawValue: contentTypeRaw),
              let timestamp = record["timestamp"] as? Date else {
            return nil
        }
        
        let copyCount = record["copyCount"] as? Int ?? 1
        let sourceApp = record["sourceApp"] as? String
        let metadata = record["metadata"] as? String
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
            isSynced: true
        )
    }
    
    /// Returns the content size from a record without downloading assets.
    public func contentSize(from record: CKRecord) -> Int {
        record["contentSize"] as? Int ?? 0
    }
}
