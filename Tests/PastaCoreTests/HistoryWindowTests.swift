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

    /// Reproduces the "copy during the initial paged load" sequence that used to
    /// strand the visible library at a few hundred rows.
    ///
    /// `BackgroundService` lives in the `PastaApp` executable target, which has
    /// no test target, so this drives the same steps against a real database:
    /// partial paged load → insert → head merge → resumed full load.
    func testInsertDuringPagedLoadIsRecoveredByResumedRefresh() throws {
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
        XCTAssertEqual(entries.count, 200)

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

        // Resumed refresh: the whole library, including the row inserted mid-load.
        entries = try db.fetchRecent(limit: displayLimit, offset: 0)
        XCTAssertEqual(entries.count, 3_001)
        XCTAssertEqual(min(try db.countEntries(), displayLimit), 3_001)
    }

    /// Documents WHY BackgroundService tracks paging completeness as explicit
    /// state instead of inferring it from counts: after a delete, the merged
    /// interim window is LARGER than the fresh library total (merge only
    /// unions by id — the deleted row is still present until the paged reload
    /// finishes), so any `loadedCount >= total` inference reads "fully
    /// loaded" in exactly the state that still needs the reload.
    func testMergedWindowAfterDeleteCanExceedFreshTotal() throws {
        let db = try DatabaseManager.inMemory()

        let seeded = (0..<1_000).map { index in
            ClipboardEntry(
                content: "seed \(index)",
                contentType: .text,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        try db.insertBatch(seeded, deduplicate: false)

        // Fully loaded window, then a row below the head page is deleted.
        let fullWindow = try db.fetchRecent(limit: 10_000, offset: 0)
        let deleted = fullWindow[500]
        _ = try db.delete(ids: [deleted.id])

        let freshTotal = try db.countEntries()
        XCTAssertEqual(freshTotal, 999)

        // Non-initial refresh: fresh head merged over the stale window.
        let head = try db.fetchRecent(limit: 200, offset: 0)
        let merged = HistoryWindow.merge(head: head, into: fullWindow, limit: 10_000)

        // The union still contains the deleted row, and is bigger than the
        // fresh total — counts cannot signal "reload still needed" here.
        XCTAssertEqual(merged.count, 1_000)
        XCTAssertGreaterThan(merged.count, freshTotal)
        XCTAssertTrue(merged.contains(where: { $0.id == deleted.id }))

        // Only the completed paged reload drops the stale row.
        let reloaded = try db.fetchRecent(limit: 10_000, offset: 0)
        XCTAssertEqual(reloaded.count, 999)
        XCTAssertFalse(reloaded.contains(where: { $0.id == deleted.id }))
    }
}
