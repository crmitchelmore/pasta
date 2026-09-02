import XCTest
import PastaCore
@testable import PastaUI

final class ClipboardRowDataTests: XCTestCase {
    func testContentLengthUsesUTF8Bytes() {
        // utf8.count is O(1) for native strings; grapheme counting is not.
        let entry = ClipboardEntry(content: "héllo", contentType: .text)
        let row = ClipboardRowData(from: entry)
        XCTAssertEqual(row.contentLength, "héllo".utf8.count)
    }

    func testPreviewTextTrimsAndCaps() {
        let entry = ClipboardEntry(
            content: "  \n" + String(repeating: "a", count: 500) + "\n ",
            contentType: .text
        )
        let row = ClipboardRowData(from: entry)
        XCTAssertEqual(row.previewText.count, 300)
        XCTAssertTrue(row.previewText.allSatisfy { $0 == "a" })
    }

    func testCreditCardPreviewMasksAllButLastFour() {
        let entry = ClipboardEntry(content: "4111 1111 1111 1234", contentType: .creditCard)
        let row = ClipboardRowData(from: entry)
        XCTAssertFalse(row.previewText.contains("4111"))
        XCTAssertTrue(row.previewText.hasSuffix("1234"))
    }

    func testHeaderRowsAreMarkedAsHeaders() {
        let header = ClipboardRowData.header("Pinned")
        XCTAssertTrue(header.isHeader)
        XCTAssertEqual(header.sectionHeader, "Pinned")

        let normal = ClipboardRowData(from: ClipboardEntry(content: "x", contentType: .text))
        XCTAssertFalse(normal.isHeader)
    }

    func testHeaderIDsAreStableAcrossBuilds() {
        // HighPerformanceListView diffs on ids; an unstable header id forces a full reload.
        XCTAssertEqual(ClipboardRowData.header("Pinned").id, ClipboardRowData.header("Pinned").id)
        XCTAssertNotEqual(ClipboardRowData.header("Pinned").id, ClipboardRowData.header("History").id)
    }

    func testSingleLinePreviewCollapsesNewlines() {
        let entry = ClipboardEntry(content: "line one\nline two", contentType: .text)
        let row = ClipboardRowData(from: entry)
        XCTAssertEqual(row.singleLinePreview, "line one line two")
    }
}
