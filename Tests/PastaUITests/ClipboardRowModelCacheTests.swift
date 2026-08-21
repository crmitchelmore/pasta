import XCTest
import PastaCore
@testable import PastaUI

final class ClipboardRowModelCacheTests: XCTestCase {
    func testReturnsRowsInOrderWithExpectedContent() {
        let cache = ClipboardRowModelCache()
        let entries = [
            ClipboardEntry(content: "first", contentType: .text),
            ClipboardEntry(content: "second", contentType: .url)
        ]

        let rows = cache.rows(for: entries)

        XCTAssertEqual(rows.map(\.id), entries.map(\.id))
        XCTAssertEqual(rows.map(\.previewText), ["first", "second"])
        XCTAssertEqual(rows.map(\.contentType), [.text, .url])
    }

    func testReusesCachedRowsAcrossBodyEvaluations() {
        let cache = ClipboardRowModelCache()
        let entries = (0..<50).map { ClipboardEntry(content: "entry \($0)", contentType: .text) }

        _ = cache.rows(for: entries)
        XCTAssertEqual(cache.rowBuildCountForTesting, 50)

        // Repeated body evaluations with the same (or equal) entries must not
        // rebuild any row model.
        _ = cache.rows(for: entries)
        _ = cache.rows(for: entries)
        XCTAssertEqual(cache.rowBuildCountForTesting, 50)
    }

    func testRebuildsRowWhenAnyFieldChanges() {
        let cache = ClipboardRowModelCache()
        var entry = ClipboardEntry(content: "hello", contentType: .text)
        let initial = cache.rows(for: [entry])
        XCTAssertFalse(initial[0].isPinned)
        XCTAssertEqual(initial[0].copyCount, 1)

        entry.isPinned = true
        entry.copyCount = 3
        let updated = cache.rows(for: [entry])

        XCTAssertTrue(updated[0].isPinned)
        XCTAssertEqual(updated[0].copyCount, 3)
    }

    func testRebuildsRowWhenContentChanges() {
        // Whole-value equality means even a content mutation (no such path
        // exists in the app today) can never render a stale preview.
        let cache = ClipboardRowModelCache()
        var entry = ClipboardEntry(content: "original", contentType: .text)
        _ = cache.rows(for: [entry])

        entry.content = "rewritten"
        let rows = cache.rows(for: [entry])

        XCTAssertEqual(rows[0].previewText, "rewritten")
        XCTAssertEqual(cache.rowBuildCountForTesting, 2)
    }

    func testPruneEvictsEntriesNoLongerDisplayed() {
        let cache = ClipboardRowModelCache()
        let bigBatch = (0..<500).map { ClipboardEntry(content: "entry \($0)", contentType: .text) }
        _ = cache.rows(for: bigBatch)
        XCTAssertEqual(cache.cachedRowCountForTesting, 500)

        // A much smaller display set pushes the cache over its keep threshold
        // and prunes everything not currently displayed.
        let smallBatch = (0..<10).map { ClipboardEntry(content: "fresh \($0)", contentType: .text) }
        _ = cache.rows(for: smallBatch)

        XCTAssertEqual(cache.cachedRowCountForTesting, 10)
    }
}
