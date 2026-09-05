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

    func testPersistedDiskOnlyImagesRoundTripThroughAsset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ImageStorageManager(imagesDirectoryURL: directory.appendingPathComponent("Images"))
        let database = try DatabaseManager(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let bytes = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a4X8AAAAASUVORK5CYII="
        ))
        let imagePath = try storage.saveImage(bytes)
        let mapper = RecordMapper()

        for contentType in [ContentType.image, .screenshot] {
            let original = ClipboardEntry(content: "", contentType: contentType, imagePath: imagePath)
            try database.insert(original, deduplicate: false)
            let persisted = try XCTUnwrap(database.fetch(id: original.id))
            XCTAssertNil(persisted.rawData)

            let prepared = try mapper.preparedRecord(from: persisted, zoneID: zoneID)
            defer { prepared.cleanupTemporaryAsset() }
            let asset = try XCTUnwrap(prepared.record["imageAsset"] as? CKAsset)
            let assetURL = try XCTUnwrap(asset.fileURL)
            XCTAssertNotEqual(assetURL.path, imagePath, "cleanup must never remove the original image")
            XCTAssertEqual(try Data(contentsOf: assetURL), bytes)
            XCTAssertEqual(mapper.contentSize(from: prepared.record), bytes.count)

            let decoded = try XCTUnwrap(mapper.entry(from: prepared.record))
            XCTAssertEqual(decoded.rawData, bytes)
            XCTAssertEqual(decoded.contentType, contentType)
            XCTAssertNil(decoded.imagePath, "another device must receive bytes, not a device-local path")
            prepared.cleanupTemporaryAsset()
            XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)), bytes)
        }
    }

    func testMissingPersistedImageFailsPreparation() {
        let mapper = RecordMapper()
        let missingPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        for contentType in [ContentType.image, .screenshot] {
            let entry = ClipboardEntry(content: "", contentType: contentType, imagePath: missingPath)
            XCTAssertThrowsError(try mapper.preparedRecord(from: entry, zoneID: zoneID))
        }
    }

    func testInlineDataTakesPrecedenceOverImagePath() throws {
        let mapper = RecordMapper()
        let bytes = Data([1, 2, 3, 4])
        let entry = ClipboardEntry(
            content: "", contentType: .image, rawData: bytes,
            imagePath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        )
        let prepared = try mapper.preparedRecord(from: entry, zoneID: zoneID)
        defer { prepared.cleanupTemporaryAsset() }

        let decoded = try XCTUnwrap(mapper.entry(from: prepared.record))
        XCTAssertEqual(decoded.rawData, bytes)
        XCTAssertEqual(mapper.contentSize(from: prepared.record), bytes.count)
    }

    func testImagesWithStorageDisabledRemainAssetless() throws {
        let mapper = RecordMapper()
        for contentType in [ContentType.image, .screenshot] {
            let entry = ClipboardEntry(content: "image copied", contentType: contentType)
            let prepared = try mapper.preparedRecord(from: entry, zoneID: zoneID)
            XCTAssertNil(prepared.temporaryAssetURL)
            XCTAssertNil(prepared.record["imageAsset"])
            XCTAssertEqual(mapper.contentSize(from: prepared.record), entry.content.utf8.count)
        }
    }

    func testNonImageDoesNotReadImagePath() throws {
        let mapper = RecordMapper()
        let entry = ClipboardEntry(
            content: "plain text", contentType: .text,
            imagePath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        )
        let prepared = try mapper.preparedRecord(from: entry, zoneID: zoneID)
        XCTAssertNil(prepared.record["imageAsset"])
        XCTAssertNil(prepared.temporaryAssetURL)
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

    /// The mask is a local column, not a CloudKit field: it must be derived
    /// from the imported metadata so records pushed by older builds (or other
    /// devices) filter correctly after import.
    func testImportedEntryDerivesContentTypeMaskLocally() throws {
        let mapper = RecordMapper()
        let original = ClipboardEntry(
            content: "mail me at a@b.com",
            contentType: .text,
            metadata: #"{"emails":[{"email":"a@b.com"}]}"#
        )

        let prepared = try mapper.preparedRecord(from: original, zoneID: zoneID)
        defer { prepared.cleanupTemporaryAsset() }
        XCTAssertNil(prepared.record["contentTypeMask"], "mask must not be synced")

        let decoded = try XCTUnwrap(mapper.entry(from: prepared.record))
        XCTAssertEqual(decoded.contentTypeMask, [.email])
    }
}
