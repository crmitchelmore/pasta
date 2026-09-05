import PastaCore
import SwiftUI

// MARK: - Quick Search Preview Panel

struct QuickSearchPreviewPanel: View {
    private enum Limits {
        static let inlineContentCharacters = 12_000
    }

    let entry: ClipboardEntry

    /// Counting and slicing `entry.content` walks graphemes, so it is done once
    /// per entry instead of on every body evaluation.
    @State private var displayedContent: String = ""
    @State private var characterCount: Int = 0
    @State private var isContentTruncated: Bool = false

    var body: some View {
        let imageSource = ClipboardImageSource(entry: entry)
        let isImageEntry = imageSource != nil

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
                Text(isImageEntry ? "Image" : "\(characterCount.formatted()) chars")
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
                if let imageSource {
                    ImagePreview(source: imageSource)
                        .padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayedContent)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if isContentTruncated {
                            Text("Showing first \(Limits.inlineContentCharacters.formatted()) characters for performance.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
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
        .onChange(of: entry.content, initial: true) { _, _ in
            refreshDisplayedContent()
        }
    }

    private func refreshDisplayedContent() {
        let content = entry.content
        let count = content.count
        characterCount = count

        if count > Limits.inlineContentCharacters {
            let end = content.index(content.startIndex, offsetBy: Limits.inlineContentCharacters)
            displayedContent = String(content[..<end])
            isContentTruncated = true
        } else {
            displayedContent = content
            isContentTruncated = false
        }
    }
}
