import Foundation
import PastaCore

/// Memoizes `ClipboardRowData` per entry.
///
/// `ClipboardListView` rebuilds its row array on every body evaluation (every
/// keystroke, selection change, …), and `ClipboardRowData.init` does
/// O(content-length) string work per row. Deriving each row once per entry
/// *value* and reusing it makes body evaluations O(rows) pointer copies.
///
/// Freshness is decided by comparing the whole cached `ClipboardEntry` with
/// `==` (synthesized memberwise equality) — no hand-maintained field list to
/// drift out of sync with what `ClipboardRowData` reads. On keystroke-driven
/// re-renders the entry's strings share copy-on-write storage with the cached
/// copy, so the comparison takes the pointer-equality fast path; the cached
/// entry is refreshed on every hit to keep that fast path once new storage
/// appears (e.g. after a refresh re-fetch).
///
/// Not thread-safe: confine to the main actor (SwiftUI body evaluations).
final class ClipboardRowModelCache {
    private var rowsByID: [UUID: (entry: ClipboardEntry, row: ClipboardRowData)] = [:]

    /// Test hooks.
    var cachedRowCountForTesting: Int { rowsByID.count }
    private(set) var rowBuildCountForTesting = 0

    /// Returns row models for `entries` in order, reusing cached rows whose
    /// entry is unchanged, and pruning cache slots for entries that are no
    /// longer displayed.
    func rows(for entries: [ClipboardEntry]) -> [ClipboardRowData] {
        var result: [ClipboardRowData] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            result.append(row(for: entry))
        }
        pruneIfNeeded(keeping: entries)
        return result
    }

    func row(for entry: ClipboardEntry) -> ClipboardRowData {
        if let cached = rowsByID[entry.id], cached.entry == entry {
            // Adopt the caller's instance so future comparisons against the
            // same array hit the COW pointer fast path instead of re-walking
            // string contents.
            rowsByID[entry.id] = (entry, cached.row)
            return cached.row
        }
        let row = ClipboardRowData(from: entry)
        rowBuildCountForTesting += 1
        rowsByID[entry.id] = (entry, row)
        return row
    }

    private func pruneIfNeeded(keeping entries: [ClipboardEntry]) {
        // Let the cache keep rows for entries that briefly left the display
        // (e.g. while a search narrows the list) but stop it growing without
        // bound across many distinct searches.
        guard rowsByID.count > max(entries.count * 2, 400) else { return }
        let liveIDs = Set(entries.map(\.id))
        rowsByID = rowsByID.filter { liveIDs.contains($0.key) }
    }
}
