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

    func testReusesCachedRowWhileEntryVersionUnchanged() {
        let cache = ClipboardRowModelCache()
        var entry = ClipboardEntry(content: "original", contentType: .text)
        _ = cache.rows(for: [entry])

        // `content` is deliberately outside the change token — it is immutable
        // for a given id in the app (dedup bumps show up as copyCount/timestamp
        // changes). Mutating it without touching any token field must therefore
        // return the cached row, proving lookups don't rebuild per call.
        entry.content = "mutated behind the cache's back"
        let rows = cache.rows(for: [entry])

        XCTAssertEqual(rows[0].previewText, "original")
    }

    func testRebuildsRowWhenTokenFieldChanges() {
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
