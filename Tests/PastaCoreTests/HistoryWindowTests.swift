import Foundation
import XCTest
@testable import PastaCore

final class HistoryWindowTests: XCTestCase {
    /// Drives the same keyset walk `BackgroundService.refresh()` performs.
    private func loadWholeHistory(_ db: DatabaseManager, pageSize: Int = 1_000, limit: Int = .max) throws -> [ClipboardEntry] {
        var entries: [ClipboardEntry] = []
        var cursor: DatabaseManager.HistoryCursor?
        repeat {
            let page = try db.fetchHistoryPage(after: cursor, limit: min(pageSize, limit - entries.count))
            entries.append(contentsOf: page.entries)
            cursor = page.nextCursor
        } while cursor != nil && entries.count < limit
        return entries
    }

    private func entry(_ content: String, at seconds: Double) -> ClipboardEntry {
        ClipboardEntry(content: content, contentType: .text, timestamp: Date(timeIntervalSince1970: seconds))
    }

    private func seededLibrary(_ count: Int) throws -> (DatabaseManager, [ClipboardEntry]) {
        let db = try DatabaseManager.inMemory()
        try db.insertBatch((0..<count).map { entry("seed \($0)", at: Double($0)) }, deduplicate: false)
        return (db, try loadWholeHistory(db))
    }

    /// `BackgroundService` lives in the untestable `PastaApp` target, so this
    /// drives its merge and paged-reload steps against a real database.
    func testMergeAndPagedLoadRecovery() throws {
        let older = entry("older", at: 1)
        let newer = entry("newer", at: 2)
        let newest = entry("newest", at: 3)
        XCTAssertEqual(HistoryWindow.merge(head: [newest, newer], into: [newer, older], limit: 100).map(\.id), [newest.id, newer.id, older.id])
        let head = (0..<5).map { entry("head \($0)", at: Double(100 + $0)) }
        let capped = HistoryWindow.merge(head: head, into: (0..<5).map { entry("current \($0)", at: Double($0)) }, limit: 7)
        XCTAssertEqual(capped.count, 7)
        XCTAssertEqual(capped.prefix(5).map(\.id), head.map(\.id))

        // A copy during the initial paged load used to strand the library at a few hundred rows.
        let (db, _) = try seededLibrary(3_000)
        var entries = try db.fetchHistoryPage(after: nil, limit: 200).entries
        let arrival = entry("copied during load", at: 9_999)
        try db.insert(arrival, deduplicate: false)
        entries = HistoryWindow.merge(head: try db.fetchRecent(limit: 100), into: entries, limit: 10_000)
        XCTAssertEqual(entries.first?.id, arrival.id)
        XCTAssertEqual(entries.count, 201)
        XCTAssertEqual(try loadWholeHistory(db, limit: 10_000).count, 3_001)

        // After a delete the merged window is LARGER than the fresh total, which
        // is why BackgroundService tracks paging completeness explicitly.
        let fullWindow = try loadWholeHistory(db, pageSize: 300, limit: 10_000)
        let deleted = fullWindow[500]
        _ = try db.delete(ids: [deleted.id])
        let freshTotal = try db.countEntries()
        let merged = HistoryWindow.merge(head: try db.fetchRecent(limit: 200), into: fullWindow, limit: 10_000)
        XCTAssertGreaterThan(merged.count, freshTotal)
        XCTAssertTrue(merged.contains { $0.id == deleted.id })
        let reloaded = try loadWholeHistory(db, pageSize: 300, limit: 10_000)
        XCTAssertEqual(reloaded.count, freshTotal)
        XCTAssertFalse(reloaded.contains { $0.id == deleted.id })
    }

    /// Every in-place update must leave exactly what a full paged reload would show.
    func testInPlaceUpdatesMatchReload() throws {
        let removalCases: [(loaded: Int, limit: Int, complete: Bool, refreshing: Bool, allowed: Bool)] = [
            (10, .max, true, false, true),
            (10, 10, true, false, false),  // capped: the next-oldest row must slide into view
            (10, .max, false, false, false),
            (10, .max, true, true, false),
        ]
        for c in removalCases {
            XCTAssertEqual(HistoryWindow.canApplyLocalRemoval(loadedCount: c.loaded, limit: c.limit, isPagingComplete: c.complete, isRefreshing: c.refreshing), c.allowed, "\(c)")
        }
        XCTAssertTrue(HistoryWindow.canUpdateRowsInPlace(isPagingComplete: true, isRefreshing: false))
        XCTAssertFalse(HistoryWindow.canUpdateRowsInPlace(isPagingComplete: false, isRefreshing: false))
        XCTAssertFalse(HistoryWindow.canUpdateRowsInPlace(isPagingComplete: true, isRefreshing: true))

        var (db, window) = try seededLibrary(2_500)
        let doomed = [window[0].id, window[1_234].id, window[2_499].id]
        _ = try db.delete(ids: doomed)
        window = HistoryWindow.removing(ids: Set(doomed), from: window)
        XCTAssertEqual(window, try loadWholeHistory(db))

        let target = window[700]
        XCTAssertTrue(try db.setPinned(id: target.id, pinned: true))
        window = try XCTUnwrap(HistoryWindow.settingPinned(true, id: target.id, in: window))
        XCTAssertEqual(window, try loadWholeHistory(db))
        XCTAssertNil(HistoryWindow.settingPinned(true, id: target.id, in: window), "No-op pin publishes nothing")
        XCTAssertNil(HistoryWindow.settingPinned(true, id: UUID(), in: window), "Rows outside the window are ignored")

        let syncedIDs = [window[3].id, window[250].id]
        try db.markSynced(ids: syncedIDs)
        let fresh = try syncedIDs.compactMap { try db.fetch(id: $0) }
        window = try XCTUnwrap(HistoryWindow.replacing(fresh, in: window))
        XCTAssertEqual(window, try loadWholeHistory(db))
        XCTAssertTrue(window[3].isSynced)
        XCTAssertNil(HistoryWindow.replacing(fresh, in: window), "Unchanged rows publish nothing")
        XCTAssertNil(HistoryWindow.replacing([entry("elsewhere", at: 9)], in: window))

        // CloudKit echoes this device's own uploads; those must change nothing.
        let echoed = try [window[0].id, window[5].id].compactMap { try db.fetch(id: $0) }
        XCTAssertEqual(HistoryWindow.applying(changedRows: echoed, removedIDs: [], to: window, canRemoveLocally: true), .unchanged)
        XCTAssertEqual(HistoryWindow.applying(changedRows: [], removedIDs: [UUID()], to: window, canRemoveLocally: false), .unchanged)

        var remote = window[10]
        remote.content = "edited elsewhere"
        let removedID = window[900].id
        try db.applySyncChanges(modified: [remote], deleted: [removedID])
        let pulled = try XCTUnwrap(try db.fetch(id: remote.id))
        let change = HistoryWindow.applying(changedRows: [pulled], removedIDs: [removedID], to: window, canRemoveLocally: true)
        guard case .updated(let updated) = change else { return XCTFail("Expected in-place update, got \(change)") }
        XCTAssertEqual(updated, try loadWholeHistory(db))
        window = updated

        var moved = window[20]
        moved.timestamp = Date(timeIntervalSince1970: 10_000)
        let fallbacks: [(rows: [ClipboardEntry], removed: Set<UUID>, canRemove: Bool)] = [
            ([moved], [], true),
            ([entry("new remote row", at: 25.5)], [], true),
            ([], [window[3].id], false),  // a capped or unsettled window must refill
        ]
        for c in fallbacks {
            XCTAssertEqual(HistoryWindow.applying(changedRows: c.rows, removedIDs: c.removed, to: window, canRemoveLocally: c.canRemove), .needsReload)
        }
    }
}
