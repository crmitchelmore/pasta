import PastaCore
import SwiftUI

// MARK: - Time Group Helpers

public enum TimeGroup: String, CaseIterable {
    case lastMinute = "Last Minute"
    case last5Minutes = "Last 5 Minutes"
    case last15Minutes = "Last 15 Minutes"
    case lastHour = "Last Hour"
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This Week"
    case older = "Older"
    
    public static func group(for date: Date, now: Date = Date()) -> TimeGroup {
        let interval = now.timeIntervalSince(date)
        let calendar = Calendar.current
        
        if interval < 60 { return .lastMinute }
        if interval < 300 { return .last5Minutes }
        if interval < 900 { return .last15Minutes }
        if interval < 3600 { return .lastHour }
        
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        if date > weekAgo { return .thisWeek }
        
        return .older
    }
}

// MARK: - Main List View

public struct ClipboardListView: View {
    public let entries: [ClipboardEntry]
    @Binding private var selectedEntryID: UUID?
    private let searchQuery: String
    private let filterType: ContentType?
    private let filterApp: String?
    private let onCopy: (ClipboardEntry) -> Void
    private let onPaste: (ClipboardEntry) -> Void
    private let onDelete: (ClipboardEntry) -> Void
    private let onDeleteMultiple: ([UUID]) -> Void
    private let onReveal: (ClipboardEntry) -> Void

    @State private var isSelectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var hoveredID: UUID? = nil
    @State private var deleteConfirmEntry: ClipboardEntry? = nil

    public init(
        entries: [ClipboardEntry],
        selectedEntryID: Binding<UUID?> = .constant(nil),
        searchQuery: String = "",
        filterType: ContentType? = nil,
        filterApp: String? = nil,
        onCopy: @escaping (ClipboardEntry) -> Void,
        onPaste: @escaping (ClipboardEntry) -> Void,
        onDelete: @escaping (ClipboardEntry) -> Void,
        onDeleteMultiple: @escaping ([UUID]) -> Void = { _ in },
        onReveal: @escaping (ClipboardEntry) -> Void
    ) {
        self.entries = entries
        _selectedEntryID = selectedEntryID
        self.searchQuery = searchQuery
        self.filterType = filterType
        self.filterApp = filterApp
        self.onCopy = onCopy
        self.onPaste = onPaste
        self.onDelete = onDelete
        self.onDeleteMultiple = onDeleteMultiple
        self.onReveal = onReveal
    }

    private var groupedEntries: [(String, [ClipboardEntry])] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If searching text, return flat list (no groups)
        if !trimmedQuery.isEmpty {
            return [("Results", entries)]
        }
        
        // Group by time
        let now = Date()
        var groups: [TimeGroup: [ClipboardEntry]] = [:]
        for entry in entries {
            let group = TimeGroup.group(for: entry.timestamp, now: now)
            groups[group, default: []].append(entry)
        }
        
        // Return in order, excluding empty groups
        return TimeGroup.allCases.compactMap { group in
            guard let items = groups[group], !items.isEmpty else { return nil }
            return (group.rawValue, items)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            listToolbar
            
            Divider()
            
            // List content
            if entries.isEmpty {
                ContentUnavailableView(
                    "No clipboard history",
                    systemImage: "doc.on.clipboard",
                    description: Text("Copy anything to build your history.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listContent
            }
        }
        .alert("Delete Entry?", isPresented: .init(
            get: { deleteConfirmEntry != nil },
            set: { if !$0 { deleteConfirmEntry = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteConfirmEntry = nil }
            Button("Delete", role: .destructive) {
                if let entry = deleteConfirmEntry {
                    onDelete(entry)
                    deleteConfirmEntry = nil
                }
            }
        } message: {
            if let entry = deleteConfirmEntry {
                Text("Delete \"\(entry.previewText.prefix(50))\"?")
            }
        }
    }
    
    @ViewBuilder
    private var listToolbar: some View {
        HStack {
            if isSelectionMode {
                Button {
                    if selectedIDs.count == entries.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(entries.map(\.id))
                    }
                } label: {
                    Text(selectedIDs.count == entries.count ? "Deselect All" : "Select All")
                }
                .buttonStyle(.borderless)
                
                Spacer()
                
                Text("\(selectedIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Delete Selected", role: .destructive) {
                    onDeleteMultiple(Array(selectedIDs))
                    selectedIDs.removeAll()
                    isSelectionMode = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedIDs.isEmpty)
                
                Button("Done") {
                    isSelectionMode = false
                    selectedIDs.removeAll()
                }
                .buttonStyle(.bordered)
            } else {
                Text("\(entries.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button {
                    isSelectionMode = true
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }
    
    @ViewBuilder
    private var listContent: some View {
        List(selection: isSelectionMode ? nil : $selectedEntryID) {
            ForEach(groupedEntries, id: \.0) { groupName, groupEntries in
                Section {
                    ForEach(groupEntries, id: \.id) { entry in
                        ClipboardRowView(
                            entry: entry,
                            isHovered: hoveredID == entry.id,
                            isSelected: isSelectionMode && selectedIDs.contains(entry.id),
                            isSelectionMode: isSelectionMode,
                            onDelete: { deleteConfirmEntry = entry },
                            onToggleSelect: {
                                if selectedIDs.contains(entry.id) {
                                    selectedIDs.remove(entry.id)
                                } else {
                                    selectedIDs.insert(entry.id)
                                }
                            }
                        )
                        .tag(entry.id)
                        .onHover { isHovered in
                            hoveredID = isHovered ? entry.id : nil
                        }
                        .contextMenu {
                            Button("Paste") { onPaste(entry) }
                            Button("Copy") { onCopy(entry) }
                            Divider()
                            Button("Delete", role: .destructive) { deleteConfirmEntry = entry }
                            if entry.contentType == .filePath {
                                Divider()
                                Button("Reveal in Finder") { onReveal(entry) }
                            }
                        }
                    }
                } header: {
                    if groupedEntries.count > 1 || groupedEntries.first?.0 != "Results" {
                        Text(groupName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Row View

private struct ClipboardRowView: View {
    let entry: ClipboardEntry
    let isHovered: Bool
    let isSelected: Bool
    let isSelectionMode: Bool
    let onDelete: () -> Void
    let onToggleSelect: () -> Void

    private var isLarge: Bool {
        entry.content.utf8.count > 10 * 1024
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Selection checkbox (in selection mode)
            if isSelectionMode {
                Button {
                    onToggleSelect()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            
            // Content type icon
            Image(systemName: entry.contentType.systemImageName)
                .foregroundStyle(entry.contentType.tint)
                .frame(width: 18)

            // Content
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
            
            // Delete button (on hover, not in selection mode)
            if isHovered && !isSelectionMode {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Supporting Views

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

// MARK: - Extensions

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
    var displayName: String {
        let parts = self.split(separator: ".")
        if let last = parts.last {
            return String(last).capitalized
        }
        return self
    }
}

#Preview {
    let base = ClipboardEntry(content: "Hello world", contentType: .text)
    let items = (0..<50).map { idx in
        var e = base
        e.content = "Item \(idx): \(String(repeating: "x", count: (idx % 40) + 1))"
        e.timestamp = Date().addingTimeInterval(-Double(idx) * 60) // Spread over time
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
}
