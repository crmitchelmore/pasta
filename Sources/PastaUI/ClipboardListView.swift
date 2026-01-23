import PastaCore
import SwiftUI

// MARK: - Time Group Helpers

public enum TimeGroup: String, CaseIterable, Sendable {
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

// MARK: - Lightweight Row Data (for Equatable diffing)

/// Minimal data needed to render a row - used for efficient diffing
private struct RowData: Equatable, Identifiable {
    let id: UUID
    let previewText: String
    let contentType: ContentType
    let sourceAppName: String?
    let timestamp: Date
    let copyCount: Int
    let isLarge: Bool
    let hasFilePath: Bool
    let isExtracted: Bool
    let parentEntryId: UUID?
    
    init(from entry: ClipboardEntry) {
        self.id = entry.id
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.previewText = trimmed.isEmpty ? "(empty)" : String(trimmed.prefix(200))
        self.contentType = entry.contentType
        self.sourceAppName = entry.sourceApp?.displayName
        self.timestamp = entry.timestamp
        self.copyCount = entry.copyCount
        self.isLarge = entry.content.utf8.count > 10 * 1024
        self.hasFilePath = entry.contentType == .filePath
        self.isExtracted = entry.isExtracted
        self.parentEntryId = entry.parentEntryId
    }
}

// MARK: - Grouped Section Data

private struct SectionData: Identifiable {
    let id: String  // group name as ID
    let name: String
    let rows: [RowData]
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
    @State private var deleteConfirmEntry: ClipboardEntry? = nil
    
    // Cached computed data for performance
    @State private var sections: [SectionData] = []
    @State private var entryLookup: [UUID: ClipboardEntry] = [:]
    @State private var lastDataHash: Int = 0

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

    /// Compute a stable hash for change detection
    private var dataChangeToken: Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        hasher.combine(searchQuery)
        // Include first/last entry IDs for content change detection
        if let first = entries.first { hasher.combine(first.id) }
        if let last = entries.last { hasher.combine(last.id) }
        return hasher.finalize()
    }
    
    /// Rebuild cached section data - runs off main thread implicitly via onChange
    private func rebuildSections() {
        let newHash = dataChangeToken
        guard newHash != lastDataHash else { return }
        lastDataHash = newHash
        
        // Build lookup table for callbacks
        var lookup: [UUID: ClipboardEntry] = [:]
        lookup.reserveCapacity(entries.count)
        for entry in entries {
            lookup[entry.id] = entry
        }
        entryLookup = lookup
        
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If searching, return flat list
        if !trimmedQuery.isEmpty {
            let rows = entries.map { RowData(from: $0) }
            sections = [SectionData(id: "Results", name: "Results", rows: rows)]
            return
        }
        
        // Group by time
        let now = Date()
        var groups: [TimeGroup: [RowData]] = [:]
        for entry in entries {
            let group = TimeGroup.group(for: entry.timestamp, now: now)
            groups[group, default: []].append(RowData(from: entry))
        }
        
        // Build sections in order
        var result: [SectionData] = []
        for group in TimeGroup.allCases {
            guard let rows = groups[group], !rows.isEmpty else { continue }
            result.append(SectionData(
                id: group.rawValue,
                name: group.rawValue,
                rows: rows
            ))
        }
        sections = result
    }

    public var body: some View {
        VStack(spacing: 0) {
            listToolbar
            Divider()
            
            // Show note when viewing API keys with skip enabled
            if filterType == .apiKey {
                apiKeyNotice
            }
            
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
        // Use a single change listener on computed hash instead of multiple onChange
        .onChange(of: dataChangeToken) { _, _ in rebuildSections() }
        .onAppear { rebuildSections() }
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
                Text("Delete \"\(entry.content.prefix(50))\"?")
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
    private var apiKeyNotice: some View {
        let skipEnabled = UserDefaults.standard.bool(forKey: "pasta.skipAPIKeys")
        
        HStack(spacing: 8) {
            Image(systemName: skipEnabled ? "eye.slash" : "eye")
                .foregroundStyle(skipEnabled ? .orange : .secondary)
            
            if skipEnabled {
                Text("API key capture is disabled in Settings → Security")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("API keys are being captured. Disable in Settings → Security if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(skipEnabled ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.1))
    }
    
    @ViewBuilder
    private var listContent: some View {
        if isSelectionMode {
            // Use SwiftUI List for selection mode (less performance critical)
            selectionModeList
        } else {
            // Use high-performance NSTableView for normal browsing
            HighPerformanceListView(
                rows: entries.map { ClipboardRowData(from: $0) },
                selectedID: $selectedEntryID,
                onPaste: { id in
                    if let entry = entryLookup[id] { onPaste(entry) }
                },
                onCopy: { id in
                    if let entry = entryLookup[id] { onCopy(entry) }
                },
                onDelete: { id in
                    if let entry = entryLookup[id] { deleteConfirmEntry = entry }
                },
                onReveal: { id in
                    if let entry = entryLookup[id] { onReveal(entry) }
                }
            )
        }
    }
    
    @ViewBuilder
    private var selectionModeList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedEntryID) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            SelectionModeRowView(
                                row: row,
                                isSelected: selectedIDs.contains(row.id)
                            )
                            .id(row.id)
                            .tag(row.id)
                            .onTapGesture {
                                if selectedIDs.contains(row.id) {
                                    selectedIDs.remove(row.id)
                                } else {
                                    selectedIDs.insert(row.id)
                                }
                            }
                        }
                    } header: {
                        if sections.count > 1 || sections.first?.name != "Results" {
                            Text(section.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Selection Mode Row View (simplified)

private struct SelectionModeRowView: View {
    let row: RowData
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Selection checkbox
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.title3)
            
            // Content type icon
            Image(systemName: row.contentType.systemImageName)
                .foregroundStyle(row.contentType.tint)
                .frame(width: 18)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(row.previewText)
                    .lineLimit(2)
                    .font(.body)

                HStack(spacing: 8) {
                    ContentTypeBadge(type: row.contentType)
                    
                    if let appName = row.sourceAppName {
                        Text(appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(row.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if row.copyCount > 1 {
                        Text("×\(row.copyCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer(minLength: 0)
            
            if row.isLarge {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Large entry (>10KB)")
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
        e.timestamp = Date().addingTimeInterval(-Double(idx) * 60)
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
