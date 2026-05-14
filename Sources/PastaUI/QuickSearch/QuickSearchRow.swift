import AppKit
import PastaCore
import SwiftUI

// MARK: - Quick Search Row

struct QuickSearchRow: View {
    enum Style {
        case standard
        case micro
    }

    let row: ClipboardRowData
    let index: Int
    let isSelected: Bool
    let query: String
    let style: Style

    init(
        entry: ClipboardEntry,
        index: Int,
        isSelected: Bool,
        query: String = "",
        style: Style = .standard
    ) {
        self.row = ClipboardRowData(from: entry)
        self.index = index
        self.isSelected = isSelected
        self.query = query
        self.style = style
    }

    var body: some View {
        switch style {
        case .standard: standardBody
        case .micro:    microBody
        }
    }

    // MARK: standard

    private var standardBody: some View {
        HStack(spacing: 12) {
            // Type icon or image thumbnail
            if row.prefersImageThumbnail, let imagePath = row.imagePath {
                ImageThumbnail(path: imagePath, size: 36)
            } else {
                Image(systemName: row.contentType.systemImageName)
                    .font(.title3)
                    .foregroundStyle(row.contentType.tint)
                    .frame(width: 28)
            }

            // Content preview — single-line preview comes from the shared
            // row data so the main panel and QuickSearch render identical text.
            VStack(alignment: .leading, spacing: 2) {
                Text(row.singleLinePreview)
                    .lineLimit(1)
                    .font(.body)

                // Metadata segments come from `quickSearchMetadataSegments`
                // (shared with the main panel via `ClipboardRowData`).
                // First two pieces (type, app) render secondary; trailing
                // pieces (timestamp, char count) render tertiary, matching
                // the previous visual hierarchy.
                let segments = row.quickSearchMetadataSegments
                let secondaryCount = row.sourceAppName == nil ? 1 : 2
                HStack(spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                        if idx > 0 {
                            Text("•")
                                .foregroundStyle(.tertiary)
                        }
                        Text(segment)
                            .font(.caption2)
                            .foregroundStyle(idx < secondaryCount ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    }
                }
            }

            Spacer()

            // Keyboard shortcut hint (first 9 items only)
            if index <= 9 {
                Text("⌘\(index)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: micro

    private var microBody: some View {
        VStack(spacing: 4) {
            // Content type icon or image thumbnail
            if row.prefersImageThumbnail, let imagePath = row.imagePath {
                ImageThumbnail(path: imagePath, size: 32)
            } else {
                Image(systemName: row.contentType.systemImageName)
                    .font(.title3)
                    .foregroundStyle(row.contentType.tint)
            }

            // App name (abbreviated)
            if let app = row.sourceAppName {
                Text(app.prefix(6))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Keyboard shortcut hint (first 9 items only)
            if index <= 9 {
                Text("⌘\(index)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
