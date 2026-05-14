import AppKit
import PastaCore
import SwiftUI

struct CodePreview: View {
    let code: String
    let language: CodeLanguage?

    @State private var highlighted: AttributedString?
    @State private var highlightTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let highlighted {
                Text(highlighted)
            } else {
                // Plain monospaced fallback while highlighting runs
                Text(code)
                    .font(.system(size: NSFont.systemFontSize, design: .monospaced))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: code) { _, newCode in
            scheduleHighlight(newCode)
        }
        .onAppear {
            scheduleHighlight(code)
        }
    }

    private func scheduleHighlight(_ text: String) {
        highlightTask?.cancel()
        let lang = language
        highlightTask = Task.detached(priority: .userInitiated) {
            let result = Self.highlightCode(text, language: lang)
            guard !Task.isCancelled else { return }
            await MainActor.run { highlighted = result }
        }
    }

    private nonisolated static func highlightCode(_ code: String, language: CodeLanguage?) -> AttributedString {
        let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let out = NSMutableAttributedString(string: code)
        out.addAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ], range: NSRange(location: 0, length: out.length))

        // Comments
        applyPattern("(?m)//.*$", color: .systemGreen, to: out)
        applyPattern("/\\*([\\s\\S]*?)\\*/", options: [.dotMatchesLineSeparators], color: .systemGreen, to: out)

        // Strings
        applyPattern(#"\"([^\"\\]|\\.)*\""#, color: .systemRed, to: out)
        applyPattern(#"'([^'\\]|\\.)*'"#, color: .systemRed, to: out)

        // Numbers
        applyPattern("\\b\\d+(?:\\.\\d+)?\\b", color: .systemPurple, to: out)

        // Keywords
        let keywords: [String]
        switch language {
        case .swift:
            keywords = ["func", "let", "var", "struct", "class", "enum", "import", "if", "else", "for", "while", "return", "public", "private", "internal", "extension", "guard", "try", "catch", "throw", "throws", "async", "await"]
        case .javaScript, .typeScript:
            keywords = ["function", "const", "let", "var", "class", "import", "export", "if", "else", "for", "while", "return", "async", "await", "type", "interface"]
        case .python:
            keywords = ["def", "class", "import", "from", "if", "elif", "else", "for", "while", "return", "async", "await"]
        default:
            keywords = ["if", "else", "for", "while", "return"]
        }

        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        applyPattern("\\b(\(escaped))\\b", color: .systemBlue, to: out)

        return AttributedString(out)
    }

    private nonisolated static func applyPattern(
        _ pattern: String,
        options: NSRegularExpression.Options = [],
        color: NSColor,
        to attr: NSMutableAttributedString
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let matches = regex.matches(in: attr.string, options: [], range: NSRange(location: 0, length: attr.length))
        for m in matches {
            attr.addAttributes([.foregroundColor: color], range: m.range)
        }
    }
}
