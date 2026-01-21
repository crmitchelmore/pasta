import Foundation
import Fuse
import os.log

public final class SearchService {
    public struct Match: Sendable {
        public let entry: ClipboardEntry
        /// Lower is better. Exact matches get score of 0, fuzzy matches use Fuse's score.
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
    private let fuse: Fuse

    public init(database: DatabaseManager, fuse: Fuse = Fuse(tokenize: true)) {
        self.database = database
        self.fuse = fuse
    }

    /// Unified search that prioritizes exact matches, then fuzzy matches.
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

        PastaLogger.search.debug("Searching for '\(trimmed)' contentType=\(String(describing: contentType)) limit=\(limit)")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Fetch candidates
        let candidates = try database.fetchRecent(contentType: contentType, limit: max(limit * 5, 500))
        
        let lowerQuery = trimmed.lowercased()
        var exactMatches: [Match] = []
        var containsMatches: [Match] = []
        var fuzzyMatches: [Match] = []
        
        let pattern = fuse.createPattern(from: trimmed)
        
        for entry in candidates {
            let lowerContent = entry.content.lowercased()
            
            // Check for exact match (content equals query)
            if lowerContent == lowerQuery {
                let ranges = Self.matchRanges(of: trimmed, in: entry.content)
                exactMatches.append(Match(entry: entry, score: 0.0, ranges: ranges, isExactMatch: true))
                continue
            }
            
            // Check for contains match (query is substring)
            if lowerContent.contains(lowerQuery) {
                let ranges = Self.matchRanges(of: trimmed, in: entry.content)
                // Score based on how much of the content the match covers
                let coverage = Double(trimmed.count) / Double(entry.content.count)
                let score = 0.1 + (1.0 - coverage) * 0.2 // Range: 0.1 to 0.3
                containsMatches.append(Match(entry: entry, score: score, ranges: ranges, isExactMatch: false))
                continue
            }
            
            // Try fuzzy match
            if let result = fuse.search(pattern, in: entry.content) {
                // Only include reasonably good fuzzy matches
                if result.score <= 0.6 {
                    fuzzyMatches.append(Match(entry: entry, score: 0.4 + result.score, ranges: result.ranges, isExactMatch: false))
                }
            }
        }
        
        // Sort each group and combine
        exactMatches.sort { $0.entry.timestamp > $1.entry.timestamp }
        containsMatches.sort { $0.score < $1.score }
        fuzzyMatches.sort { $0.score < $1.score }
        
        var results: [Match] = []
        results.append(contentsOf: exactMatches)
        results.append(contentsOf: containsMatches)
        results.append(contentsOf: fuzzyMatches)
        
        let limited = Array(results.prefix(limit))
        
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        PastaLogger.search.info("Search completed: \(limited.count) results (\(exactMatches.count) exact, \(containsMatches.count) contains, \(fuzzyMatches.count) fuzzy) in \(String(format: "%.1f", elapsed))ms")
        
        return limited
    }

    private static func matchRanges(of needle: String, in haystack: String) -> [CountableClosedRange<Int>] {
        let lowerHaystack = haystack.lowercased()
        let lowerNeedle = needle.lowercased()

        guard !lowerNeedle.isEmpty else { return [] }

        var ranges: [CountableClosedRange<Int>] = []
        var searchStart = lowerHaystack.startIndex

        while let found = lowerHaystack.range(of: lowerNeedle, range: searchStart..<lowerHaystack.endIndex) {
            let start = lowerHaystack.distance(from: lowerHaystack.startIndex, to: found.lowerBound)
            let end = start + lowerNeedle.count - 1
            if end >= start {
                ranges.append(start...end)
            }
            searchStart = found.upperBound
        }

        return ranges
    }
}
