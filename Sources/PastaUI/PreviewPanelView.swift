import AppKit
import PastaCore
import PastaDetectors
import SwiftUI

// File-level struct for file path preview data
struct FilePathPreviewData {
    var path: String
    var filename: String
    var fileType: FilePathDetector.FileType
    var mimeType: String?
    var exists: Bool
}

public struct PreviewPanelView: View {
    private enum Limits {
        static let inlineContentCharacters = 12_000
        static let inlineCodeCharacters = 2_000
        static let maxMetadataParseBytes = 128_000
        static let maxMetadataRenderBytes = 24_000
    }

    public let entry: ClipboardEntry?

    public init(entry: ClipboardEntry?) {
        self.entry = entry
    }

    public var body: some View {
        Group {
            if let entry {
                let metadataIsLarge = isMetadataLarge(entry.metadata)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header(entry)

                        if let decoded = decodedPreview(from: entry), decoded != entry.content {
                            let decodedPreview = truncatedText(decoded, limit: Limits.inlineContentCharacters)
                            SectionBox(title: "Decoded") {
                                MonospaceText(decodedPreview.text)
                                if decodedPreview.isTruncated {
                                    Text("Showing first \(Limits.inlineContentCharacters.formatted()) characters for performance.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        // Show extracted items (emails, URLs, etc.) if present
                        ExtractedItemsSection(entry: entry)

                        SectionBox(title: "Content") {
                            if (entry.contentType == .image || entry.contentType == .screenshot), let imagePath = entry.imagePath {
                                ImagePreview(path: imagePath)
                            } else if entry.contentType == .filePath, let filePreview = filePathPreview(from: entry) {
                                FilePreview(preview: filePreview)
                            } else if entry.contentType == .color, let swatch = colorSwatchPreview(from: entry) {
                                ColorSwatchPreview(swatch: swatch)
                            } else if entry.contentType == .code {
                                let codePreview = truncatedText(entry.content, limit: Limits.inlineCodeCharacters)
                                CodePreview(code: codePreview.text, language: detectedCodeLanguage(from: entry))
                                if codePreview.isTruncated {
                                    Text("Showing first \(Limits.inlineCodeCharacters.formatted()) characters for performance.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                let contentPreview = truncatedText(entry.content, limit: Limits.inlineContentCharacters)
                                Text(contentPreview.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if contentPreview.isTruncated {
                                    Text("Showing first \(Limits.inlineContentCharacters.formatted()) characters for performance.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !metadataIsLarge, entry.contentType == .jwt, let jwt = jwtPreview(from: entry) {
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

                        if !metadataIsLarge, let summary = metadataSummary(from: entry) {
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

                        if metadataIsLarge {
                            SectionBox(title: "Metadata") {
                                Text("Metadata is too large to render inline. Use Export My Data for the full JSON.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let pretty = prettyPrintedJSON(entry.metadata) {
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
            fileType: (first["fileType"] as? String).flatMap(FilePathDetector.FileType.init(rawValue:)) ?? .other,
            mimeType: first["mimeType"] as? String,
            exists: first["exists"] as? Bool ?? false
        )
    }

    private func colorSwatchPreview(from entry: ClipboardEntry) -> ColorSwatchPreview.Swatch? {
        if let meta = entry.metadata,
           let dict = parseJSONDictionary(meta),
           let colors = dict["colors"] as? [[String: Any]],
           let first = colors.first,
           let r = (first["red"] as? Int) ?? (first["red"] as? Double).map(Int.init),
           let g = (first["green"] as? Int) ?? (first["green"] as? Double).map(Int.init),
           let b = (first["blue"] as? Int) ?? (first["blue"] as? Double).map(Int.init)
        {
            let a = (first["alpha"] as? Double) ?? Double(first["alpha"] as? Int ?? 1)
            let raw = (first["raw"] as? String) ?? entry.content
            let format = (first["format"] as? String) ?? ""
            return ColorSwatchPreview.Swatch(
                raw: raw,
                format: format,
                red: UInt8(clamping: r),
                green: UInt8(clamping: g),
                blue: UInt8(clamping: b),
                alpha: a
            )
        }
        return nil
    }

    private func parseJSONDictionary(_ json: String) -> [String: Any]? {
        guard json.utf8.count <= Limits.maxMetadataParseBytes else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return obj as? [String: Any]
    }
    
    private func prettyPrintedJSON(_ json: String?) -> String? {
        guard let json else { return nil }
        guard json.utf8.count <= Limits.maxMetadataRenderBytes else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        guard let prettyString = String(data: pretty, encoding: .utf8) else { return nil }
        return truncatedText(prettyString, limit: Limits.maxMetadataRenderBytes).text
    }

    private func isMetadataLarge(_ metadata: String?) -> Bool {
        guard let metadata else { return false }
        return metadata.utf8.count > Limits.maxMetadataRenderBytes
    }

    private func truncatedText(_ text: String, limit: Int) -> TruncatedText {
        guard text.count > limit else {
            return TruncatedText(text: text, isTruncated: false)
        }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return TruncatedText(text: String(text[..<endIndex]), isTruncated: true)
    }

    private struct TruncatedText {
        let text: String
        let isTruncated: Bool
    }
}

// MARK: - Extracted Items Section

private struct ExtractedItemsSection: View {
    private static let batchSize = 100

    let entry: ClipboardEntry

    @State private var items: [PreviewPanelView.ExtractedItem] = []
    @State private var hasMore: Bool = false
    @State private var isLoading: Bool = false
    @State private var loadTask: Task<Void, Never>? = nil
    
    var body: some View {
        Group {
            if isLoading || !items.isEmpty {
                SectionBox(title: "Detected Items") {
                    if isLoading && items.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            ExtractedItemRow(item: item)
                        }
                    }

                    if hasMore {
                        HStack(spacing: 8) {
                            Text("Showing the first \(items.count) detected items.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("Show \(Self.batchSize) more") {
                                loadItems(limit: items.count + Self.batchSize)
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .disabled(isLoading)
                        }
                    }
                }
            }
        }
        .onAppear {
            loadItems(limit: Self.batchSize)
        }
        .onChange(of: entry.id) { _, _ in
            loadItems(limit: Self.batchSize)
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func loadItems(limit: Int) {
        loadTask?.cancel()
        items = []
        hasMore = false

        guard entry.metadata != nil else {
            isLoading = false
            return
        }

        isLoading = true
        let snapshot = entry

        loadTask = Task {
            let result = await Task.detached(priority: .utility) { () -> ([ExtractedItemPayload], Bool) in
                let extracted = MetadataParser.extractAllValues(
                    from: snapshot.metadata,
                    limit: limit + 1
                )
                let limited = extracted.prefix(limit).map {
                    ExtractedItemPayload(type: $0.type, value: $0.value, displayValue: $0.displayValue)
                }
                return (Array(limited), extracted.count > limit)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                items = result.0.map {
                    PreviewPanelView.ExtractedItem(type: $0.type, value: $0.value, displayValue: $0.displayValue)
                }
                hasMore = result.1
                isLoading = false
            }
        }
    }

    private struct ExtractedItemPayload: Sendable {
        let type: ContentType
        let value: String
        let displayValue: String
    }
}

private struct ExtractedItemRow: View {
    let item: PreviewPanelView.ExtractedItem
    @State private var copied = false
    
    var body: some View {
        Button {
            copyToClipboard()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.type.systemImageName)
                    .font(.caption)
                    .foregroundStyle(item.type.tint)
                    .frame(width: 16)
                
                Text(item.displayValue)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer(minLength: 4)
                
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(item.type.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy: \(item.value)")
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.value, forType: .string)
        
        withAnimation(.easeInOut(duration: 0.2)) {
            copied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                copied = false
            }
        }
    }
}

// Make ExtractedItem accessible to private structs
extension PreviewPanelView {
    struct ExtractedItem: Identifiable {
        let id = UUID()
        let type: ContentType
        let value: String
        let displayValue: String

        init(type: ContentType, value: String, displayValue: String) {
            self.type = type
            self.value = value
            self.displayValue = displayValue
        }
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

struct ImagePreview: View {
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
            let loaded = ImageDownsampler.load(path: imagePath, maxPixelSize: 1600) ?? NSImage(contentsOfFile: imagePath)
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
        preview.fileType == .image
    }

    private var systemImageName: String {
        switch preview.fileType {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.richtext"
        case .code: return "doc.text"
        case .archive: return "archivebox"
        case .data: return "cylinder"
        case .executable: return "app"
        case .font: return "textformat"
        case .other: return "doc"
        }
    }

    private var fileTypeColor: Color {
        switch preview.fileType {
        case .image: return .purple
        case .video: return .pink
        case .audio: return .orange
        case .document: return .blue
        case .code: return .green
        case .archive: return .brown
        case .data: return .cyan
        case .executable: return .red
        case .font: return .indigo
        case .other: return .gray
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
                        Text(preview.fileType.rawValue.uppercased())
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
                    let loaded = ImageDownsampler.load(path: path, maxPixelSize: 1200) ?? NSImage(contentsOfFile: path)
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


#Preview {
    PreviewPanelView(entry: ClipboardEntry(content: "func hello() {\n  print(\"hi\")\n}", contentType: .code, metadata: "{\"code\":[{\"language\":\"swift\",\"confidence\":0.9}]}"))
        .frame(width: 420, height: 520)
        .padding()
}

struct ColorSwatchPreview: View {
    struct Swatch {
        let raw: String
        let format: String
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: Double
    }

    let swatch: Swatch

    private var color: Color {
        Color(.sRGB,
              red: Double(swatch.red) / 255.0,
              green: Double(swatch.green) / 255.0,
              blue: Double(swatch.blue) / 255.0,
              opacity: swatch.alpha)
    }

    private var hexString: String {
        if swatch.alpha < 1.0 {
            return String(format: "#%02X%02X%02X%02X",
                          swatch.red, swatch.green, swatch.blue,
                          UInt8(round(swatch.alpha * 255)))
        }
        return String(format: "#%02X%02X%02X", swatch.red, swatch.green, swatch.blue)
    }

    private var rgbString: String {
        if swatch.alpha < 1.0 {
            return String(format: "rgba(%d, %d, %d, %.2f)",
                          swatch.red, swatch.green, swatch.blue, swatch.alpha)
        }
        return "rgb(\(swatch.red), \(swatch.green), \(swatch.blue))"
    }

    private var hslString: String {
        let (h, s, l) = rgbToHSL(r: swatch.red, g: swatch.green, b: swatch.blue)
        let hi = Int(round(h))
        let si = Int(round(s * 100))
        let li = Int(round(l * 100))
        if swatch.alpha < 1.0 {
            return String(format: "hsla(%d, %d%%, %d%%, %.2f)", hi, si, li, swatch.alpha)
        }
        return "hsl(\(hi), \(si)%, \(li)%)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .frame(width: 80, height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(swatch.raw)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if !swatch.format.isEmpty {
                    Text(swatch.format.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(hexString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(rgbString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(hslString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rgbToHSL(r: UInt8, g: UInt8, b: UInt8) -> (Double, Double, Double) {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let maxV = max(rf, gf, bf)
        let minV = min(rf, gf, bf)
        let l = (maxV + minV) / 2.0
        let delta = maxV - minV
        if delta == 0 { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2.0 - maxV - minV) : delta / (maxV + minV)
        var h: Double = 0
        if maxV == rf {
            h = (gf - bf) / delta + (gf < bf ? 6 : 0)
        } else if maxV == gf {
            h = (bf - rf) / delta + 2
        } else {
            h = (rf - gf) / delta + 4
        }
        h *= 60
        return (h, s, l)
    }
}
