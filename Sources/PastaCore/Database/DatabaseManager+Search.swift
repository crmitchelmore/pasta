import Foundation
import GRDB
import SQLite3

extension DatabaseManager {
    /// Coefficient applied to `ln(1 + copyCount)` in the FTS5 ranking score.
    /// Frequently-pasted entries should rank higher.
    fileprivate static let copyCountBonusCoefficient: Double = 0.3

    /// Bonus applied when an entry's content equals the trimmed query
    /// (case-insensitive). Large enough to dominate BM25 + recency.
    fileprivate static let exactEqualityBonus: Double = 10.0

    /// `octet_length` (SQLite 3.43+) reads a column's stored size without
    /// loading its value. Checking it first stops the exact-equality test from
    /// reading and lower-casing every long matching entry, which doubled rank
    /// time when long entries matched. Older SQLite keeps the unguarded check.
    fileprivate static let supportsOctetLength = sqlite3_libversion_number() >= 3_043_000

    /// Leading and trailing spaces that `TRIM` may strip from an otherwise
    /// exact-equal entry. Entries padded beyond this lose only the bonus.
    fileprivate static let exactEqualityPaddingBytes = 1024

    public func search(query: String, limit: Int = 50) throws -> [ClipboardEntry] {
        let pattern = "%\(query)%"
        return try dbWriter.read { db in
            try ClipboardEntry
                .filter(Column("content").like(pattern))
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Fast full-text search using FTS5 with prefix matching support.
    /// This is the primary search method - uses SQLite's optimized FTS5 engine.
    ///
    /// - Parameters:
    ///   - query: Search query (supports multiple words, each gets prefix matching)
    ///   - contentType: Optional filter by content type
    ///   - limit: Maximum results to return
    /// - Returns: Matching entries ordered by combined relevance + recency + popularity
    public func searchFTS(query: String, contentType: ContentType?, limit: Int = 50, pinnedOnly: Bool = false, mixedOnly: Bool = false) throws -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let ftsQuery = buildFTSQuery(from: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        // Pre-normalised form used for the SQL exact-equality boost.
        let normalisedExact = trimmed.lowercased()

        let exactLengthGuard = Self.supportsOctetLength ? "octet_length(e.content) <= ? AND " : ""

        return try dbWriter.read { db in
            // Two-stage query: rank rowids inside the FTS5 virtual table first
            // (touching only the FTS index + the small `content`/`contentType`
            // columns needed for the rank + filters), then hydrate the top
            // `limit` rows from the main table. This avoids reading the
            // potentially-large `rawData` BLOB and other ClipboardEntry fields
            // for every FTS match before sorting and trimming.
            var rankSQL = """
            SELECT clipboard_entries_fts.rowid AS rid,
                   bm25(clipboard_entries_fts)
                   + \(Self.recencyPenaltyCoefficient) * ln(1.0 + max(julianday('now') - julianday(e.timestamp), 0.0))
                   - \(Self.copyCountBonusCoefficient) * ln(1.0 + e.copyCount)
                   + (CASE WHEN \(exactLengthGuard)LOWER(TRIM(e.content)) = ? THEN -\(Self.exactEqualityBonus) ELSE 0.0 END)
                   AS rank
            FROM clipboard_entries_fts
            JOIN \(ClipboardEntry.databaseTableName) e ON e.rowid = clipboard_entries_fts.rowid
            WHERE clipboard_entries_fts MATCH ?
            """

            var rankArgs: [DatabaseValueConvertible] = []
            if Self.supportsOctetLength {
                // SQLite's LOWER only folds ASCII, so it preserves byte length.
                rankArgs.append(normalisedExact.utf8.count + Self.exactEqualityPaddingBytes)
            }
            rankArgs += [normalisedExact, ftsQuery]

            if let contentType {
                rankSQL += " AND e.contentType = ?"
                rankArgs.append(contentType.rawValue)
            }

            if pinnedOnly {
                rankSQL += " AND e.isPinned = 1"
            }
            if mixedOnly {
                rankSQL += " AND e.parentEntryId IS NULL AND (e.contentTypeMask & ?) != 0"
                rankArgs.append(ContentTypeMask.mixed.rawValue)
            }

            rankSQL += " ORDER BY rank ASC LIMIT ?"
            rankArgs.append(limit)

            let sql = """
            WITH ranked AS (\(rankSQL))
            SELECT e.*
            FROM ranked
            JOIN \(ClipboardEntry.databaseTableName) e ON e.rowid = ranked.rid
            ORDER BY ranked.rank ASC
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(rankArgs))
            return rows.compactMap { row in
                try? ClipboardEntry(row: row)
            }
        }
    }

    /// Builds an FTS5 MATCH query string with prefix matching.
    /// Punctuation is replaced with whitespace so e.g. "github.com" becomes
    /// the two-token query "github* com*", and FTS5-special characters that
    /// would otherwise change query semantics are stripped.
    fileprivate func buildFTSQuery(from input: String) -> String {
        // Punctuation that should split a token. Default unicode61 tokenizer
        // also splits on these, so re-tokenising the query the same way avoids
        // surprises with terms like `github.com`, `foo@bar`, `path/to/file`.
        let splitters: Set<Character> = [
            ".", ",", ";", "/", "\\", "@", "#", "&", "|",
            "!", "?", "<", ">", "=", "[", "]", "{", "}",
            "\"", "*", "-", "+", "(", ")", ":", "^", "~", "'", "`"
        ]

        let normalised = String(input.map { splitters.contains($0) ? " " : $0 })

        let words = normalised
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return "" }
        // User input is literal text, never FTS syntax. Quoting also handles
        // punctuation outside the splitter list (such as $ and %) and words
        // like AND/OR/NOT. Keep * outside the quotes to retain prefix matching.
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }
}
