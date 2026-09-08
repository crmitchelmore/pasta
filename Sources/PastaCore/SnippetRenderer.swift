import Foundation

/// Reads the current saved template and only the history required by its
/// placeholders. Rendering is performed at activation, never in search rows.
public struct SnippetRenderer {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    public func render(id: UUID, clipboardText: String?, now: Date = Date()) throws -> SnippetEvaluation? {
        guard let snippet = try SnippetStore(database: database).get(id: id) else { return nil }
        let regex = try NSRegularExpression(pattern: #"\{\s*clipboard\s*:\s*([0-9]+)\s*\}"#, options: .caseInsensitive)
        let ns = snippet.content as NSString
        let offset = regex.matches(in: snippet.content, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }.max() ?? 0
        let history = offset > 0 ? try database.fetchRecent(limit: offset).map(\.content) : []
        return SnippetPlaceholderEvaluator(now: { now }, clipboardText: { clipboardText }, history: { history })
            .evaluate(snippet.content)
    }
}
