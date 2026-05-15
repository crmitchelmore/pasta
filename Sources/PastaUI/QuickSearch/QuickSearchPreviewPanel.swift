import PastaCore
import SwiftUI

// MARK: - Quick Search Preview Panel

struct QuickSearchPreviewPanel: View {
    let entry: ClipboardEntry

    var body: some View {
        let isImageEntry = (entry.contentType == .image || entry.contentType == .screenshot) && entry.imagePath != nil

        VStack(alignment: .leading, spacing: 0) {
            // Header with metadata
            HStack(spacing: 8) {
                Image(systemName: entry.contentType.systemImageName)
                    .font(.title3)
                    .foregroundStyle(entry.contentType.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.contentType.displayTitle)
                        .font(.headline)

                    HStack(spacing: 6) {
                        if let app = entry.sourceApp?.appDisplayName {
                            HStack(spacing: 3) {
                                SourceAppIconView(sourceApp: entry.sourceApp, size: 12)
                                Text(app)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("•")
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.timestamp.relativeFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Character count badge or "Image" badge
                Text(isImageEntry ? "Image" : "\(entry.content.count.formatted()) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .opacity(0.5)

            // Scrollable content
            ScrollView {
                if let imagePath = entry.imagePath, isImageEntry {
                    ImagePreview(path: imagePath)
                        .padding(16)
                } else {
                    Text(entry.content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }

            Divider()
                .opacity(0.5)

            // Footer with hint
            HStack {
                Text("← to close")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("↵ to paste")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
