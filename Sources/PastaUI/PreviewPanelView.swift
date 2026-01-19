import AppKit
import PastaCore
import SwiftUI

public struct PreviewPanelView: View {
    public let entry: ClipboardEntry?

    public init(entry: ClipboardEntry?) {
        self.entry = entry
    }

    public var body: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header(entry)

                        if let decoded = decodedPreview(from: entry), decoded != entry.content {
                            SectionBox(title: "Decoded") {
                                MonospaceText(decoded)
                            }
                        }

                        SectionBox(title: "Content") {
                            if entry.contentType == .image, let imagePath = entry.imagePath {
                                ImagePreview(path: imagePath)
                            } else if entry.contentType == .code {
                                CodePreview(code: entry.content, language: detectedCodeLanguage(from: entry))
                            } else {
                                Text(entry.content)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if entry.contentType == .jwt, let jwt = jwtPreview(from: entry) {
                            SectionBox(title: "JWT") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let header = jwt.headerJSON {
                                        LabeledContent("Header") {
                                            MonospaceText(header)
                                        }
                                    }
                                    if let payload = jwt.payloadJSON {
                                        LabeledContent("Payload") {
                                            MonospaceText(payload)
                                        }
                                    }
                                    if let claims = jwt.claimsPrettyJSON {
                                        LabeledContent("Claims") {
                                            MonospaceText(claims)
                                        }
                                    }
                                }
                            }
                        }

                        if let pretty = prettyPrintedJSON(entry.metadata) {
                            SectionBox(title: "Metadata") {
                                MonospaceText(pretty)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            } else {
                ContentUnavailableView(
                    "Select an item",
                    systemImage: "sidebar.right",
                    description: Text("Pick an entry to see details.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func header(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.contentType.systemImageName)
                    .foregroundStyle(entry.contentType.tint)

                Text(entry.contentType.rawValue.uppercased())
                    .font(.headline)

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text(entry.timestamp, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if entry.copyCount > 1 {
                    Text("×\(entry.copyCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let source = entry.sourceApp, !source.isEmpty {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func decodedPreview(from entry: ClipboardEntry) -> String? {
        guard let meta = entry.metadata else { return nil }
        guard let dict = parseJSONDictionary(meta) else { return nil }
        guard let encoding = dict["encoding"] as? [String: Any] else { return nil }
        return encoding["decodedPreview"] as? String
    }

    private func detectedCodeLanguage(from entry: ClipboardEntry) -> CodeLanguage? {
        guard let meta = entry.metadata else { return nil }
        guard let dict = parseJSONDictionary(meta) else { return nil }
        guard let codes = dict["code"] as? [[String: Any]] else { return nil }
        guard let first = codes.first else { return nil }
        guard let lang = first["language"] as? String else { return nil }
        return CodeLanguage(rawValue: lang)
    }

    private struct JWTPreview {
        var headerJSON: String?
        var payloadJSON: String?
        var claimsPrettyJSON: String?
    }

    private func jwtPreview(from entry: ClipboardEntry) -> JWTPreview? {
        guard let meta = entry.metadata else { return nil }
        guard let dict = parseJSONDictionary(meta) else { return nil }
        guard let jwts = dict["jwt"] as? [[String: Any]], let first = jwts.first else { return nil }

        let header = first["headerJSON"] as? String
        let payload = first["payloadJSON"] as? String

        var prettyClaims: String?
        if let claims = first["claims"],
           JSONSerialization.isValidJSONObject(claims),
           let data = try? JSONSerialization.data(withJSONObject: claims, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            prettyClaims = s
        }

        return JWTPreview(headerJSON: header, payloadJSON: payload, claimsPrettyJSON: prettyClaims)
    }

    private func parseJSONDictionary(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return obj as? [String: Any]
    }

    private func prettyPrintedJSON(_ json: String?) -> String? {
        guard let json else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MonospaceText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImagePreview: View {
    let path: String

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ContentUnavailableView(
                "Missing image",
                systemImage: "photo",
                description: Text(path)
            )
        }
    }
}

private struct CodePreview: View {
    let code: String
    let language: CodeLanguage?

    var body: some View {
        Text(highlightedCode(code, language: language))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func highlightedCode(_ code: String, language: CodeLanguage?) -> AttributedString {
        let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let out = NSMutableAttributedString(string: code)
        out.addAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ], range: NSRange(location: 0, length: out.length))

        // Comments
        apply(pattern: "(?m)//.*$", color: .systemGreen, to: out)
        apply(pattern: "/\\*([\\s\\S]*?)\\*/", options: [.dotMatchesLineSeparators], color: .systemGreen, to: out)

        // Strings
        apply(pattern: #"\"([^\"\\]|\\.)*\""#, color: .systemRed, to: out)
        apply(pattern: #"'([^'\\]|\\.)*'"#, color: .systemRed, to: out)

        // Numbers
        apply(pattern: "\\b\\d+(?:\\.\\d+)?\\b", color: .systemPurple, to: out)

        // Keywords (lightweight, language-aware-ish)
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
        apply(pattern: "\\b(\(escaped))\\b", color: .systemBlue, to: out)

        return AttributedString(out)
    }

    private func apply(
        pattern: String,
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


#Preview {
    PreviewPanelView(entry: ClipboardEntry(content: "func hello() {\n  print(\"hi\")\n}", contentType: .code, metadata: "{\"code\":[{\"language\":\"swift\",\"confidence\":0.9}]}"))
        .frame(width: 420, height: 520)
        .padding()
}
