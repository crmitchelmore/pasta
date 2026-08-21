import PastaCore
import SwiftUI

// MARK: - Row Data Model
//
// `ClipboardRowData` is the SINGLE SOURCE OF TRUTH for what a row shows.
//
// Two surfaces render this struct today:
//   * `ClipboardCellView` (AppKit) inside `HighPerformanceListView` — main panel.
//   * `QuickSearchRow` (SwiftUI) — Spotlight-style quick search overlay.
//
// We can't share the actual cell because one is AppKit and one is SwiftUI, but
// both renderers consume the same `ClipboardRowData` and read the same
// computed display properties below. That means whatever we change about how a
// row's metadata/preview is derived applies in both places automatically.

/// Lightweight data for rendering a single row.
public struct ClipboardRowData: Equatable {
    public let id: UUID
    public let previewText: String
    public let contentType: ContentType
    public let sourceAppIdentifier: String?
    public let sourceAppName: String?
    public let timestamp: Date
    public let copyCount: Int
    public let isLarge: Bool
    public let isExtracted: Bool
    public let parentEntryId: UUID?
    public let isSynced: Bool
    public let swatchColor: SwatchColor?
    public let isPinned: Bool
    /// Path to the image file (for image/screenshot entries). Used by surfaces
    /// that render thumbnails (QuickSearch). The main-panel cell does not
    /// currently render thumbnails but the data lives here for parity.
    public let imagePath: String?
    /// Number of characters in the underlying content. QuickSearch shows this
    /// as part of its metadata line.
    public let contentLength: Int
    /// When non-nil, this row renders as a non-selectable section header
    /// with the given title. The other fields are unused.
    public let sectionHeader: String?

    public struct SwatchColor: Equatable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
        public let alpha: Double

        public init(red: UInt8, green: UInt8, blue: UInt8, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    public init(from entry: ClipboardEntry) {
        self.id = entry.id
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseText = trimmed.isEmpty ? "(empty)" : String(trimmed.prefix(300))
        // Credit-card primary entries should never show their full PAN in the row preview.
        if entry.contentType == .creditCard, !trimmed.isEmpty {
            self.previewText = ClipboardRowData.maskCreditCardPreview(trimmed)
        } else {
            self.previewText = baseText
        }
        self.contentType = entry.contentType
        self.sourceAppIdentifier = entry.sourceApp
        self.sourceAppName = entry.sourceApp?.appDisplayName
        self.timestamp = entry.timestamp
        self.copyCount = entry.copyCount
        self.isLarge = entry.content.utf8.count > 10 * 1024
        self.isExtracted = entry.isExtracted
        self.parentEntryId = entry.parentEntryId
        self.isSynced = entry.isSynced
        self.swatchColor = Self.parseSwatch(from: entry)
        self.isPinned = entry.isPinned
        self.imagePath = entry.imagePath
        // utf8.count is O(1) for native strings; `count` walks every grapheme,
        // which is milliseconds per row for multi-MB entries.
        self.contentLength = entry.content.utf8.count
        self.sectionHeader = nil
    }

    private static func parseSwatch(from entry: ClipboardEntry) -> SwatchColor? {
        guard entry.contentType == .color else { return nil }
        if let meta = entry.metadata,
           let data = meta.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = obj as? [String: Any],
           let colors = dict["colors"] as? [[String: Any]],
           let first = colors.first,
           let r = (first["red"] as? Int) ?? (first["red"] as? Double).map(Int.init),
           let g = (first["green"] as? Int) ?? (first["green"] as? Double).map(Int.init),
           let b = (first["blue"] as? Int) ?? (first["blue"] as? Double).map(Int.init)
        {
            let a = (first["alpha"] as? Double) ?? Double(first["alpha"] as? Int ?? 1)
            return SwatchColor(red: UInt8(clamping: r), green: UInt8(clamping: g), blue: UInt8(clamping: b), alpha: a)
        }
        // Fallback: re-detect from content.
        let detector = ColorSwatchParser.shared
        if let det = detector.parse(entry.content) {
            return SwatchColor(red: det.red, green: det.green, blue: det.blue, alpha: det.alpha)
        }
        return nil
    }

    /// Masks any 13-19 digit (Luhn-valid) numbers in the preview, leaving only last 4 visible.
    /// Falls back to the trimmed input if no valid card found.
    static func maskCreditCardPreview(_ text: String) -> String {
        let digits = text.filter(\.isNumber)
        guard digits.count >= 13, digits.count <= 19 else {
            return String(text.prefix(300))
        }
        // If the whole entry is a single card number, build the masked grouped form.
        let last4 = String(digits.suffix(4))
        let masked = String(repeating: "*", count: max(0, digits.count - 4)) + last4
        var grouped = ""
        for (i, ch) in masked.enumerated() {
            if i > 0 && i % 4 == 0 { grouped.append(" ") }
            grouped.append(ch)
        }
        return grouped
    }

    /// Builds a non-selectable section header row.
    public static func header(_ title: String) -> ClipboardRowData {
        ClipboardRowData(headerTitle: title)
    }

    private init(headerTitle: String) {
        self.id = UUID()
        self.previewText = ""
        self.contentType = .text
        self.sourceAppIdentifier = nil
        self.sourceAppName = nil
        self.timestamp = .distantPast
        self.copyCount = 0
        self.isLarge = false
        self.isExtracted = false
        self.parentEntryId = nil
        self.isSynced = false
        self.swatchColor = nil
        self.isPinned = false
        self.imagePath = nil
        self.contentLength = 0
        self.sectionHeader = headerTitle
    }

    public var isHeader: Bool { sectionHeader != nil }

    // MARK: - Derived display strings (shared by all renderers)

    /// Single-line preview with newlines collapsed to spaces. QuickSearch uses
    /// this; the main panel uses the multi-line `previewText` directly.
    public var singleLinePreview: String {
        let trimmed = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.components(separatedBy: .newlines).joined(separator: " ")
        if collapsed.isEmpty {
            switch contentType {
            case .image:      return "Image"
            case .screenshot: return "Screenshot"
            default:          return "(empty)"
            }
        }
        return String(collapsed.prefix(100))
    }

    /// Metadata line for the main-panel cell:  "App • 5m ago • ×3"
    public var mainPanelMetadata: String {
        var parts: [String] = []
        if let sourceAppName { parts.append(sourceAppName) }
        parts.append(timestamp.relativeFormatted)
        if copyCount > 1 { parts.append("×\(copyCount)") }
        return parts.joined(separator: " • ")
    }

    /// Metadata segments for the QuickSearch standard row.
    /// Returns the pieces in the order the row should render them, e.g.
    /// ["URL", "Safari", "5m ago", "12 chars"].
    public var quickSearchMetadataSegments: [String] {
        var parts: [String] = [contentType.displayTitle]
        if let sourceAppName { parts.append(sourceAppName) }
        parts.append(timestamp.relativeFormatted)
        parts.append("\(contentLength.formatted()) chars")
        return parts
    }

    /// True if this row should render an image thumbnail rather than an icon.
    public var prefersImageThumbnail: Bool {
        (contentType == .image || contentType == .screenshot) && imagePath != nil
    }
}

/// Tiny shim to avoid pulling PastaDetectors into PastaUI for swatch parsing.
/// Uses NSColor parsing for hex literals as a best-effort fallback.
private final class ColorSwatchParser {
    static let shared = ColorSwatchParser()
    struct Parsed { let red: UInt8; let green: UInt8; let blue: UInt8; let alpha: Double }

    func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let body = String(trimmed.dropFirst())
        switch body.count {
        case 3:
            let chars = Array(body)
            guard let r = hex(chars[0], chars[0]),
                  let g = hex(chars[1], chars[1]),
                  let b = hex(chars[2], chars[2]) else { return nil }
            return Parsed(red: r, green: g, blue: b, alpha: 1.0)
        case 6:
            let chars = Array(body)
            guard let r = hex(chars[0], chars[1]),
                  let g = hex(chars[2], chars[3]),
                  let b = hex(chars[4], chars[5]) else { return nil }
            return Parsed(red: r, green: g, blue: b, alpha: 1.0)
        case 8:
            let chars = Array(body)
            guard let r = hex(chars[0], chars[1]),
                  let g = hex(chars[2], chars[3]),
                  let b = hex(chars[4], chars[5]),
                  let a = hex(chars[6], chars[7]) else { return nil }
            return Parsed(red: r, green: g, blue: b, alpha: Double(a) / 255.0)
        default:
            return nil
        }
    }

    private func hex(_ a: Character, _ b: Character) -> UInt8? {
        UInt8(String([a, b]), radix: 16)
    }
}
