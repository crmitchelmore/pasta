import CloudKit
import XCTest
import PastaCore
@testable import PastaSync

final class RecordMapperTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    func testRecordsCarryFieldsAndImageBytesThroughOwnedTemporaryAssets() throws {
        do {
            let mapper = RecordMapper()
            let missingPath = { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path }

            let text = try mapper.preparedRecord(from: ClipboardEntry(content: "plain text", contentType: .text), zoneID: zoneID)
            XCTAssertNil(text.temporaryAssetURL)
            XCTAssertNil(text.record["imageAsset"])
            XCTAssertEqual(text.record["content"] as? String, "plain text")
            // Cleanup on an asset-less record is a no-op, not a crash.
            text.cleanupTemporaryAsset()

            let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
            let image = try mapper.preparedRecord(from: ClipboardEntry(content: "", contentType: .image, rawData: bytes), zoneID: zoneID)
            let assetURL = try XCTUnwrap(image.temporaryAssetURL)
            XCTAssertEqual(try Data(contentsOf: assetURL), bytes)
            XCTAssertEqual((image.record["imageAsset"] as? CKAsset)?.fileURL, assetURL)
            image.cleanupTemporaryAsset()
            XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path),
                           "the temp .dat file must be removed once the push completes — it used to leak per pushed record")

            let small = ClipboardEntry(content: "", contentType: .image, rawData: Data([1, 2, 3]))
            let first = try mapper.preparedRecord(from: small, zoneID: zoneID)
            let second = try mapper.preparedRecord(from: small, zoneID: zoneID)
            defer {
                first.cleanupTemporaryAsset()
                second.cleanupTemporaryAsset()
            }
            let secondURL = try XCTUnwrap(second.temporaryAssetURL)
            XCTAssertNotEqual(try XCTUnwrap(first.temporaryAssetURL), secondURL,
                              "cleanup of one in-flight push must not delete another's asset")
            first.cleanupTemporaryAsset()
            XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))

            let inlineBytes = Data([1, 2, 3, 4])
            let inline = try mapper.preparedRecord(
                from: ClipboardEntry(content: "", contentType: .image, rawData: inlineBytes, imagePath: missingPath()), zoneID: zoneID)
            defer { inline.cleanupTemporaryAsset() }
            XCTAssertEqual(try XCTUnwrap(mapper.entry(from: inline.record)).rawData, inlineBytes)
            XCTAssertEqual(mapper.contentSize(from: inline.record), inlineBytes.count)

            let nonImage = try mapper.preparedRecord(
                from: ClipboardEntry(content: "plain text", contentType: .text, imagePath: missingPath()), zoneID: zoneID)
            XCTAssertNil(nonImage.record["imageAsset"])
            XCTAssertNil(nonImage.temporaryAssetURL)

            for contentType in [ContentType.image, .screenshot] {
                XCTAssertThrowsError(try mapper.preparedRecord(
                    from: ClipboardEntry(content: "", contentType: contentType, imagePath: missingPath()), zoneID: zoneID))
                let storageDisabled = ClipboardEntry(content: "image copied", contentType: contentType)
                let assetless = try mapper.preparedRecord(from: storageDisabled, zoneID: zoneID)
                XCTAssertNil(assetless.temporaryAssetURL)
                XCTAssertNil(assetless.record["imageAsset"])
                XCTAssertEqual(mapper.contentSize(from: assetless.record), storageDisabled.content.utf8.count)
            }

            let original = ClipboardEntry(content: "https://example.com", contentType: .url,
                                          timestamp: Date(timeIntervalSince1970: 1_000),
                                          sourceApp: "com.example.App", metadata: "{\"k\":1}")
            let decoded = try XCTUnwrap(mapper.entry(from: try mapper.preparedRecord(from: original, zoneID: zoneID).record))
            XCTAssertEqual(decoded.id, original.id)
            XCTAssertEqual(decoded.content, original.content)
            XCTAssertEqual(decoded.contentType, original.contentType)
            XCTAssertEqual(decoded.timestamp, original.timestamp)
            XCTAssertEqual(decoded.sourceApp, original.sourceApp)
            XCTAssertEqual(decoded.metadata, original.metadata)
            XCTAssertTrue(decoded.isSynced)

            // The mask is a local column derived on import so records from older builds still filter correctly.
            let email = try mapper.preparedRecord(
                from: ClipboardEntry(content: "mail me at a@b.com", contentType: .text,
                                     metadata: #"{"emails":[{"email":"a@b.com"}]}"#), zoneID: zoneID)
            XCTAssertNil(email.record["contentTypeMask"], "mask must not be synced")
            XCTAssertEqual(try XCTUnwrap(mapper.entry(from: email.record)).contentTypeMask, [.email])
        }
        do {
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
    }
}
