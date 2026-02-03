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
        var entries = try database.searchFTS(query: trimmed, contentType: contentType, limit: limit)
        if entries.isEmpty, let relaxed = relaxedQuery(from: trimmed) {
            entries = try database.searchFTS(query: relaxed, contentType: contentType, limit: limit)
        }
        
        // Convert to Match objects (FTS5 already returns results ranked by BM25 relevance)
        let normalizedQuery = trimmed.lowercased()
        let results: [Match] = entries.enumerated().map { index, entry in
            let isExactMatch = entry.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedQuery
            let ranges = matchRanges(in: entry.content, query: trimmed)
            return Match(entry: entry, score: Double(index) * 0.01, ranges: ranges, isExactMatch: isExactMatch)
        }
        
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        PastaLogger.search.info("FTS5 search completed: \(results.count) results in \(String(format: "%.1f", elapsed))ms")
        
        return results
    }

    private func relaxedQuery(from query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        guard words.contains(where: { $0.count >= 4 }) else { return nil }

        let relaxed = words.map { word -> String in
            guard word.count >= 4 else { return String(word) }
            return String(word.dropLast())
        }.joined(separator: " ")

        return relaxed == query ? nil : relaxed
    }

    private func matchRanges(in content: String, query: String) -> [CountableClosedRange<Int>] {
        let lowerContent = content.lowercased()
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return [] }

        var ranges: [CountableClosedRange<Int>] = []
        for term in terms {
            guard let range = lowerContent.range(of: term) else { continue }
            let start = lowerContent.distance(from: lowerContent.startIndex, to: range.lowerBound)
            let end = lowerContent.distance(from: lowerContent.startIndex, to: range.upperBound) - 1
            if start <= end {
                ranges.append(start...end)
            }
        }
        return ranges
    }
}
