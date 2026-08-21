import Foundation

/// Pure helpers describing the in-memory window of clipboard history that the
/// app pages in incrementally.
///
/// They live here rather than inline in the app layer so the paging invariants
/// can be unit-tested: `PastaApp` is an executable target with no test target
/// of its own.
public enum HistoryWindow {
    /// Merges a freshly-fetched head page in front of the currently displayed
    /// entries, de-duplicating by ID and capping the result at `limit`.
    ///
    /// Head order wins, so newly captured entries appear at the top without
    /// discarding the pages already loaded below them.
    public static func merge(
        head: [ClipboardEntry],
        into current: [ClipboardEntry],
        limit: Int
    ) -> [ClipboardEntry] {
        guard limit > 0 else { return [] }

        var seen = Set<UUID>()
        var merged: [ClipboardEntry] = []
        merged.reserveCapacity(min(limit, head.count + current.count))

        for entry in head {
            guard seen.insert(entry.id).inserted else { continue }
            merged.append(entry)
            if merged.count >= limit { return merged }
        }

        for entry in current {
            guard seen.insert(entry.id).inserted else { continue }
            merged.append(entry)
            if merged.count >= limit { break }
        }

        return merged
    }

    // NOTE: there is deliberately no "is the window fully loaded" helper that
    // infers completeness from counts. After a delete, the head-merged interim
    // window can hold MORE rows than the fresh library total (merge only
    // unions; stale rows leave when the paged reload finishes), so
    // `loadedCount >= total` misreads exactly the state that most needs a
    // resumed reload. BackgroundService tracks an explicit
    // paging-completeness flag instead.
}
