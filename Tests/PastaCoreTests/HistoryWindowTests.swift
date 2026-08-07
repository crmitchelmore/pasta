import Foundation
import XCTest
@testable import PastaCore

final class HistoryWindowTests: XCTestCase {
    private func entry(_ content: String, at seconds: Double) -> ClipboardEntry {
        ClipboardEntry(
            content: content,
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: seconds)
        )
    }

    func testMergePutsHeadFirstAndDropsDuplicates() {
        let older = entry("older", at: 1)
        let newer = entry("newer", at: 2)
        let newest = entry("newest", at: 3)

        let merged = HistoryWindow.merge(
            head: [newest, newer],
            into: [newer, older],
            limit: 100
        )

        XCTAssertEqual(merged.map(\.id), [newest.id, newer.id, older.id])
    }

    func testMergeCapsAtLimit() {
        let head = (0..<5).map { entry("head \($0)", at: Double(100 + $0)) }
        let current = (0..<5).map { entry("current \($0)", at: Double($0)) }

        let merged = HistoryWindow.merge(head: head, into: current, limit: 7)

        XCTAssertEqual(merged.count, 7)
        XCTAssertEqual(merged.prefix(5).map(\.id), head.map(\.id))
    }

    func testIsFullyLoadedTreatsUnknownTotalAsIncomplete() {
        XCTAssertFalse(HistoryWindow.isFullyLoaded(loadedCount: 200, totalEntryCount: nil, displayLimit: 10_000))
        XCTAssertFalse(HistoryWindow.isFullyLoaded(loadedCount: 200, totalEntryCount: 3_000, displayLimit: 10_000))
        XCTAssertTrue(HistoryWindow.isFullyLoaded(loadedCount: 3_000, totalEntryCount: 3_000, displayLimit: 10_000))
        // The display limit, not the library size, is the ceiling.
        XCTAssertTrue(HistoryWindow.isFullyLoaded(loadedCount: 500, totalEntryCount: 3_000, displayLimit: 500))
    }

    /// Reproduces the "copy during the initial paged load" sequence that used to
    /// strand the visible library at a few hundred rows.
    ///
    /// `BackgroundService` lives in the `PastaApp` executable target, which has
    /// no test target, so this drives the same steps against a real database:
    /// partial paged load → insert → head merge → completeness check → resumed
    /// full load.
    func testInsertDuringPagedLoadLeavesWindowIncompleteUntilRefreshResumes() throws {
        let db = try DatabaseManager.inMemory()

        let seeded = (0..<3_000).map { index in
            ClipboardEntry(
                content: "seed \(index)",
                contentType: .text,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        try db.insertBatch(seeded, deduplicate: false)

        let displayLimit = 10_000

        // A refresh has fetched the first page only.
        var entries = try db.fetchRecent(limit: 200, offset: 0)
        let totalEntryCount = min(try db.countEntries(), displayLimit)
        XCTAssertEqual(entries.count, 200)
        XCTAssertFalse(HistoryWindow.isFullyLoaded(
            loadedCount: entries.count,
            totalEntryCount: totalEntryCount,
            displayLimit: displayLimit
        ))

        // A copy lands mid-load: the paging task is cancelled and a small head
        // page is merged in.
        let arrival = ClipboardEntry(
            content: "copied during load",
            contentType: .text,
            timestamp: Date(timeIntervalSince1970: 9_999)
        )
        try db.insert(arrival, deduplicate: false)

        let head = try db.fetchRecent(limit: 100)
        entries = HistoryWindow.merge(head: head, into: entries, limit: displayLimit)

        XCTAssertEqual(entries.first?.id, arrival.id)
        XCTAssertEqual(entries.count, 201)

        // The merge alone leaves the window truncated — which is exactly the
        // signal that must restart the paged refresh.
        XCTAssertFalse(HistoryWindow.isFullyLoaded(
            loadedCount: entries.count,
            totalEntryCount: totalEntryCount,
            displayLimit: displayLimit
        ))

        // Resumed refresh: the whole library, including the row inserted mid-load.
        entries = try db.fetchRecent(limit: displayLimit, offset: 0)
        let refreshedTotal = min(try db.countEntries(), displayLimit)

        XCTAssertEqual(entries.count, 3_001)
        XCTAssertEqual(refreshedTotal, 3_001)
        XCTAssertTrue(HistoryWindow.isFullyLoaded(
            loadedCount: entries.count,
            totalEntryCount: refreshedTotal,
            displayLimit: displayLimit
        ))
    }
}
