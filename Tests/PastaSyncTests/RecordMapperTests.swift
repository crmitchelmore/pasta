import CloudKit
import XCTest
import PastaCore
@testable import PastaSync

final class RecordMapperTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    func testPreparedRecordWithoutRawDataHasNoTemporaryAsset() throws {
        let mapper = RecordMapper()
        let entry = ClipboardEntry(content: "plain text", contentType: .text)

        let prepared = try mapper.preparedRecord(from: entry, zoneID: zoneID)

        XCTAssertNil(prepared.temporaryAssetURL)
        XCTAssertNil(prepared.record["imageAsset"])
        XCTAssertEqual(prepared.record["content"] as? String, "plain text")
        // Cleanup on an asset-less record is a no-op, not a crash.
        prepared.cleanupTemporaryAsset()
    }

    func testPreparedRecordWritesAssetFileAndCleanupRemovesIt() throws {
        let mapper = RecordMapper()
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let entry = ClipboardEntry(content: "", contentType: .image, rawData: bytes)

        let prepared = try mapper.preparedRecord(from: entry, zoneID: zoneID)

        let assetURL = try XCTUnwrap(prepared.temporaryAssetURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertEqual(try Data(contentsOf: assetURL), bytes)

        let asset = try XCTUnwrap(prepared.record["imageAsset"] as? CKAsset)
        XCTAssertEqual(asset.fileURL, assetURL)

        prepared.cleanupTemporaryAsset()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: assetURL.path),
            "the temp .dat file must be removed once the push completes — it used to leak per pushed record"
        )
    }

    func testConcurrentPushesOfTheSameEntryUseDistinctAssetFiles() throws {
        let mapper = RecordMapper()
        let entry = ClipboardEntry(content: "", contentType: .image, rawData: Data([1, 2, 3]))

        let first = try mapper.preparedRecord(from: entry, zoneID: zoneID)
        let second = try mapper.preparedRecord(from: entry, zoneID: zoneID)
        defer {
            first.cleanupTemporaryAsset()
            second.cleanupTemporaryAsset()
        }

        let firstURL = try XCTUnwrap(first.temporaryAssetURL)
        let secondURL = try XCTUnwrap(second.temporaryAssetURL)
        XCTAssertNotEqual(firstURL, secondURL, "cleanup of one in-flight push must not delete another's asset")

        // Cleaning up one leaves the other intact.
        first.cleanupTemporaryAsset()
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testEntryRoundTripPreservesCoreFields() throws {
        let mapper = RecordMapper()
        let original = ClipboardEntry(
            content: "https://example.com",
            contentType: .url,
            timestamp: Date(timeIntervalSince1970: 1_000),
            sourceApp: "com.example.App",
            metadata: "{\"k\":1}"
        )

        let prepared = try mapper.preparedRecord(from: original, zoneID: zoneID)
        defer { prepared.cleanupTemporaryAsset() }
        let decoded = try XCTUnwrap(mapper.entry(from: prepared.record))

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.contentType, original.contentType)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.sourceApp, original.sourceApp)
        XCTAssertEqual(decoded.metadata, original.metadata)
        XCTAssertTrue(decoded.isSynced)
    }
}
