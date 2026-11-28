import XCTest
import PastaCore
@testable import PastaUI

final class ClipboardRowDataTests: XCTestCase {
    func testRowDataDerivesBoundedMaskedPreviewsAndStableHeaders() throws {
        let metadata = try ContentComposition.metadata(nil, content: #"{"url":"https://example.com"}"#,
            values: [(.url, "https://example.com")], analysisTruncated: false)
        let mixed = ClipboardRowData(from: ClipboardEntry(content: "", contentType: .code, metadata: metadata))
        XCTAssertEqual(mixed.contentType, .code)
        XCTAssertEqual(mixed.classificationTitle, "Mixed \u{00b7} Code")
        XCTAssertEqual(mixed.classificationBadge, "MIXED \u{00b7} CODE")
        XCTAssertEqual(mixed.quickSearchMetadataSegments.first, mixed.classificationTitle)

        // utf8.count is O(1) for native strings; grapheme counting is not.
        XCTAssertEqual(ClipboardRowData(from: ClipboardEntry(content: "héllo", contentType: .text)).contentLength, "héllo".utf8.count)

        let long = ClipboardRowData(from: ClipboardEntry(
            content: "  \n" + String(repeating: "a", count: 500) + "\n ", contentType: .text))
        XCTAssertEqual(long.previewText.count, 300)
        XCTAssertTrue(long.previewText.allSatisfy { $0 == "a" })

        let card = ClipboardRowData(from: ClipboardEntry(content: "4111 1111 1111 1234", contentType: .creditCard))
        XCTAssertFalse(card.previewText.contains("4111"))
        XCTAssertTrue(card.previewText.hasSuffix("1234"))

        let multiLine = ClipboardRowData(from: ClipboardEntry(content: "line one\nline two", contentType: .text))
        XCTAssertEqual(multiLine.singleLinePreview, "line one line two")
        XCTAssertFalse(multiLine.isHeader)

        // HighPerformanceListView diffs on ids; an unstable header id forces a full reload.
        let header = ClipboardRowData.header("Pinned")
        XCTAssertTrue(header.isHeader)
        XCTAssertEqual(header.sectionHeader, "Pinned")
        XCTAssertEqual(header.id, ClipboardRowData.header("Pinned").id)
        XCTAssertNotEqual(header.id, ClipboardRowData.header("History").id)
    }
}
