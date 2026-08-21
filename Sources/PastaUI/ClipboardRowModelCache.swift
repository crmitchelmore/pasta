import Foundation
import PastaCore

/// Memoizes `ClipboardRowData` per entry.
///
/// `ClipboardListView` rebuilds its row array on every body evaluation (every
/// keystroke, selection change, …), and `ClipboardRowData.init` does
/// O(content-length) string work per row. Deriving each row once per entry
/// *version* and reusing it makes body evaluations O(rows) pointer copies.
///
/// The change token covers every `ClipboardEntry` field the row reads except
/// `content`, which is immutable for a given id (dedup bumps surface as
/// `copyCount`/`timestamp` changes; reclassification as `contentType`/
/// `metadata` changes).
///
/// Not thread-safe: confine to the main actor (SwiftUI body evaluations).
final class ClipboardRowModelCache {
    private var rowsByID: [UUID: (token: Int, row: ClipboardRowData)] = [:]

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
        let token = Self.changeToken(for: entry)
        if let cached = rowsByID[entry.id], cached.token == token {
            return cached.row
        }
        let row = ClipboardRowData(from: entry)
        rowsByID[entry.id] = (token, row)
        return row
    }

    /// Test hook.
    var cachedRowCountForTesting: Int { rowsByID.count }

    private func pruneIfNeeded(keeping entries: [ClipboardEntry]) {
        // Let the cache keep rows for entries that briefly left the display
        // (e.g. while a search narrows the list) but stop it growing without
        // bound across many distinct searches.
        guard rowsByID.count > max(entries.count * 2, 400) else { return }
        let liveIDs = Set(entries.map(\.id))
        rowsByID = rowsByID.filter { liveIDs.contains($0.key) }
    }

    static func changeToken(for entry: ClipboardEntry) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.id)
        hasher.combine(entry.contentType.rawValue)
        hasher.combine(entry.sourceApp)
        hasher.combine(entry.timestamp)
        hasher.combine(entry.copyCount)
        hasher.combine(entry.isSynced)
        hasher.combine(entry.isPinned)
        hasher.combine(entry.imagePath)
        hasher.combine(entry.parentEntryId)
        hasher.combine(entry.metadata)
        return hasher.finalize()
    }
}
