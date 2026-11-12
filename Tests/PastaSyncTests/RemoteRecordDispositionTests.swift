import CloudKit
import XCTest
import PastaCore
@testable import PastaSync

/// `SyncManager.disposition(for:mapper:)` decides, per fetched record, whether
/// the pull applies it, fails the batch (transient asset problem) or skips it
/// (this build cannot represent it). Skipping matters: a record written by a
/// newer app version on another device must not make every later pull fail
/// and freeze sync until this app updates. `SingleRecordSaveOutcome` decides
/// when a single push may be acknowledged.
final class RemoteRecordDispositionTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    func testFetchedRecordsApplySkipOrFailAndSavesAcknowledgeOnlyConfirmedRecords() throws {
        let mapper = RecordMapper()
        func record(name: String = UUID().uuidString, _ edit: (inout [String: CKRecordValueProtocol?]) -> Void = { _ in }) -> CKRecord {
            var fields: [String: CKRecordValueProtocol?] = [
                "content": "hello", "contentType": ContentType.text.rawValue,
                "timestamp": Date(timeIntervalSince1970: 1_000), "copyCount": 2
            ]
            edit(&fields)
            let record = CKRecord(recordType: RecordMapper.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
            for (key, value) in fields {
                record[key] = value
            }
            return record
        }

        let id = UUID()
        let applied = SyncManager.disposition(for: record(name: id.uuidString), mapper: mapper)
        guard case .apply(let entry) = applied else {
            return XCTFail("expected .apply, got \(applied)")
        }
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.content, "hello")
        XCTAssertEqual(entry.copyCount, 2)

        let skipped: [(CKRecord, String)] = [
            (record { $0["contentType"] = "hologram" }, "unknown contentType 'hologram'"),
            (record(name: "not-a-uuid"), "record name is not a UUID"),
            (record { $0["content"] = nil }, "missing content"),
            (record { $0["timestamp"] = nil }, "missing timestamp"),
            (record { $0["contentType"] = nil }, "missing contentType")
        ]
        for (record, reason) in skipped {
            XCTAssertEqual(SyncManager.disposition(for: record, mapper: mapper), .unmappable(reason: reason))
        }

        // A transient asset problem must NOT be skipped: the token would move
        // past image bytes that never reached SQLite.
        let unreadableAsset = record {
            $0["contentType"] = ContentType.image.rawValue
            $0["imageAsset"] = CKAsset(fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).dat"))
        }
        XCTAssertEqual(SyncManager.disposition(for: unreadableAsset, mapper: mapper), .assetUnavailable)

        let conflict = SingleRecordSaveOutcome()
        conflict.recordSaved(.failure(CKError(.serverRecordChanged)))
        XCTAssertThrowsError(try conflict.completed(.failure(CKError(.partialFailure))).get()) {
            XCTAssertEqual(($0 as? CKError)?.code, .serverRecordChanged)
        }
        let failed = SingleRecordSaveOutcome()
        failed.recordSaved(.failure(CKError(.quotaExceeded)))
        XCTAssertThrowsError(try failed.completed(.success(())).get()) {
            XCTAssertEqual(($0 as? CKError)?.code, .quotaExceeded)
        }
        XCTAssertThrowsError(try SingleRecordSaveOutcome().completed(.success(())).get())
        let confirmed = SingleRecordSaveOutcome()
        confirmed.recordSaved(.success(CKRecord(recordType: "ClipboardEntry")))
        XCTAssertThrowsError(try confirmed.completed(.failure(CKError(.networkFailure))).get())
        try confirmed.completed(.success(())).get()
    }
}
