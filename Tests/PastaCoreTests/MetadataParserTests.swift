import XCTest
@testable import PastaCore

final class MetadataParserTests: XCTestCase {
    func testExtractAllValuesIncludesCustomDetectors() {
        let metadata = """
        {
          "emails":[{"email":"user@example.com","confidence":0.9}],
          "customDetectors":[
            {"name":"Ticket ID","value":"4821","confidence":0.8},
            {"name":"Order Ref","value":"ORD-123","confidence":0.75}
          ]
        }
        """

        let values = MetadataParser.extractAllValues(from: metadata)
        XCTAssertTrue(values.contains(where: { $0.type == .email && $0.value == "user@example.com" }))
        XCTAssertTrue(values.contains(where: { $0.type == .text && $0.displayValue == "Ticket ID: 4821" }))
        XCTAssertTrue(values.contains(where: { $0.type == .text && $0.displayValue == "Order Ref: ORD-123" }))
    }

    /// JSON exports written before `contentTypeMask`, `isPinned` and the sync
    /// flags existed must still import, deriving the mask from their metadata.
    func testLegacyExportDecodesWithDefaultsAndDerivedMask() throws {
        let entry = ClipboardEntry(
            id: UUID(uuidString: "3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F")!,
            content: "hello@example.com",
            contentType: .email,
            rawData: Data([0x01, 0x02, 0x03]),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            copyCount: 7,
            sourceApp: "com.apple.Terminal",
            metadata: #"{"emails":[{"email":"hello@example.com","confidence":0.9}]}"#,
            isSynced: true,
            isPinned: true,
            cloudSyncAllowed: false,
            receivedViaTailnet: true
        )
        XCTAssertEqual(try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(entry)), entry)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for key in ["contentTypeMask", "isPinned", "isSynced", "cloudSyncAllowed", "receivedViaTailnet"] {
            XCTAssertNotNil(legacy.removeValue(forKey: key), key)
        }
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.content, entry.content)
        XCTAssertEqual(decoded.rawData, entry.rawData)
        XCTAssertEqual(decoded.copyCount, 7)
        XCTAssertEqual(decoded.contentTypeMask, MetadataParser.typeMask(for: entry.metadata))
        XCTAssertTrue(decoded.contentTypeMask.contains(.email))
        XCTAssertFalse(decoded.isPinned)
        XCTAssertFalse(decoded.isSynced)
        XCTAssertTrue(decoded.cloudSyncAllowed)
        XCTAssertFalse(decoded.receivedViaTailnet)
    }
}
