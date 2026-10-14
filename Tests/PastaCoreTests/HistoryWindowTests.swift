import Foundation
import XCTest
@testable import PastaCore

final class HistoryWindowTests: XCTestCase {
    /// Drives the same keyset walk `BackgroundService.refresh()` performs.
    private func loadWholeHistory(_ db: DatabaseManager, pageSize: Int, limit: Int) throws -> [ClipboardEntry] {
        var entries: [ClipboardEntry] = []
        var cursor: DatabaseManager.HistoryCursor? = nil
        repeat {
            let page = try db.fetchHistoryPage(after: cursor, limit: min(pageSize, limit - entries.count))
            entries.append(contentsOf: page.entries)
            cursor = page.nextCursor
        } while cursor != nil && entries.count < limit
        return entries
    }

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
        var entries = try db.fetchHistoryPage(after: nil, limit: 200).entries
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
        entries = try loadWholeHistory(db, pageSize: 1_000, limit: displayLimit)
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
        let fullWindow = try loadWholeHistory(db, pageSize: 300, limit: 10_000)
        let deleted = fullWindow[500]
        _ = try db.delete(ids: [deleted.id])

        let freshTotal = try db.countEntries()
        XCTAssertEqual(freshTotal, 999)

        // Non-initial refresh: fresh head merged over the stale window.
        let head = try db.fetchRecent(limit: 200)
        let merged = HistoryWindow.merge(head: head, into: fullWindow, limit: 10_000)

        // The union still contains the deleted row, and is bigger than the
        // fresh total — counts cannot signal "reload still needed" here.
        XCTAssertEqual(merged.count, 1_000)
        XCTAssertGreaterThan(merged.count, freshTotal)
        XCTAssertTrue(merged.contains(where: { $0.id == deleted.id }))

        // Only the completed paged reload drops the stale row.
        let reloaded = try loadWholeHistory(db, pageSize: 300, limit: 10_000)
        XCTAssertEqual(reloaded.count, 999)
        XCTAssertFalse(reloaded.contains(where: { $0.id == deleted.id }))
    }

    // MARK: - In-place updates

    private func seededLibrary(_ count: Int) throws -> (DatabaseManager, [ClipboardEntry]) {
        let db = try DatabaseManager.inMemory()
        let seeded = (0..<count).map { entry("seed \($0)", at: Double($0)) }
        try db.insertBatch(seeded, deduplicate: false)
        return (db, try loadWholeHistory(db, pageSize: 1_000, limit: .max))
    }

    func testLocalRemovalOnlyWhenWindowHoldsWholeSettledLibrary() {
        XCTAssertTrue(HistoryWindow.canApplyLocalRemoval(loadedCount: 10, limit: .max, isPagingComplete: true, isRefreshing: false))
        // Capped window: the next-oldest row must slide into view.
        XCTAssertFalse(HistoryWindow.canApplyLocalRemoval(loadedCount: 10, limit: 10, isPagingComplete: true, isRefreshing: false))
        XCTAssertFalse(HistoryWindow.canApplyLocalRemoval(loadedCount: 10, limit: .max, isPagingComplete: false, isRefreshing: false))
        XCTAssertFalse(HistoryWindow.canApplyLocalRemoval(loadedCount: 10, limit: .max, isPagingComplete: true, isRefreshing: true))

        XCTAssertTrue(HistoryWindow.canUpdateRowsInPlace(isPagingComplete: true, isRefreshing: false))
        XCTAssertFalse(HistoryWindow.canUpdateRowsInPlace(isPagingComplete: false, isRefreshing: false))
        XCTAssertFalse(HistoryWindow.canUpdateRowsInPlace(isPagingComplete: true, isRefreshing: true))
    }

    /// A local delete must leave exactly what a full paged reload would show.
    func testLocalRemovalMatchesReload() throws {
        let (db, window) = try seededLibrary(2_500)
        let doomed = [window[0].id, window[1_234].id, window[2_499].id]
        _ = try db.delete(ids: doomed)

        let local = HistoryWindow.removing(ids: Set(doomed), from: window)

        XCTAssertEqual(local, try loadWholeHistory(db, pageSize: 1_000, limit: .max))
    }

    /// Pinning does not reorder history, so flipping the flag in place matches a reload.
    func testLocalPinMatchesReload() throws {
        let (db, window) = try seededLibrary(1_500)
        let target = window[700]
        XCTAssertTrue(try db.setPinned(id: target.id, pinned: true))

        let local = try XCTUnwrap(HistoryWindow.settingPinned(true, id: target.id, in: window))

        XCTAssertEqual(local, try loadWholeHistory(db, pageSize: 1_000, limit: .max))
        XCTAssertNil(HistoryWindow.settingPinned(true, id: target.id, in: local), "No-op pin publishes nothing")
        XCTAssertNil(HistoryWindow.settingPinned(true, id: UUID(), in: local), "Rows outside the window are ignored")
    }

    func testReplacingSwapsChangedRowsAndKeepsPositions() throws {
        let (db, window) = try seededLibrary(300)
        let ids = [window[3].id, window[250].id]
        try db.markSynced(ids: ids)
        let fresh = try ids.compactMap { try db.fetch(id: $0) }

        let local = try XCTUnwrap(HistoryWindow.replacing(fresh, in: window))

        XCTAssertEqual(local, try loadWholeHistory(db, pageSize: 1_000, limit: .max))
        XCTAssertTrue(local[3].isSynced)
        XCTAssertNil(HistoryWindow.replacing(fresh, in: local), "Unchanged rows publish nothing")
        XCTAssertNil(HistoryWindow.replacing([entry("elsewhere", at: 9)], in: local))
    }

    /// CloudKit echoes this device's own uploads: rows the window already
    /// shows as stored must not trigger any update.
    func testApplyingEchoedRowsIsUnchanged() throws {
        let (db, window) = try seededLibrary(100)
        let echoed = try [window[0].id, window[5].id].compactMap { try db.fetch(id: $0) }

        XCTAssertEqual(
            HistoryWindow.applying(changedRows: echoed, removedIDs: [], to: window, canRemoveLocally: true),
            .unchanged
        )
        XCTAssertEqual(
            HistoryWindow.applying(changedRows: [], removedIDs: [UUID()], to: window, canRemoveLocally: false),
            .unchanged,
            "Removing a row the window never showed changes nothing"
        )
    }

    func testApplyingPulledChangesMatchesReload() throws {
        let (db, window) = try seededLibrary(1_200)
        var remote = window[10]
        remote.content = "edited elsewhere"
        let removedID = window[900].id
        try db.applySyncChanges(modified: [remote], deleted: [removedID])
        let fresh = try XCTUnwrap(try db.fetch(id: remote.id))

        let change = HistoryWindow.applying(
            changedRows: [fresh], removedIDs: [removedID], to: window, canRemoveLocally: true
        )

        guard case .updated(let local) = change else { return XCTFail("Expected in-place update, got \(change)") }
        XCTAssertEqual(local, try loadWholeHistory(db, pageSize: 1_000, limit: .max))
    }

    func testApplyingFallsBackToReloadWhenRowsMoveOrAreNew() throws {
        let (_, window) = try seededLibrary(50)
        var moved = window[20]
        moved.timestamp = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            HistoryWindow.applying(changedRows: [moved], removedIDs: [], to: window, canRemoveLocally: true),
            .needsReload
        )
        XCTAssertEqual(
            HistoryWindow.applying(changedRows: [entry("new remote row", at: 25.5)], removedIDs: [], to: window, canRemoveLocally: true),
            .needsReload
        )
        XCTAssertEqual(
            HistoryWindow.applying(changedRows: [], removedIDs: [window[3].id], to: window, canRemoveLocally: false),
            .needsReload,
            "A capped or unsettled window must refill from the database"
        )
    }
}
