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

    /// Whether a delete can be mirrored by dropping rows from the in-memory
    /// window instead of re-paging the whole library.
    ///
    /// Only when the last paged load finished, nothing else is reloading, and
    /// the window holds the entire library (fewer rows than `limit`): with a
    /// capped window, deleting a row should pull the next-oldest row into view,
    /// and only the database knows which one that is.
    public static func canApplyLocalRemoval(
        loadedCount: Int,
        limit: Int,
        isPagingComplete: Bool,
        isRefreshing: Bool
    ) -> Bool {
        isPagingComplete && !isRefreshing && loadedCount < limit
    }

    /// Whether existing rows can be updated in place (pin or sync state).
    /// History is ordered by `(timestamp, rowid)`, so these changes never move
    /// or add rows; it is only unsafe while a reload is in flight, whose final
    /// assignment could carry the pre-change row back in.
    public static func canUpdateRowsInPlace(isPagingComplete: Bool, isRefreshing: Bool) -> Bool {
        isPagingComplete && !isRefreshing
    }

    /// `current` without the rows in `ids`, order preserved.
    public static func removing(ids: Set<UUID>, from current: [ClipboardEntry]) -> [ClipboardEntry] {
        guard !ids.isEmpty else { return current }
        return current.filter { !ids.contains($0.id) }
    }

    /// `current` with the row `id` re-flagged as `pinned`; `nil` when the row
    /// is not in the window or already has that state (nothing to publish).
    public static func settingPinned(
        _ pinned: Bool,
        id: UUID,
        in current: [ClipboardEntry]
    ) -> [ClipboardEntry]? {
        guard let index = current.firstIndex(where: { $0.id == id }),
              current[index].isPinned != pinned else { return nil }
        var updated = current
        updated[index].isPinned = pinned
        return updated
    }

    /// `current` with each of `rows` swapped in for the row with the same ID,
    /// positions unchanged; `nil` when no row in the window actually differs.
    /// Rows not in the window are ignored.
    public static func replacing(_ rows: [ClipboardEntry], in current: [ClipboardEntry]) -> [ClipboardEntry]? {
        guard !rows.isEmpty else { return nil }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var updated = current
        var changed = false
        var remaining = byID.count
        for index in updated.indices where remaining > 0 {
            guard let row = byID[updated[index].id] else { continue }
            remaining -= 1
            guard row != updated[index] else { continue }
            updated[index] = row
            changed = true
        }
        return changed ? updated : nil
    }

    /// What re-read database rows mean for the window, short of reloading it.
    public enum RowChange: Equatable {
        /// The window already shows these rows exactly as stored.
        case unchanged
        /// The window with changed rows swapped in place and removed rows dropped.
        case updated([ClipboardEntry])
        /// A change only a reload can place: a row the window does not hold,
        /// a moved sort key, or a removal that may not be applied locally.
        case needsReload
    }

    /// Applies fresh copies of `rows`, and the disappearance of `removedIDs`,
    /// to `current` without re-paging the library.
    ///
    /// A row the window does not hold could be new and belong anywhere, and a
    /// changed timestamp moves a row, so both need a reload. Removed IDs the
    /// window does not show change nothing visible. A removed row that is
    /// shown is dropped only when `canRemoveLocally` (see
    /// `canApplyLocalRemoval`); a capped window must refill from the database.
    public static func applying(
        changedRows rows: [ClipboardEntry],
        removedIDs: Set<UUID>,
        to current: [ClipboardEntry],
        canRemoveLocally: Bool
    ) -> RowChange {
        var pending = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var removing = removedIDs.subtracting(pending.keys)
        guard !pending.isEmpty || !removing.isEmpty else { return .unchanged }

        var updated = current
        var dropped = Set<UUID>()
        var changed = false
        for index in updated.indices {
            if pending.isEmpty && removing.isEmpty { break }
            let id = updated[index].id
            if let row = pending.removeValue(forKey: id) {
                guard row.timestamp == updated[index].timestamp else { return .needsReload }
                if row != updated[index] {
                    updated[index] = row
                    changed = true
                }
            } else if removing.remove(id) != nil {
                guard canRemoveLocally else { return .needsReload }
                dropped.insert(id)
            }
        }
        guard pending.isEmpty else { return .needsReload }
        if !dropped.isEmpty {
            updated.removeAll { dropped.contains($0.id) }
            changed = true
        }
        return changed ? .updated(updated) : .unchanged
    }

    // NOTE: there is deliberately no "is the window fully loaded" helper that
    // infers completeness from counts. After a delete, the head-merged interim
    // window can hold MORE rows than the fresh library total (merge only
    // unions; stale rows leave when the paged reload finishes), so
    // `loadedCount >= total` misreads exactly the state that most needs a
    // resumed reload. BackgroundService tracks an explicit
    // paging-completeness flag instead.
}
