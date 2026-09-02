import AppKit
import PastaCore
import PastaDetectors
import SwiftUI

public struct PreviewPanelView: View {
    private enum Limits {
        static let inlineContentCharacters = 12_000
        static let inlineCodeCharacters = 2_000
        static let maxMetadataParseBytes = 128_000
        static let maxMetadataRenderBytes = 24_000
    }

    public let entry: ClipboardEntry?
    private let onCopy: ((ClipboardEntry) -> Void)?
    /// True when the list beside this panel has nothing to select, so the
    /// empty state can say "No items yet" instead of asking for a selection.
    private let isListEmpty: Bool

    public init(
        entry: ClipboardEntry?,
        isListEmpty: Bool = false,
        onCopy: ((ClipboardEntry) -> Void)? = nil
    ) {
        self.entry = entry
        self.isListEmpty = isListEmpty
        self.onCopy = onCopy
    }

    public var body: some View {
        Group {
            if let entry {
                let metadataIsLarge = isMetadataLarge(entry.metadata)
                // Parse the metadata JSON once per body pass; every section below
                // reads from this dictionary instead of re-parsing it.
                let metadata = entry.metadata.flatMap { parseJSONDictionary($0) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header(entry)

                        if let decoded = decodedPreview(from: metadata), decoded != entry.content {
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
                            if onCopy != nil {
                                HStack {
                                    Spacer(minLength: 0)
                                    Button {
                                        onCopy?(entry)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .help("Copy this item")
                                }
                            }

                            if (entry.contentType == .image || entry.contentType == .screenshot), let imagePath = entry.imagePath {
                                ImagePreview(path: imagePath)
                            } else if entry.contentType == .filePath, let filePreview = filePathPreview(from: metadata, entry: entry) {
                                FilePreview(preview: filePreview)
                            } else if entry.contentType == .color, let swatch = colorSwatchPreview(from: metadata, entry: entry) {
                                ColorSwatchPreview(swatch: swatch)
                            } else if entry.contentType == .code {
                                let codePreview = truncatedText(entry.content, limit: Limits.inlineCodeCharacters)
                                CodePreview(code: codePreview.text, language: detectedCodeLanguage(from: metadata))
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

                        if !metadataIsLarge, entry.contentType == .jwt, let jwt = jwtPreview(from: metadata) {
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

                        if !metadataIsLarge, let summary = metadataSummary(from: metadata, contentType: entry.contentType) {
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
                        } else if let pretty = prettyPrintedJSON(metadata) {
                            SectionBox(title: "Metadata") {
                                MonospaceText(pretty)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            } else if isListEmpty {
                ContentUnavailableView(
                    "No items yet",
                    systemImage: "doc.on.clipboard",
                    description: Text("Copy something and it will show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .clipShape(RoundedRectangle(cornerRadius: PastaTheme.Radius.large, style: .continuous))
    }

    private func header(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.contentType.systemImageName)
                    .foregroundStyle(entry.contentType.tint)

                Text(entry.contentType.displayTitle)
                    .textCase(.uppercase)
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
                    HStack(spacing: 4) {
                        SourceAppIconView(sourceApp: source, size: 13)
                        Text(source.appDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func decodedPreview(from dict: [String: Any]?) -> String? {
        guard let dict else { return nil }
        guard let encoding = dict["encoding"] as? [String: Any] else { return nil }
        return encoding["decodedPreview"] as? String
    }

    private func detectedCodeLanguage(from dict: [String: Any]?) -> CodeLanguage? {
        guard let dict else { return nil }
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

    private func metadataSummary(from dict: [String: Any]?, contentType: ContentType) -> MetadataSummary? {
        guard let dict else { return nil }

        switch contentType {
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

    private func jwtPreview(from dict: [String: Any]?) -> JWTPreview? {
        guard let dict else { return nil }
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

    fileprivate func filePathPreview(from dict: [String: Any]?, entry: ClipboardEntry) -> FilePathPreviewData? {
        guard let dict else { return nil }
        guard let paths = dict["filePaths"] as? [[String: Any]], let first = paths.first else { return nil }

        return FilePathPreviewData(
            path: first["path"] as? String ?? entry.content,
            filename: first["filename"] as? String ?? "",
            fileType: (first["fileType"] as? String).flatMap(FilePathDetector.FileType.init(rawValue:)) ?? .other,
            mimeType: first["mimeType"] as? String,
            exists: first["exists"] as? Bool ?? false
        )
    }

    private func colorSwatchPreview(from dict: [String: Any]?, entry: ClipboardEntry) -> ColorSwatchPreview.Swatch? {
        if let dict,
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

    private func prettyPrintedJSON(_ dict: [String: Any]?) -> String? {
        guard let dict else { return nil }
        guard JSONSerialization.isValidJSONObject(dict) else { return nil }
        guard let pretty = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return nil }
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

#Preview {
    PreviewPanelView(entry: ClipboardEntry(content: "func hello() {\n  print(\"hi\")\n}", contentType: .code, metadata: "{\"code\":[{\"language\":\"swift\",\"confidence\":0.9}]}"))
        .frame(width: 420, height: 520)
        .padding()
}
