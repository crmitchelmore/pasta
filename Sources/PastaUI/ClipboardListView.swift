import PastaCore
import SwiftUI

public struct ClipboardListView: View {
    public let entries: [ClipboardEntry]
    @Binding private var selectedEntryID: UUID?
    private let onCopy: (ClipboardEntry) -> Void
    private let onPaste: (ClipboardEntry) -> Void
    private let onDelete: (ClipboardEntry) -> Void
    private let onReveal: (ClipboardEntry) -> Void

    public init(
        entries: [ClipboardEntry],
        selectedEntryID: Binding<UUID?> = .constant(nil),
        onCopy: @escaping (ClipboardEntry) -> Void,
        onPaste: @escaping (ClipboardEntry) -> Void,
        onDelete: @escaping (ClipboardEntry) -> Void,
        onReveal: @escaping (ClipboardEntry) -> Void
    ) {
        self.entries = entries
        _selectedEntryID = selectedEntryID
        self.onCopy = onCopy
        self.onPaste = onPaste
        self.onDelete = onDelete
        self.onReveal = onReveal
    }

    public var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No clipboard history",
                systemImage: "doc.on.clipboard",
                description: Text("Copy anything to build your history. Press ⌘F to search or ↩︎ to paste.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedEntryID) {
                ForEach(entries, id: \.id) { entry in
                    ClipboardRowView(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Paste") { onPaste(entry) }
                            Button("Copy") { onCopy(entry) }
                            Button("Delete", role: .destructive) { onDelete(entry) }
                            if entry.contentType == .filePath {
                                Button("Reveal in Finder") { onReveal(entry) }
                            }
                        }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct ClipboardRowView: View {
    let entry: ClipboardEntry

    private var isLarge: Bool {
        entry.content.utf8.count > 10 * 1024
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.contentType.systemImageName)
                .foregroundStyle(entry.contentType.tint)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.previewText)
                        .lineLimit(2)
                        .font(.body)

                    Spacer(minLength: 0)

                    if isLarge {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Large entry (>10KB)")
                    }
                }

                HStack(spacing: 8) {
                    ContentTypeBadge(type: entry.contentType)
                    
                    if let appName = entry.sourceApp?.displayName {
                        Text(appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(entry.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if entry.copyCount > 1 {
                        Text("×\(entry.copyCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ContentTypeBadge: View {
    let type: ContentType

    var body: some View {
        Text(type.badgeTitle)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(type.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(type.tint)
    }
}

private extension ClipboardEntry {
    var previewText: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "(empty)"
        }
        return trimmed
    }
}

private extension String {
    /// Convert bundle identifier to friendly app name
    var displayName: String {
        // Strip "com.apple." or "com.xxx." prefix and capitalize
        let parts = self.split(separator: ".")
        if let last = parts.last {
            return String(last).capitalized
        }
        return self
    }
}

#Preview {
    let base = ClipboardEntry(content: "Hello world", contentType: .text)
    let items = (0..<1_000).map { idx in
        var e = base
        e.content = "Item \(idx): \(String(repeating: "x", count: (idx % 40) + 1))"
        e.timestamp = Date().addingTimeInterval(-Double(idx) * 30)
        e.copyCount = (idx % 5) + 1
        e.contentType = ContentType.allCases[idx % ContentType.allCases.count]
        return e
    }

    return ClipboardListView(
        entries: items,
        onCopy: { _ in },
        onPaste: { _ in },
        onDelete: { _ in },
        onReveal: { _ in }
    )
        .frame(width: 420, height: 600)
        .padding()
}
