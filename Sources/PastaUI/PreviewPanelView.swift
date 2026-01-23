import AppKit
import PastaCore
import SwiftUI

// File-level struct for file path preview data
struct FilePathPreviewData {
    var path: String
    var filename: String
    var fileType: String
    var mimeType: String?
    var exists: Bool
}

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
                            if (entry.contentType == .image || entry.contentType == .screenshot), let imagePath = entry.imagePath {
                                ImagePreview(path: imagePath)
                            } else if entry.contentType == .filePath, let filePreview = filePathPreview(from: entry) {
                                FilePreview(preview: filePreview)
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

                        if let summary = metadataSummary(from: entry) {
                            SectionBox(title: "Details") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(summary.items, id: \.title) { item in
                                        LabeledContent(item.title) {
                                            Text(item.value)
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

                Text(entry.contentType.displayTitle.uppercased())
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

    private struct MetadataSummary {
        var items: [MetadataItem]
    }

    private struct MetadataItem {
        var title: String
        var value: String
    }

    private func metadataSummary(from entry: ClipboardEntry) -> MetadataSummary? {
        guard let meta = entry.metadata else { return nil }
        guard let dict = parseJSONDictionary(meta) else { return nil }

        switch entry.contentType {
        case .phoneNumber:
            guard let phone = firstObject(dict["phoneNumbers"]) else { return nil }
            let number = phone["number"] as? String ?? ""
            let confidence = formatConfidence(phone["confidence"])
            return compactSummary([
                MetadataItem(title: "Number", value: number),
                MetadataItem(title: "Confidence", value: confidence)
            ])
        case .ipAddress:
            guard let ip = firstObject(dict["ipAddresses"]) else { return nil }
            let address = ip["address"] as? String ?? ""
            let version = ip["version"] as? String ?? ""
            let scope = formatScope(from: ip)
            let confidence = formatConfidence(ip["confidence"])
            return compactSummary([
                MetadataItem(title: "Address", value: address),
                MetadataItem(title: "Version", value: version.uppercased()),
                MetadataItem(title: "Scope", value: scope),
                MetadataItem(title: "Confidence", value: confidence)
            ])
        case .uuid:
            guard let uuid = firstObject(dict["uuids"]) else { return nil }
            let value = uuid["uuid"] as? String ?? ""
            let version = formatUUIDVersion(uuid["version"])
            let variant = uuid["variant"] as? String ?? ""
            let confidence = formatConfidence(uuid["confidence"])
            return compactSummary([
                MetadataItem(title: "UUID", value: value),
                MetadataItem(title: "Version", value: version),
                MetadataItem(title: "Variant", value: variant.uppercased()),
                MetadataItem(title: "Confidence", value: confidence)
            ])
        case .hash:
            guard let hash = firstObject(dict["hashes"]) else { return nil }
            let value = hash["hash"] as? String ?? ""
            let kind = hash["kind"] as? String ?? ""
            let bits = formatBits(hash["bits"])
            let confidence = formatConfidence(hash["confidence"])
            return compactSummary([
                MetadataItem(title: "Hash", value: value),
                MetadataItem(title: "Kind", value: kind.uppercased()),
                MetadataItem(title: "Bits", value: bits),
                MetadataItem(title: "Confidence", value: confidence)
            ])
        default:
            return nil
        }
    }

    private func compactSummary(_ items: [MetadataItem?]) -> MetadataSummary? {
        let compacted = items.compactMap { $0 }.filter { !$0.value.isEmpty }
        guard !compacted.isEmpty else { return nil }
        return MetadataSummary(items: compacted)
    }

    private func firstObject(_ value: Any?) -> [String: Any]? {
        if let list = value as? [[String: Any]] {
            return list.first
        }
        return nil
    }

    private func formatConfidence(_ value: Any?) -> String {
        guard let confidence = value as? Double else { return "" }
        return String(format: "%.0f%%", confidence * 100)
    }

    private func formatBits(_ value: Any?) -> String {
        if let bits = value as? Int { return "\(bits)" }
        if let bits = value as? Double { return "\(Int(bits))" }
        return ""
    }

    private func formatScope(from dict: [String: Any]) -> String {
        var scopes: [String] = []
        if (dict["isPrivate"] as? Bool) == true { scopes.append("private") }
        if (dict["isLoopback"] as? Bool) == true { scopes.append("loopback") }
        if (dict["isLinkLocal"] as? Bool) == true { scopes.append("link-local") }
        if (dict["isMulticast"] as? Bool) == true { scopes.append("multicast") }
        if scopes.isEmpty { scopes.append("public") }
        return scopes.joined(separator: ", ")
    }

    private func formatUUIDVersion(_ value: Any?) -> String {
        if let version = value as? Int { return "v\(version)" }
        if let version = value as? Double { return "v\(Int(version))" }
        return "unknown"
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
    
    fileprivate func filePathPreview(from entry: ClipboardEntry) -> FilePathPreviewData? {
        guard let meta = entry.metadata else { return nil }
        guard let dict = parseJSONDictionary(meta) else { return nil }
        guard let paths = dict["filePaths"] as? [[String: Any]], let first = paths.first else { return nil }
        
        return FilePathPreviewData(
            path: first["path"] as? String ?? entry.content,
            filename: first["filename"] as? String ?? "",
            fileType: first["fileType"] as? String ?? "other",
            mimeType: first["mimeType"] as? String,
            exists: first["exists"] as? Bool ?? false
        )
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

    @State private var image: NSImage?
    @State private var loadedPath: String = ""

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: path) { _, newPath in
            loadImage(from: newPath)
        }
        .overlay {
            if image == nil {
                ContentUnavailableView(
                    "Missing image",
                    systemImage: "photo",
                    description: Text(path)
                )
                .opacity(0) // keeps layout stable while loading
            }
        }
    }
    
    private func loadImageIfNeeded() {
        guard loadedPath != path else { return }
        loadImage(from: path)
    }
    
    private func loadImage(from imagePath: String) {
        loadedPath = imagePath
        image = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = NSImage(contentsOfFile: imagePath)
            DispatchQueue.main.async {
                // Only update if path hasn't changed
                if loadedPath == imagePath {
                    self.image = loaded
                }
            }
        }
    }
}

private struct FilePreview: View {
    let preview: FilePathPreviewData
    
    @State private var image: NSImage?
    @State private var quickLookURL: URL?
    
    private var isImage: Bool {
        preview.fileType == "image"
    }
    
    private var systemImageName: String {
        switch preview.fileType {
        case "image": return "photo"
        case "video": return "film"
        case "audio": return "waveform"
        case "document": return "doc.richtext"
        case "code": return "doc.text"
        case "archive": return "archivebox"
        case "data": return "cylinder"
        case "executable": return "app"
        case "font": return "textformat"
        default: return "doc"
        }
    }
    
    private var fileTypeColor: Color {
        switch preview.fileType {
        case "image": return .purple
        case "video": return .pink
        case "audio": return .orange
        case "document": return .blue
        case "code": return .green
        case "archive": return .brown
        case "data": return .cyan
        case "executable": return .red
        case "font": return .indigo
        default: return .gray
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // File info header
            HStack(spacing: 12) {
                Image(systemName: systemImageName)
                    .font(.largeTitle)
                    .foregroundStyle(fileTypeColor)
                    .frame(width: 50, height: 50)
                    .background(fileTypeColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.filename)
                        .font(.headline)
                        .lineLimit(2)
                    
                    HStack(spacing: 8) {
                        Text(preview.fileType.uppercased())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(fileTypeColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(fileTypeColor)
                        
                        if let mime = preview.mimeType {
                            Text(mime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        if !preview.exists {
                            Label("Not found", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                
                Spacer()
            }
            
            // Path
            Text(preview.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            
            // Image preview if it's an image file
            if isImage && preview.exists {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 100)
                }
            }
            
            // Actions
            if preview.exists {
                HStack(spacing: 12) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: preview.path)])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: preview.path))
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .onAppear {
            if isImage && preview.exists && image == nil {
                let path = preview.path
                DispatchQueue.global(qos: .userInitiated).async {
                    let loaded = NSImage(contentsOfFile: path)
                    DispatchQueue.main.async {
                        self.image = loaded
                    }
                }
            }
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
