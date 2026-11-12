import Foundation
import XCTest

@testable import PastaCore

/// The paged history load the panel performs at launch, run over a library
/// large enough to need many pages, with the timestamp ties and mid-walk
/// inserts a real clipboard produces.
final class HistoryKeysetLoadTests: XCTestCase {
    private var env: E2ETempEnvironment!
    private var database: DatabaseManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        env = try E2ETempEnvironment(name: "history")
        database = try env.openDatabase()
    }

    override func tearDownWithError() throws {
        database = nil
        env.destroy()
        env = nil
        try super.tearDownWithError()
    }

    /// Seeds `count` rows where every fourth timestamp collides with its
    /// neighbour so the rowid tiebreaker is exercised on every page boundary.
    private func seed(count: Int) throws -> [ClipboardEntry] {
        let entries = (0..<count).map { index in
            ClipboardEntry(
                content: "history row \(index)",
                contentType: index % 9 == 0 ? .url : .text,
                timestamp: Date(timeIntervalSince1970: 1_650_000_000 + Double(index / 4) * 13),
                sourceApp: "com.example.App\(index % 5)"
            )
        }
        try database.insertBatch(entries, deduplicate: false)
        return entries
    }

    /// The same walk `BackgroundService.refresh()` performs.
    private func walk(pageSize: Int, limit: Int = .max, onPage: ((Int) -> Void)? = nil) throws -> [ClipboardEntry] {
        var all: [ClipboardEntry] = []
        var cursor: DatabaseManager.HistoryCursor?
        var pageIndex = 0
        repeat {
            let page = try database.fetchHistoryPage(after: cursor, limit: min(pageSize, limit - all.count))
            all.append(contentsOf: page.entries)
            cursor = page.nextCursor
            onPage?(pageIndex)
            pageIndex += 1
        } while cursor != nil && all.count < limit
        return all
    }

    private func assertNewestFirstWithoutGapsOrDuplicates(_ loaded: [ClipboardEntry], expected: [ClipboardEntry], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(loaded.count, expected.count, "row count", file: file, line: line)
        XCTAssertEqual(Set(loaded.map(\.id)).count, loaded.count, "no duplicates", file: file, line: line)
        XCTAssertEqual(Set(loaded.map(\.id)), Set(expected.map(\.id)), "no gaps", file: file, line: line)
        for (previous, next) in zip(loaded, loaded.dropFirst()) {
            XCTAssertGreaterThanOrEqual(previous.timestamp, next.timestamp, "newest first", file: file, line: line)
        }
    }

    func testWalkingTheLibraryIsCompleteOrderedLimitedAndTerminates() throws {
        // Empty and single-row libraries terminate the walk.
        let empty = try database.fetchHistoryPage(after: nil, limit: 200)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertNil(empty.nextCursor)

        let only = ClipboardEntry(content: "solo", contentType: .text)
        try database.insert(only)
        let first = try database.fetchHistoryPage(after: nil, limit: 200)
        XCTAssertEqual(first.entries.map(\.id), [only.id])
        let after = try database.fetchHistoryPage(after: first.nextCursor, limit: 200)
        XCTAssertTrue(after.entries.isEmpty)
        XCTAssertNil(after.nextCursor)
        XCTAssertEqual(try database.fetchHistoryPage(after: nil, limit: 0).entries.count, 0)
        XCTAssertTrue(try database.delete(id: only.id))

        let seeded = try seed(count: 5_000)

        let byLargePages = try walk(pageSize: 1_000)
        assertNewestFirstWithoutGapsOrDuplicates(byLargePages, expected: seeded)

        // Page boundaries that fall inside a run of equal timestamps must not
        // shift or repeat rows: a different page size yields the identical order.
        let bySmallPages = try walk(pageSize: 199)
        XCTAssertEqual(bySmallPages.map(\.id), byLargePages.map(\.id), "order must not depend on page size")

        // fetchRecent (the head merge path) agrees with the keyset walk.
        XCTAssertEqual(try database.fetchRecent(limit: 300).map(\.id), Array(byLargePages.prefix(300).map(\.id)))

        // The whole-table order, resolved the same way SQLite would with rowid ties.
        let expectedOrder: [String] = try database.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM clipboard_entries ORDER BY timestamp DESC, rowid DESC")
        }
        XCTAssertEqual(byLargePages.map(\.id.uuidString), expectedOrder)

        // A display limit truncates the walk without overfetching.
        let limited = try walk(pageSize: 400, limit: 1_000)
        XCTAssertEqual(limited.count, 1_000)
        XCTAssertEqual(limited.map(\.id), Array(byLargePages.prefix(1_000)).map(\.id))
    }

    func testCopiesDeletesAndPinsDuringTheWalkReconcileThroughTheHistoryWindow() throws {
        let seeded = try seed(count: 3_000)
        var arrivals: [ClipboardEntry] = []

        let loaded = try walk(pageSize: 500) { pageIndex in
            // A copy lands after the first and third pages.
            guard pageIndex == 0 || pageIndex == 2 else { return }
            let arrival = ClipboardEntry(
                content: "arrived during page \(pageIndex)",
                contentType: .text,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(pageIndex))
            )
            try? self.database.insert(arrival, deduplicate: false)
            arrivals.append(arrival)
        }

        // The walk is stable: it neither repeats nor skips the seeded rows, and
        // the newer arrivals sit above every cursor already issued.
        assertNewestFirstWithoutGapsOrDuplicates(loaded, expected: seeded)
        XCTAssertFalse(loaded.contains { arrival in arrivals.map(\.id).contains(arrival.id) })

        // The head refresh picks the arrivals up and the merge dedups by id.
        let head = try database.fetchRecent(limit: 100)
        XCTAssertEqual(Array(head.prefix(2).map(\.id)), arrivals.reversed().map(\.id))
        let merged = HistoryWindow.merge(head: head, into: loaded, limit: .max)
        XCTAssertEqual(merged.count, seeded.count + arrivals.count)
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
        XCTAssertEqual(HistoryWindow.merge(head: head, into: loaded, limit: 50).map(\.id), Array(head.prefix(50)).map(\.id))
        XCTAssertTrue(HistoryWindow.merge(head: head, into: loaded, limit: 0).isEmpty)

        // A resumed full walk shows the arrivals in place.
        let resumed = try walk(pageSize: 1_000)
        assertNewestFirstWithoutGapsOrDuplicates(resumed, expected: seeded + arrivals)
        XCTAssertEqual(Array(resumed.prefix(2).map(\.id)), arrivals.reversed().map(\.id))

        // Deletes and pins between pages do not corrupt the walk.
        let victims = Set(seeded.filter { $0.content.hasSuffix("7") }.map(\.id))
        XCTAssertEqual(victims.count, 300)
        let pinnedRow = try XCTUnwrap(seeded.last { !victims.contains($0.id) })
        let interrupted = try walk(pageSize: 250) { pageIndex in
            guard pageIndex == 1 else { return }
            // Delete rows both above and below the current cursor, and pin one.
            _ = try? self.database.delete(ids: Array(victims))
            _ = try? self.database.setPinned(id: pinnedRow.id, pinned: true)
        }

        // Rows deleted below the cursor are gone; rows deleted above it were
        // already emitted (that stale tail is what the wholesale replacement
        // fixes). Either way: no duplicates, and nothing surviving was skipped.
        XCTAssertEqual(Set(interrupted.map(\.id)).count, interrupted.count)
        let survivors = Set((seeded + arrivals).map(\.id)).subtracting(victims)
        let interruptedIDs = Set(interrupted.map(\.id))
        XCTAssertTrue(survivors.isSubset(of: interruptedIDs), "no surviving row may be skipped by the walk")
        XCTAssertLessThanOrEqual(interruptedIDs.subtracting(survivors).count, 250, "only rows emitted before the delete can be stale")

        var window = try walk(pageSize: 1_000)
        XCTAssertEqual(Set(window.map(\.id)), survivors)
        XCTAssertEqual(try database.countEntries(), 2_702)
        XCTAssertEqual(window.filter(\.isPinned).map(\.id), [pinnedRow.id])

        // Reconcile later changes in memory the way BackgroundService does,
        // reloading only when the window cannot place the change itself.
        XCTAssertTrue(HistoryWindow.canApplyLocalRemoval(loadedCount: window.count, limit: 5_000, isPagingComplete: true, isRefreshing: false))
        XCTAssertFalse(HistoryWindow.canApplyLocalRemoval(loadedCount: window.count, limit: window.count, isPagingComplete: true, isRefreshing: false),
                       "a capped window must refill from the database")
        XCTAssertFalse(HistoryWindow.canApplyLocalRemoval(loadedCount: window.count, limit: 5_000, isPagingComplete: true, isRefreshing: true))
        XCTAssertTrue(HistoryWindow.canUpdateRowsInPlace(isPagingComplete: true, isRefreshing: false))
        XCTAssertFalse(HistoryWindow.canUpdateRowsInPlace(isPagingComplete: false, isRefreshing: false))

        // Pin: flip the flag in place, then confirm the stored row agrees.
        let pinTarget = window[10]
        XCTAssertTrue(try database.setPinned(id: pinTarget.id, pinned: true))
        let pinnedWindow = try XCTUnwrap(HistoryWindow.settingPinned(true, id: pinTarget.id, in: window))
        XCTAssertEqual(pinnedWindow.map(\.id), window.map(\.id), "pinning never moves a row")
        XCTAssertTrue(pinnedWindow[10].isPinned)
        XCTAssertNil(HistoryWindow.settingPinned(true, id: pinTarget.id, in: pinnedWindow), "already pinned")
        XCTAssertNil(HistoryWindow.settingPinned(true, id: UUID(), in: window), "not in the window")
        let storedPin = try XCTUnwrap(database.fetch(id: pinTarget.id))
        XCTAssertEqual(HistoryWindow.applying(changedRows: [storedPin], removedIDs: [], to: window, canRemoveLocally: true),
                       .updated(pinnedWindow))
        XCTAssertEqual(HistoryWindow.applying(changedRows: [storedPin], removedIDs: [], to: pinnedWindow, canRemoveLocally: true), .unchanged)
        XCTAssertEqual(HistoryWindow.replacing([storedPin], in: window), pinnedWindow)
        XCTAssertNil(HistoryWindow.replacing([storedPin], in: pinnedWindow))
        XCTAssertNil(HistoryWindow.replacing([], in: window))
        window = pinnedWindow

        // Delete: dropped locally only when allowed; unseen removals change nothing.
        let deleted = window[20]
        XCTAssertTrue(try database.delete(id: deleted.id))
        let withoutDeleted = HistoryWindow.removing(ids: [deleted.id], from: window)
        XCTAssertEqual(withoutDeleted.count, window.count - 1)
        XCTAssertEqual(HistoryWindow.removing(ids: [], from: window), window)
        XCTAssertEqual(HistoryWindow.applying(changedRows: [], removedIDs: [deleted.id], to: window, canRemoveLocally: true),
                       .updated(withoutDeleted))
        XCTAssertEqual(HistoryWindow.applying(changedRows: [], removedIDs: [deleted.id], to: window, canRemoveLocally: false), .needsReload)
        XCTAssertEqual(HistoryWindow.applying(changedRows: [], removedIDs: [UUID()], to: window, canRemoveLocally: false), .unchanged)
        XCTAssertEqual(HistoryWindow.applying(changedRows: [], removedIDs: [], to: window, canRemoveLocally: true), .unchanged)
        window = withoutDeleted

        // A brand-new row or a re-copy (which moves its timestamp) needs a reload.
        let newcomer = ClipboardEntry(content: "copied after load", contentType: .text,
                                      timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        try database.insert(newcomer, deduplicate: false)
        XCTAssertEqual(HistoryWindow.applying(changedRows: [newcomer], removedIDs: [], to: window, canRemoveLocally: true), .needsReload)
        let recopied = window[30]
        let recopy = ClipboardEntry(content: recopied.content, contentType: recopied.contentType,
                                    timestamp: Date(timeIntervalSince1970: 1_800_000_001))
        let canonical = try database.insert(recopy).entry
        XCTAssertEqual(canonical.id, recopied.id)
        XCTAssertEqual(HistoryWindow.applying(changedRows: [canonical], removedIDs: [], to: window, canRemoveLocally: true), .needsReload)

        // The head merge then matches what a fresh walk would show.
        let reconciled = HistoryWindow.merge(head: try database.fetchRecent(limit: 50), into: window, limit: .max)
        let reloaded = try walk(pageSize: 1_000)
        XCTAssertEqual(Set(reconciled.map(\.id)), Set(reloaded.map(\.id)))
        XCTAssertEqual(Array(reconciled.prefix(2).map(\.id)), [canonical.id, newcomer.id])
        XCTAssertEqual(Array(reloaded.prefix(2).map(\.id)), [canonical.id, newcomer.id])
    }
}
