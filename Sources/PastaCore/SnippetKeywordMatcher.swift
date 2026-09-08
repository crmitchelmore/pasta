import Foundation

/// Bounded, transient input state. No full keystroke history is retained.
/// Only an exact keyword followed by whitespace requests expansion.
public struct SnippetKeywordMatcher {
    public private(set) var token = ""
    private var overflowed = false
    public init() {}
    public mutating func reset() { token = ""; overflowed = false }

    public mutating func consume(_ characters: String, snippets: [Snippet]) -> (id: UUID, deleteCount: Int)? {
        guard !characters.isEmpty else { reset(); return nil }
        if characters == "\u{7f}" { if !overflowed, !token.isEmpty { token.removeLast() }; return nil }
        if characters.count == 1, characters.first?.isWhitespace == true {
            defer { reset() }
            guard characters == " ", !overflowed, !token.isEmpty else { return nil }
            let matches = snippets.filter { $0.keyword == token }
            // Ambiguous keywords never select an arbitrary template.
            guard matches.count == 1 else { return nil }
            return (matches[0].id, token.count + 1)
        }
        guard characters.allSatisfy({ !$0.isWhitespace && !$0.isNewline }),
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            reset(); return nil
        }
        guard !overflowed else { return nil }
        token.append(characters)
        if token.count > 128 { token = ""; overflowed = true }
        return nil
    }
}

public extension Notification.Name {
    static let openSnippetPicker = Notification.Name("pasta.openSnippetPicker")
    static let snippetsDidChange = Notification.Name("pasta.snippetsDidChange")
}
