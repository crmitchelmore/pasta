import Foundation
import Fuse

public final class SearchService {
    public enum Mode {
        case exact
        case fuzzy
    }

    public struct Match: Sendable {
        public let entry: ClipboardEntry
        /// Lower is better. For exact search this is the SQLite bm25 rank; for fuzzy search this is Fuse's score.
        public let score: Double
        public let ranges: [CountableClosedRange<Int>]
    }

    private let database: DatabaseManager
    private let fuse: Fuse

    public init(database: DatabaseManager, fuse: Fuse = Fuse(tokenize: true)) {
        self.database = database
        self.fuse = fuse
    }

    public func search(
        query: String,
        mode: Mode,
        contentType: ContentType? = nil,
        limit: Int = 50
    ) throws -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        switch mode {
        case .exact:
            let ranked = try database.searchExact(query: trimmed, contentType: contentType, limit: limit)
            return ranked.map { entry, rank in
                Match(entry: entry, score: rank, ranges: Self.matchRanges(of: trimmed, in: entry.content))
            }
        case .fuzzy:
            let candidates = try database.fetchRecent(contentType: contentType, limit: max(limit, 250))
            let pattern = fuse.createPattern(from: trimmed)

            let matches: [Match] = candidates.compactMap { entry in
                guard let result = fuse.search(pattern, in: entry.content) else {
                    return nil
                }
                return Match(entry: entry, score: result.score, ranges: result.ranges)
            }

            let sorted = matches.sorted { $0.score < $1.score }
            guard let best = sorted.first else {
                return []
            }

            // Fuse can return weak matches for unrelated strings; filter to “close to best”.
            // Lower scores are better. Keep it conservative but always include the best match.
            let maxScore = max(best.score, min(0.4, best.score * 1.5))

            return sorted
                .filter { $0.score <= maxScore }
                .prefix(limit)
                .map { $0 }
        }
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
