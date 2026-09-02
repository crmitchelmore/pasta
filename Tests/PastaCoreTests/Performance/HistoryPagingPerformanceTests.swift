import Foundation
import GRDB
import XCTest
@testable import PastaCore

/// Full-library page walk, as `BackgroundService.refresh()` performs it on
/// launch and after every delete/prune/pin.
///
/// Both tests page the same 50k-row in-memory library in 1_000-row pages.
/// `testOffsetPagingBaseline` reproduces the old `fetchRecent(limit:offset:)`
/// loop with raw SQL so the two can be compared in one run.
///
/// Measured on an Apple Silicon laptop (average of 10 `measure` iterations,
/// 1_000-row pages). Row hydration — the Codable decode of every row, which
/// is identical for both — sets the floor: ~0.26 s for 50k rows, ~1.06 s for
/// 200k.
///
///   50k rows, in-memory:   OFFSET 0.285 s   keyset 0.283 s
///   200k rows, in-memory:  OFFSET 1.290 s   keyset 1.149 s
///   200k rows, on-disk:    OFFSET 1.276 s   keyset 1.140 s   (DatabasePool, warm)
///
/// So at 50k the walk is hydration-bound and the two are indistinguishable;
/// the OFFSET term is quadratic — Σ(i·pageSize) ≈ n²/(2·pageSize) index
/// steps, 20M at 200k — and shows up as the ~0.23 s over the floor there,
/// against ~0.09 s (200 statement preparations) for the cursor. What the
/// cursor also buys, independent of size: every page costs the same rather
/// than growing with its position (the last OFFSET page at 200k walks 199k
/// index entries; the last keyset page walks 1_000), and a copy or delete
/// landing mid-walk can no longer shift later pages so that a row is
/// repeated or skipped.
final class HistoryPagingPerformanceTests: XCTestCase {
    private static let rowCount = 50_000
    private static let pageSize = 1_000

    private static var db: DatabaseManager!

    override class func setUp() {
        super.setUp()
        db = try! DatabaseManager.inMemory()

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Bursts of equal timestamps exercise the rowid tie-break.
        let entries = (0..<rowCount).map { i in
            ClipboardEntry(
                content: "history row \(i)",
                contentType: .text,
                timestamp: base.addingTimeInterval(Double(i / 4))
            )
        }
        try! db.insertBatch(entries, deduplicate: false)
    }

    override class func tearDown() {
        db = nil
        super.tearDown()
    }

    func testKeysetPagingWalksFullLibrary() throws {
        let db = Self.db!
        var lastCount = 0

        measure {
            var loaded = 0
            var cursor: DatabaseManager.HistoryCursor? = nil
            repeat {
                let page = try! db.fetchHistoryPage(after: cursor, limit: Self.pageSize)
                loaded += page.entries.count
                cursor = page.nextCursor
            } while cursor != nil
            lastCount = loaded
        }

        XCTAssertEqual(lastCount, Self.rowCount)
    }

    /// The pre-change loop: `ORDER BY timestamp DESC LIMIT ? OFFSET ?` per page.
    func testOffsetPagingBaseline() throws {
        let db = Self.db!
        var lastCount = 0

        measure {
            var loaded = 0
            var offset = 0
            while true {
                let page: [ClipboardEntry] = try! db.dbWriter.read { conn in
                    try ClipboardEntry.fetchAll(
                        conn,
                        sql: """
                        SELECT * FROM clipboard_entries
                        ORDER BY timestamp DESC
                        LIMIT ? OFFSET ?
                        """,
                        arguments: [Self.pageSize, offset]
                    )
                }
                if page.isEmpty { break }
                loaded += page.count
                offset += page.count
            }
            lastCount = loaded
        }

        XCTAssertEqual(lastCount, Self.rowCount)
    }
}
