import PastaCore
import PastaDetectors
import XCTest

/// The history operations the iOS Shortcuts actions run.
final class ShortcutsFlowTests: XCTestCase {
    func testSaveLatestAndSearchShareTheCapturePolicy() throws {
        let db = try DatabaseManager.inMemory()
        let shortcuts = ClipboardHistoryShortcuts(database: db)
        let start = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertNil(try shortcuts.save("  \n", syncSensitiveContent: false), "blank input stores nothing")
        XCTAssertNil(try shortcuts.latest())

        let url = try XCTUnwrap(shortcuts.save("https://example.com/release", syncSensitiveContent: false, timestamp: start))
        XCTAssertEqual(url.contentType, .url)
        XCTAssertEqual(url.sourceApp, ClipboardHistoryShortcuts.sourceApp)
        XCTAssertTrue(url.allowsCloudUpload)

        let secret = try XCTUnwrap(shortcuts.save("API_KEY=shortcut-value-123", syncSensitiveContent: false,
                                                  timestamp: start.addingTimeInterval(1)))
        XCTAssertFalse(secret.allowsCloudUpload, "Shortcuts must not bypass the secret policy")
        XCTAssertTrue(try XCTUnwrap(shortcuts.save("API_KEY=opted-in-value-456", syncSensitiveContent: true,
                                                   timestamp: start.addingTimeInterval(2))).allowsCloudUpload)

        let parent = ClipboardEntry(content: "see https://example.com/child", contentType: .text,
                                    timestamp: start.addingTimeInterval(3), isSynced: true)
        try db.insert(parent, deduplicate: false)
        try db.insert(ClipboardEntry(content: "https://example.com/child", contentType: .url,
                                     timestamp: start.addingTimeInterval(4), parentEntryId: parent.id, isSynced: true),
                      deduplicate: false)
        try db.insert(ClipboardEntry(content: "", contentType: .image, rawData: Data([1, 2, 3]),
                                     timestamp: start.addingTimeInterval(5)), deduplicate: false)

        XCTAssertEqual(try shortcuts.latest()?.id, parent.id, "skips images and extracted values")
        XCTAssertEqual(try shortcuts.latest(contentType: .url)?.content, "https://example.com/child")
        XCTAssertEqual(try shortcuts.latest(contentType: .envVar)?.content, "API_KEY=opted-in-value-456")

        let again = try XCTUnwrap(shortcuts.save("https://example.com/release", syncSensitiveContent: false,
                                                 timestamp: start.addingTimeInterval(6)))
        XCTAssertEqual(again.id, url.id, "saving existing text folds into its row")
        XCTAssertEqual(again.copyCount, 2)

        XCTAssertEqual(try shortcuts.search("release").map(\.id), [url.id])
        XCTAssertEqual(try shortcuts.search("example", contentType: .url).count, 2)
        XCTAssertTrue(try shortcuts.search("nosuchthing").isEmpty)
    }
}
