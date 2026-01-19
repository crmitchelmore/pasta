import XCTest
@testable import PastaCore

final class PastaCoreTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(PastaCore.version, "0.1.0")
    }

    func testClipboardEntryCodableRoundTrip() throws {
        let entry = ClipboardEntry(
            id: UUID(uuidString: "3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F")!,
            content: "hello@example.com",
            contentType: .email,
            rawData: Data([0x01, 0x02, 0x03]),
            imagePath: "/tmp/image.png",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            copyCount: 7,
            sourceApp: "com.apple.Terminal",
            metadata: "{\"key\":\"value\"}"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: data)

        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.content, entry.content)
        XCTAssertEqual(decoded.contentType, entry.contentType)
        XCTAssertEqual(decoded.rawData, entry.rawData)
        XCTAssertEqual(decoded.imagePath, entry.imagePath)
        XCTAssertEqual(decoded.timestamp, entry.timestamp)
        XCTAssertEqual(decoded.copyCount, entry.copyCount)
        XCTAssertEqual(decoded.sourceApp, entry.sourceApp)
        XCTAssertEqual(decoded.metadata, entry.metadata)
    }
}
