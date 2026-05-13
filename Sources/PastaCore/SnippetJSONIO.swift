import Foundation

/// JSON import / export helpers for `[Snippet]`.
///
/// The on-disk format is a plain JSON array of `Snippet` objects, encoded
/// with `.iso8601` dates so files round-trip cleanly between machines.
public enum SnippetJSONIO {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ snippets: [Snippet]) throws -> Data {
        try makeEncoder().encode(snippets)
    }

    public static func decode(_ data: Data) throws -> [Snippet] {
        try makeDecoder().decode([Snippet].self, from: data)
    }

    public struct ImportSummary: Equatable, Sendable {
        public var inserted: Int
        public var updated: Int
        public var total: Int { inserted + updated }
        public init(inserted: Int = 0, updated: Int = 0) {
            self.inserted = inserted
            self.updated = updated
        }
    }

    /// Imports snippets into the given store, deduplicating by id (existing
    /// rows with the same id are replaced).
    @discardableResult
    public static func importSnippets(_ snippets: [Snippet], into store: SnippetStore) throws -> ImportSummary {
        var summary = ImportSummary()
        for snippet in snippets {
            if try store.get(id: snippet.id) != nil {
                _ = try store.upsert(snippet)
                summary.updated += 1
            } else {
                _ = try store.upsert(snippet)
                summary.inserted += 1
            }
        }
        return summary
    }
}
