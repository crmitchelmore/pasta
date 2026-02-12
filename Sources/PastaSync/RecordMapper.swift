import CloudKit
import Foundation
import PastaCore

/// Maps between ClipboardEntry and CKRecord.
public struct RecordMapper {
    public static let recordType = "ClipboardEntry"
    
    // Size threshold for including raw data inline vs as asset
    private static let inlineDataThreshold = 50_000 // 50KB
    
    public init() {}
    
    /// Creates a CKRecord from a ClipboardEntry.
    public func record(from entry: ClipboardEntry, zoneID: CKRecordZone.ID) -> CKRecord {
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
        
        // Store content size for download-on-demand decisions
        let contentSize = (entry.rawData?.count ?? entry.content.utf8.count)
        record["contentSize"] = contentSize as CKRecordValue
        
        // Handle image data as CKAsset for large blobs
        if let rawData = entry.rawData, !rawData.isEmpty {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(entry.id.uuidString)
                .appendingPathExtension("dat")
            try? rawData.write(to: tempURL)
            record["imageAsset"] = CKAsset(fileURL: tempURL)
        }
        
        return record
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
    
    /// Returns whether the record has an image asset.
    public func hasImageAsset(_ record: CKRecord) -> Bool {
        record["imageAsset"] != nil
    }
}
