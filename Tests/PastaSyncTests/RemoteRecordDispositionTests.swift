import CloudKit
import XCTest
import PastaCore
@testable import PastaSync

/// `SyncManager.disposition(for:mapper:)` decides, per fetched record, whether
/// the pull applies it, fails the batch (transient asset problem) or skips it
/// (this build cannot represent it). Skipping matters: a record written by a
/// newer app version on another device must not make every later pull fail
/// and freeze sync until this app updates.
final class RemoteRecordDispositionTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let mapper = RecordMapper()

    private func record(name: String = UUID().uuidString, fields: [String: CKRecordValueProtocol?]) -> CKRecord {
        let record = CKRecord(recordType: RecordMapper.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        for (key, value) in fields {
            record[key] = value
        }
        return record
    }

    private var validFields: [String: CKRecordValueProtocol?] {
        ["content": "hello", "contentType": ContentType.text.rawValue, "timestamp": Date(timeIntervalSince1970: 1_000), "copyCount": 2]
    }

    func testWellFormedRecordIsApplied() throws {
        let id = UUID()
        let disposition = SyncManager.disposition(for: record(name: id.uuidString, fields: validFields), mapper: mapper)
        guard case .apply(let entry) = disposition else {
            return XCTFail("expected .apply, got \(disposition)")
        }
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.content, "hello")
        XCTAssertEqual(entry.copyCount, 2)
    }

    func testUnknownContentTypeFromANewerAppIsSkippedNotFatal() {
        var fields = validFields
        fields["contentType"] = "hologram"
        let disposition = SyncManager.disposition(for: record(fields: fields), mapper: mapper)
        XCTAssertEqual(disposition, .unmappable(reason: "unknown contentType 'hologram'"))
    }

    func testMalformedRecordNameIsSkipped() {
        let disposition = SyncManager.disposition(for: record(name: "not-a-uuid", fields: validFields), mapper: mapper)
        XCTAssertEqual(disposition, .unmappable(reason: "record name is not a UUID"))
    }

    func testMissingRequiredFieldsAreSkippedWithTheMissingFieldNamed() {
        var noContent = validFields
        noContent["content"] = nil
        XCTAssertEqual(SyncManager.disposition(for: record(fields: noContent), mapper: mapper), .unmappable(reason: "missing content"))

        var noTimestamp = validFields
        noTimestamp["timestamp"] = nil
        XCTAssertEqual(SyncManager.disposition(for: record(fields: noTimestamp), mapper: mapper), .unmappable(reason: "missing timestamp"))

        var noType = validFields
        noType["contentType"] = nil
        XCTAssertEqual(SyncManager.disposition(for: record(fields: noType), mapper: mapper), .unmappable(reason: "missing contentType"))
    }

    func testUnreadableImageAssetFailsTheBatchInsteadOfSkipping() {
        // A transient asset problem must NOT be skipped: the token would move
        // past image bytes that never reached SQLite.
        var fields = validFields
        fields["contentType"] = ContentType.image.rawValue
        fields["imageAsset"] = CKAsset(fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).dat"))
        XCTAssertEqual(SyncManager.disposition(for: record(fields: fields), mapper: mapper), .assetUnavailable)
    }
}
