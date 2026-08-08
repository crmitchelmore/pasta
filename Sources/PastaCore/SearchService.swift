import Foundation
import os.log

/// Fast search service using SQLite FTS5 for instant results.
/// FTS5 runs in SQLite's optimized C engine - sub-10ms for 10k+ entries.
public final class SearchService: @unchecked Sendable {
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
        limit: Int = 50,
        pinnedOnly: Bool = false
    ) throws -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            PastaLogger.search.debug("Search skipped: empty query")
            return []
        }

        PastaLogger.search.debug("FTS5 search for '\(trimmed)' contentType=\(String(describing: contentType)) limit=\(limit) pinnedOnly=\(pinnedOnly)")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Use FTS5 for blazing fast search
        var entries = try database.searchFTS(query: trimmed, contentType: contentType, limit: limit, pinnedOnly: pinnedOnly)
        if entries.isEmpty, let relaxed = relaxedQuery(from: trimmed) {
            entries = try database.searchFTS(query: relaxed, contentType: contentType, limit: limit, pinnedOnly: pinnedOnly)
        }
        
        // Convert to Match objects. FTS5 already returns results in our combined
        // ranking order (BM25 + recency penalty - copyCount bonus + exact-equality
        // bonus), so we preserve that ordering and only annotate metadata.
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
        // Tokenise the query, then locate each term in the content using
        // case-insensitive substring search. Avoids allocating a `lowercased()`
        // copy of the (potentially large) content/query strings on every result.
        //
        // Offsets are returned as **UTF-16 code-unit** distances so the
        // ranges line up with `NSAttributedString` / `NSRange` highlighting
        // APIs (which is what AppKit/SwiftUI text renderers consume). Using
        // Character distances here would silently desync highlights for any
        // content containing astral-plane characters (emoji, combining marks).
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return [] }

        let contentUTF16 = content.utf16
        let utf16Start = contentUTF16.startIndex

        var ranges: [CountableClosedRange<Int>] = []
        ranges.reserveCapacity(terms.count)

        for term in terms {
            guard let range = content.range(of: term, options: .caseInsensitive) else { continue }
            let lower = range.lowerBound.samePosition(in: contentUTF16) ?? range.lowerBound
            let upper = range.upperBound.samePosition(in: contentUTF16) ?? range.upperBound
            let start = contentUTF16.distance(from: utf16Start, to: lower)
            let end = contentUTF16.distance(from: utf16Start, to: upper) - 1
            if start <= end {
                ranges.append(start...end)
            }
        }
        return ranges
    }
}
