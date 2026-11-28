import XCTest
import PastaCore
@testable import PastaUI

final class ClipboardRowModelCacheTests: XCTestCase {
    func testCacheReusesUnchangedRowsRebuildsChangedOnesAndPrunes() {
        let cache = ClipboardRowModelCache()
        var entries = (0..<500).map { ClipboardEntry(content: "entry \($0)", contentType: $0 == 1 ? .url : .text) }

        let rows = cache.rows(for: entries)
        XCTAssertEqual(rows.map(\.id), entries.map(\.id))
        XCTAssertEqual(rows.prefix(2).map(\.previewText), ["entry 0", "entry 1"])
        XCTAssertEqual(rows.prefix(2).map(\.contentType), [.text, .url])
        XCTAssertEqual(cache.rowBuildCountForTesting, 500)

        // Repeated body evaluations with equal entries must not rebuild any row model.
        _ = cache.rows(for: entries)
        _ = cache.rows(for: entries)
        XCTAssertEqual(cache.rowBuildCountForTesting, 500)

        // Whole-value equality: any field change, even content, rebuilds that row only.
        entries[0].isPinned = true
        entries[0].copyCount = 3
        entries[1].content = "rewritten"
        let updated = cache.rows(for: entries)
        XCTAssertTrue(updated[0].isPinned)
        XCTAssertEqual(updated[0].copyCount, 3)
        XCTAssertEqual(updated[1].previewText, "rewritten")
        XCTAssertEqual(cache.rowBuildCountForTesting, 502)
        XCTAssertEqual(cache.cachedRowCountForTesting, 500)

        // A much smaller display set prunes everything not currently displayed.
        let smallBatch = (0..<10).map { ClipboardEntry(content: "fresh \($0)", contentType: .text) }
        _ = cache.rows(for: smallBatch)
        XCTAssertEqual(cache.cachedRowCountForTesting, 10)
    }
}
