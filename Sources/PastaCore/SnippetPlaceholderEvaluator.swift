import Foundation

/// Result of evaluating a snippet template.
public struct SnippetEvaluation: Equatable {
    public var text: String
    /// Character offset of the `{cursor}` marker in the rendered text, or
    /// nil if the template did not contain `{cursor}`. Counted in
    /// `String.count` (extended grapheme clusters), matching the offset
    /// used when constructing the text. v1 only records this; the panel
    /// pastes the full text and does not move the user's cursor.
    public var cursorOffset: Int?

    public init(text: String, cursorOffset: Int? = nil) {
        self.text = text
        self.cursorOffset = cursorOffset
    }
}

/// Evaluates `{placeholder}` tokens in snippet templates.
///
/// Supported placeholders:
///   - `{date}` / `{time}` / `{datetime}` — locale-default formatted
///   - `{date:FORMAT}` / `{time:FORMAT}` / `{datetime:FORMAT}` —
///     custom `DateFormatter` patterns (e.g. `{date:yyyy-MM-dd}`).
///   - `{clipboard}` — current system clipboard text (or empty if none)
///   - `{clipboard:N}` — the Nth historical clipboard entry, **1-based**:
///     `{clipboard:1}` is the most recent entry, `{clipboard:2}` the one
///     before, and so on. Out-of-range indices render as empty string.
///   - `{cursor}` — marker for the desired final cursor position;
///     replaced with empty string in the rendered text but its offset is
///     reported via `SnippetEvaluation.cursorOffset`. Only the first
///     `{cursor}` is recorded; subsequent ones are also stripped.
///   - `{uuid}` — a freshly generated UUID
///
/// Any unknown token (e.g. `{foo}`) is left as-is so users can include
/// literal braces, and so future tokens degrade gracefully.
public struct SnippetPlaceholderEvaluator {
    private let now: () -> Date
    private let clipboardText: () -> String?
    private let history: () -> [String]
    private let uuidProvider: () -> UUID
    private let timeZone: TimeZone

    public init(
        now: @escaping () -> Date = Date.init,
        clipboardText: @escaping () -> String? = { nil },
        history: @escaping () -> [String] = { [] },
        uuidProvider: @escaping () -> UUID = UUID.init,
        timeZone: TimeZone = .current
    ) {
        self.now = now
        self.clipboardText = clipboardText
        self.history = history
        self.uuidProvider = uuidProvider
        self.timeZone = timeZone
    }

    public func evaluate(_ template: String) -> SnippetEvaluation {
        var output = ""
        output.reserveCapacity(template.count)
        var cursorOffset: Int? = nil

        let chars = Array(template)
        var index = 0

        while index < chars.count {
            let ch = chars[index]
            if ch == "{", let closeOffset = findClosingBrace(in: chars, startingAfter: index) {
                let tokenStart = index + 1
                let tokenEnd = closeOffset
                let token = String(chars[tokenStart..<tokenEnd])

                if let replacement = expand(token: token) {
                    switch replacement {
                    case .text(let text):
                        output.append(text)
                    case .cursor:
                        if cursorOffset == nil {
                            cursorOffset = output.count
                        }
                    }
                    index = tokenEnd + 1
                    continue
                }
                // Unknown placeholder — leave braces verbatim
            }

            output.append(ch)
            index += 1
        }

        return SnippetEvaluation(text: output, cursorOffset: cursorOffset)
    }

    // MARK: - Token expansion

    private enum Replacement {
        case text(String)
        case cursor
    }

    private func expand(token: String) -> Replacement? {
        guard !token.isEmpty else { return nil }

        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let argument: String? = parts.count > 1 ? String(parts[1]) : nil

        switch name {
        case "date":
            return .text(formatDate(argument: argument, includeDate: true, includeTime: false))
        case "time":
            return .text(formatDate(argument: argument, includeDate: false, includeTime: true))
        case "datetime":
            return .text(formatDate(argument: argument, includeDate: true, includeTime: true))
        case "clipboard":
            return .text(resolveClipboard(argument: argument))
        case "uuid":
            return .text(uuidProvider().uuidString)
        case "cursor":
            return .cursor
        default:
            return nil
        }
    }

    private func formatDate(argument: String?, includeDate: Bool, includeTime: Bool) -> String {
        let date = now()
        if let argument, !argument.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = argument
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = includeDate ? .medium : .none
        formatter.timeStyle = includeTime ? .short : .none
        return formatter.string(from: date)
    }

    private func resolveClipboard(argument: String?) -> String {
        guard let argument, !argument.isEmpty else {
            return clipboardText() ?? ""
        }
        // 1-based historical index: {clipboard:1} = most recent
        guard let n = Int(argument.trimmingCharacters(in: .whitespaces)), n >= 1 else {
            return ""
        }
        let entries = history()
        let zeroBased = n - 1
        guard zeroBased < entries.count else { return "" }
        return entries[zeroBased]
    }

    private func findClosingBrace(in chars: [Character], startingAfter openIndex: Int) -> Int? {
        var i = openIndex + 1
        while i < chars.count {
            let c = chars[i]
            // Disallow nested braces and newlines inside tokens — bail so
            // they render literally.
            if c == "{" || c == "\n" { return nil }
            if c == "}" {
                // Empty token "{}" doesn't count
                return i > openIndex + 1 ? i : nil
            }
            i += 1
        }
        return nil
    }
}
