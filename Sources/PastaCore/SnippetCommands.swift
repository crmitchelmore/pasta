import Foundation

/// The explicit !snippet picker uses the existing keyboard command surface.
/// Keywords are searchable aliases; automatic expansion is separately opt-in.
public enum SnippetCommands {
    public static func searchQuery(_ commandQuery: String) -> String? {
        let parts = commandQuery.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let name = parts.first, ["snippet", "snippets"].contains(name.lowercased()) else { return nil }
        return parts.count > 1 ? String(parts[1]) : ""
    }

    public static func commands(for snippets: [Snippet]) -> [Command] {
        snippets.map { snippet in
            Command(id: "snippet-\(snippet.id)", trigger: snippet.name.isEmpty ? "Untitled snippet" : snippet.name,
                    description: snippet.keyword.map { "Paste snippet · \($0)" } ?? "Paste snippet",
                    icon: "text.badge.plus", category: .utility) { .pasteSnippet(snippet.id) }
        }
    }
}
