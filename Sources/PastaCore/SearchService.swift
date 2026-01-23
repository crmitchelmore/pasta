import Foundation
import os.log

/// Fast search service using SQLite FTS5 for instant results.
/// FTS5 runs in SQLite's optimized C engine - sub-10ms for 10k+ entries.
public final class SearchService {
    public struct Match: Sendable {
        public let entry: ClipboardEntry
        /// Lower is better. FTS5 bm25 rank converted to 0-1 score.
        public let score: Double
        public let ranges: [CountableClosedRange<Int>]
        public let isExactMatch: Bool
        
        public init(entry: ClipboardEntry, score: Double, ranges: [CountableClosedRange<Int>], isExactMatch: Bool = false) {
            self.entry = entry
            self.score = score
            self.ranges = ranges
            self.isExactMatch = isExactMatch
        }
    }

    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// Fast FTS5-based search that returns results in milliseconds.
    public func search(
        query: String,
        contentType: ContentType? = nil,
        limit: Int = 50
    ) throws -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            PastaLogger.search.debug("Search skipped: empty query")
            return []
        }

        PastaLogger.search.debug("FTS5 search for '\(trimmed)' contentType=\(String(describing: contentType)) limit=\(limit)")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Use FTS5 for blazing fast search
        let entries = try database.searchFTS(query: trimmed, contentType: contentType, limit: limit)
        
        // Convert to Match objects (skip expensive range computation - not needed for display)
        let results: [Match] = entries.enumerated().map { index, entry in
            Match(entry: entry, score: Double(index) * 0.01, ranges: [], isExactMatch: false)
        }
        
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        PastaLogger.search.info("FTS5 search completed: \(results.count) results in \(String(format: "%.1f", elapsed))ms")
        
        return results
    }
}
