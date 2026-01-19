import PastaCore
import SwiftUI

public struct ClipboardListView: View {
    public let entries: [ClipboardEntry]
    @Binding private var selectedEntryID: UUID?

    public init(entries: [ClipboardEntry], selectedEntryID: Binding<UUID?> = .constant(nil)) {
        self.entries = entries
        _selectedEntryID = selectedEntryID
    }

    public var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No clipboard history",
                systemImage: "doc.on.clipboard",
                description: Text("Copy something to start building your history.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries, id: \.id) { entry in
                        ClipboardRowView(entry: entry, isSelected: selectedEntryID == entry.id)
                            .onTapGesture { selectedEntryID = entry.id }
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

private struct ClipboardRowView: View {
    let entry: ClipboardEntry
    let isSelected: Bool

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
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 2)
        }
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

private extension ContentType {
    var badgeTitle: String {
        switch self {
        case .envVar: return "ENV"
        case .envVarBlock: return "ENV BLOCK"
        default: return rawValue.uppercased()
        }
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

    return ClipboardListView(entries: items)
        .frame(width: 420, height: 600)
        .padding()
}
