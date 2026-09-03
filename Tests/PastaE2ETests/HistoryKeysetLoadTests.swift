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

    func testWalkingSeveralThousandRowsIsCompleteOrderedAndStableAcrossPageSizes() throws {
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
    }

    func testDisplayLimitTruncatesTheWalkWithoutOverfetching() throws {
        let seeded = try seed(count: 2_500)
        let limited = try walk(pageSize: 400, limit: 1_000)
        XCTAssertEqual(limited.count, 1_000)
        XCTAssertEqual(limited.map(\.id), Array(try walk(pageSize: 1_000).prefix(1_000)).map(\.id))
        XCTAssertEqual(Set(limited.map(\.id)).count, 1_000)
        _ = seeded
    }

    func testCopiesArrivingMidWalkLandAtTheHeadWithoutDisturbingLaterPages() throws {
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

        // A resumed full walk shows the arrivals in place.
        let resumed = try walk(pageSize: 1_000)
        assertNewestFirstWithoutGapsOrDuplicates(resumed, expected: seeded + arrivals)
        XCTAssertEqual(Array(resumed.prefix(2).map(\.id)), arrivals.reversed().map(\.id))
    }

    func testDeletesAndPinsBetweenPagesDoNotCorruptTheWalk() throws {
        let seeded = try seed(count: 2_000)
        let victims = Set(seeded.filter { $0.content.hasSuffix("7") }.map(\.id))
        XCTAssertEqual(victims.count, 200)

        let loaded = try walk(pageSize: 250) { pageIndex in
            guard pageIndex == 1 else { return }
            // Delete rows both above and below the current cursor, and pin one.
            _ = try? self.database.delete(ids: Array(victims))
            if let pinned = seeded.last(where: { !victims.contains($0.id) }) {
                _ = try? self.database.setPinned(id: pinned.id, pinned: true)
            }
        }

        // Rows deleted below the cursor are gone; rows deleted above it were
        // already emitted (that stale tail is what the wholesale replacement
        // fixes). Either way: no duplicates, and nothing surviving was skipped.
        XCTAssertEqual(Set(loaded.map(\.id)).count, loaded.count)
        let survivors = Set(seeded.map(\.id)).subtracting(victims)
        let loadedIDs = Set(loaded.map(\.id))
        XCTAssertTrue(survivors.isSubset(of: loadedIDs), "no surviving row may be skipped by the walk")
        XCTAssertLessThanOrEqual(loadedIDs.subtracting(survivors).count, 250, "only rows emitted before the delete can be stale")

        let fresh = try walk(pageSize: 1_000)
        XCTAssertEqual(Set(fresh.map(\.id)), survivors)
        XCTAssertEqual(try database.countEntries(), 1_800)
        XCTAssertEqual(fresh.filter(\.isPinned).count, 1)
    }

    func testEmptyAndSingleRowLibrariesTerminateTheWalk() throws {
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
    }
}
