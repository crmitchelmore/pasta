import Foundation
import GRDB

/// Payload columns of a history row that `DatabaseManager.fetchHistoryPage`
/// left in the database because they exceeded `thresholdBytes`.
///
/// The full history stays in memory for filtering and the list, so a library
/// with multi-megabyte logs or rich-text HTML held every byte for the life of
/// the app although rows only ever show a few hundred characters. A lazy row
/// keeps a preview of its content plus byte counts; `ClipboardEntry`'s
/// `content`, `rawData` and `metadata` getters load the rest on first access,
/// so paste, copy, drag, export and detectors keep seeing the full value.
struct LazyPayload: Sendable {
    /// Columns at or below this size are fetched in full.
    static let thresholdBytes = 64 * 1024
    /// Characters kept as the preview of lazy content. A lazy column holds
    /// more than `thresholdBytes` bytes, so it has at least
    /// `thresholdBytes / 4` (16,384) characters and the preview is a strict
    /// prefix of it, longer than any inline preview shows.
    static let previewCharacters = 16_384

    /// Byte length of the full content; `nil` when content was fetched in full.
    var contentByteCount: Int?
    /// Byte length of the full raw data; `nil` when it was fetched in full.
    var rawDataByteCount: Int?
    /// Byte length of the full metadata; `nil` when it was fetched in full.
    var metadataByteCount: Int?
    /// The row's stored `contentHash`, valid while content stays lazy.
    let storedContentHash: String?
    let loader: LazyPayloadLoader

    var isEmpty: Bool { contentByteCount == nil && rawDataByteCount == nil && metadataByteCount == nil }

    static func contentMatches(_ lhs: String, _ lhsLazy: LazyPayload?, _ rhs: String, _ rhsLazy: LazyPayload?) -> Bool {
        switch (lhsLazy?.contentByteCount, rhsLazy?.contentByteCount) {
        case (nil, nil):
            return lhs == rhs
        case let (lhsCount?, rhsCount?):
            guard lhsCount == rhsCount, lhs == rhs else { return false }
            if lhsLazy!.loader === rhsLazy!.loader { return true }
            return lhsLazy!.storedContentHash == rhsLazy!.storedContentHash
        case let (lazyCount?, nil):
            return rhs.utf8.count == lazyCount && rhs.utf8.starts(with: lhs.utf8)
        case let (nil, lazyCount?):
            return lhs.utf8.count == lazyCount && lhs.utf8.starts(with: rhs.utf8)
        }
    }

    static func columnMatches<Value: Equatable>(
        _ lhs: Value?, _ lhsLazy: LazyPayload?, _ column: KeyPath<LazyPayload, Int?>,
        _ rhs: Value?, _ rhsLazy: LazyPayload?, byteCount: KeyPath<Value, Int>
    ) -> Bool {
        switch (lhsLazy?[keyPath: column], rhsLazy?[keyPath: column]) {
        case (nil, nil):
            return lhs == rhs
        case let (lhsCount?, rhsCount?):
            return lhsCount == rhsCount
        case let (lazyCount?, nil):
            return rhs?[keyPath: byteCount] == lazyCount
        case let (nil, lazyCount?):
            return lhs?[keyPath: byteCount] == lazyCount
        }
    }
}

/// Loads and caches one row's lazy payload columns. Shared by every copy of
/// the entry; thread-safe.
final class LazyPayloadLoader: @unchecked Sendable {
    private enum PayloadColumn: String {
        case content, rawData, metadata
    }

    private let reader: any DatabaseReader
    /// The row's stored `id` value, matched verbatim.
    private let key: DatabaseValue
    private let lock = NSLock()
    private var cache: [PayloadColumn: DatabaseValue] = [:]

    init(reader: any DatabaseReader, key: DatabaseValue) {
        self.reader = reader
        self.key = key
    }

    /// Thrown when the row is gone or unreadable. Property getters fall back
    /// to the preview; persistence and export rethrow so a truncated preview
    /// is never written back or exported as the entry's content.
    struct LoadError: Error, CustomStringConvertible {
        let column: String
        let reason: String
        var description: String { "Lazy \(column) load failed: \(reason)" }
    }

    func content() throws -> String {
        guard let content = String.fromDatabaseValue(try load(.content)) else {
            throw LoadError(column: PayloadColumn.content.rawValue, reason: "not text")
        }
        return content
    }
    func rawData() throws -> Data? { Data.fromDatabaseValue(try load(.rawData)) }
    func metadata() throws -> String? { String.fromDatabaseValue(try load(.metadata)) }

    func hasLoaded(_ payload: LazyPayload) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (payload.contentByteCount == nil || cache[.content] != nil)
            && (payload.rawDataByteCount == nil || cache[.rawData] != nil)
            && (payload.metadataByteCount == nil || cache[.metadata] != nil)
    }

    private func load(_ column: PayloadColumn) throws -> DatabaseValue {
        lock.lock()
        if let cached = cache[column] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Read without holding the lock: a thread inside a database access
        // that touches this entry must not wait on a reader that is in turn
        // waiting for that access. Reentrant so getters work inside
        // `read`/`write` closures (e.g. reclassification snapshot checks).
        let value: DatabaseValue
        do {
            guard let row = try reader.unsafeReentrantRead({ db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT \(column.rawValue) FROM \(ClipboardEntry.databaseTableName) WHERE id = ?",
                    arguments: [key]
                )
            }) else {
                throw LoadError(column: column.rawValue, reason: "row deleted")
            }
            value = row[0]
        } catch {
            PastaLogger.database.error("\(PastaLogger.diagnosticDescription(error))")
            throw error
        }

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[column] { return cached }
        cache[column] = value
        return value
    }
}
