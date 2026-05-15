import AppKit
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
        self.sourceAppName = entry.sourceApp?.appDisplayName
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
    @Binding private var selectedEntryIDs: Set<UUID>
    private let searchQuery: String
    private let filterType: ContentType?
    private let filterApp: String?
    @Binding private var showExtractedValuesOnly: Bool
    private let hasClipboardHistory: Bool
    private let isFiltered: Bool
    private let onClearSearch: (() -> Void)?
    private let onClearFilters: (() -> Void)?
    private let onCopy: (ClipboardEntry) -> Void
    private let onCopyMultiple: ([ClipboardEntry]) -> Void
    private let onPaste: (ClipboardEntry) -> Void
    private let onDelete: (ClipboardEntry) -> Void
    private let onDeleteMultiple: ([UUID]) -> Void
    private let onReveal: (ClipboardEntry) -> Void
    private let onOpenURL: ((ClipboardEntry) -> Void)?
    private let onTogglePin: ((ClipboardEntry) -> Void)?

    @State private var isSelectionMode = false
    @State private var bulkSelectedIDs: Set<UUID> = []
    @State private var deleteConfirmEntry: ClipboardEntry? = nil
    
    // Cached computed data for performance
    @State private var sections: [SectionData] = []
    @State private var entryLookup: [UUID: ClipboardEntry] = [:]
    @State private var lastDataHash: Int = 0
    
    /// Whether we can show the "values only" toggle (filtering by extractable type)
    private var canShowValuesToggle: Bool {
        guard let filterType else { return false }
        return MetadataParser.extractableTypes.contains(filterType)
    }

    private var bulkSelectedEntriesInDisplayOrder: [ClipboardEntry] {
        entries.filter { bulkSelectedIDs.contains($0.id) }
    }

    private var selectedEntriesInDisplayOrder: [ClipboardEntry] {
        let ids = selectedEntryIDs.isEmpty ? Set([selectedEntryID].compactMap { $0 }) : selectedEntryIDs
        return entries.filter { ids.contains($0.id) }
    }

    private var primarySelectedEntry: ClipboardEntry? {
        if let selectedEntryID, let entry = entries.first(where: { $0.id == selectedEntryID }) {
            return entry
        }
        return selectedEntriesInDisplayOrder.first
    }

    public init(
        entries: [ClipboardEntry],
        selectedEntryID: Binding<UUID?> = .constant(nil),
        selectedEntryIDs: Binding<Set<UUID>> = .constant([]),
        searchQuery: String = "",
        filterType: ContentType? = nil,
        filterApp: String? = nil,
        showExtractedValuesOnly: Binding<Bool> = .constant(false),
        hasClipboardHistory: Bool? = nil,
        isFiltered: Bool = false,
        onClearSearch: (() -> Void)? = nil,
        onClearFilters: (() -> Void)? = nil,
        onCopy: @escaping (ClipboardEntry) -> Void,
        onCopyMultiple: @escaping ([ClipboardEntry]) -> Void = { _ in },
        onPaste: @escaping (ClipboardEntry) -> Void,
        onDelete: @escaping (ClipboardEntry) -> Void,
        onDeleteMultiple: @escaping ([UUID]) -> Void = { _ in },
        onReveal: @escaping (ClipboardEntry) -> Void,
        onOpenURL: ((ClipboardEntry) -> Void)? = nil,
        onTogglePin: ((ClipboardEntry) -> Void)? = nil
    ) {
        self.entries = entries
        _selectedEntryID = selectedEntryID
        _selectedEntryIDs = selectedEntryIDs
        self.searchQuery = searchQuery
        self.filterType = filterType
        self.filterApp = filterApp
        _showExtractedValuesOnly = showExtractedValuesOnly
        self.hasClipboardHistory = hasClipboardHistory ?? !entries.isEmpty
        self.isFiltered = isFiltered
        self.onClearSearch = onClearSearch
        self.onClearFilters = onClearFilters
        self.onCopy = onCopy
        self.onCopyMultiple = onCopyMultiple
        self.onPaste = onPaste
        self.onDelete = onDelete
        self.onDeleteMultiple = onDeleteMultiple
        self.onReveal = onReveal
        self.onOpenURL = onOpenURL
        self.onTogglePin = onTogglePin
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
                emptyState
            } else {
                listContent
            }
        }
        // Keep cached sections and selection state in sync as the displayed entries change.
        .onChange(of: dataChangeToken) { _, _ in rebuildSections() }
        .onAppear { rebuildSections() }
        .onChange(of: entries.map(\.id)) { _, ids in
            let visibleIDs = Set(ids)
            let filteredSelection = bulkSelectedIDs.intersection(visibleIDs)
            if filteredSelection != bulkSelectedIDs {
                bulkSelectedIDs = filteredSelection
            }
            if ids.isEmpty, isSelectionMode {
                isSelectionMode = false
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
                Text("Delete \"\(entry.content.prefix(50))\"?")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasClipboardHistory && isFiltered {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("No clipboard items match the current search or filters.")
            } actions: {
                HStack(spacing: 8) {
                    if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let onClearSearch {
                        Button("Clear Search", action: onClearSearch)
                            .buttonStyle(.bordered)
                    }
                    if let onClearFilters {
                        Button("Clear Filters", action: onClearFilters)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No clipboard history",
                systemImage: "doc.on.clipboard",
                description: Text("Copy anything to build your history.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private var listToolbar: some View {
        let bulkSelectedEntries = bulkSelectedEntriesInDisplayOrder
        let bulkSelectedCount = bulkSelectedEntries.count
        let selectedEntries = selectedEntriesInDisplayOrder
        let normalSelectedCount = selectedEntries.count
        let primaryEntry = primarySelectedEntry

        Group {
            if isSelectionMode {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            if bulkSelectedCount == entries.count {
                                bulkSelectedIDs.removeAll()
                            } else {
                                bulkSelectedIDs = Set(entries.map(\.id))
                            }
                        } label: {
                            Text(bulkSelectedCount == entries.count ? "Deselect All" : "Select All")
                        }
                        .buttonStyle(.borderless)

                        Spacer(minLength: 8)

                        Text("\(bulkSelectedCount) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Button("Done") {
                            isSelectionMode = false
                            bulkSelectedIDs.removeAll()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 8) {
                        Button {
                            onCopyMultiple(bulkSelectedEntries)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .disabled(bulkSelectedEntries.isEmpty)

                        Button("Delete", role: .destructive) {
                            onDeleteMultiple(Array(bulkSelectedIDs))
                            bulkSelectedIDs.removeAll()
                            isSelectionMode = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(bulkSelectedEntries.isEmpty)

                        Spacer(minLength: 0)
                    }
                }
                .controlSize(.small)
            } else {
                HStack {
                    Text(normalSelectedCount > 0 ? "\(normalSelectedCount) selected" : "\(entries.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !selectedEntries.isEmpty {
                        Button {
                            if selectedEntries.count > 1 {
                                onCopyMultiple(selectedEntries)
                            } else if let primaryEntry {
                                onCopy(primaryEntry)
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(selectedEntries.count > 1 ? "Copy selected items" : "Copy selected item")

                        Button {
                            if let primaryEntry {
                                onPaste(primaryEntry)
                            }
                        } label: {
                            Image(systemName: "arrowshape.turn.up.right")
                        }
                        .buttonStyle(.borderless)
                        .disabled(normalSelectedCount != 1 || primaryEntry == nil)
                        .help("Paste selected item")

                        if let onTogglePin, let primaryEntry, normalSelectedCount == 1 {
                            Button {
                                onTogglePin(primaryEntry)
                            } label: {
                                Image(systemName: primaryEntry.isPinned ? "pin.slash" : "pin")
                            }
                            .buttonStyle(.borderless)
                            .help(primaryEntry.isPinned ? "Unpin selected item" : "Pin selected item")
                        }

                        Button(role: .destructive) {
                            if let primaryEntry {
                                deleteConfirmEntry = primaryEntry
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(normalSelectedCount != 1 || primaryEntry == nil)
                        .help("Delete selected item")
                    }

                    // Show "Values Only" toggle when filtering by extractable type
                    if canShowValuesToggle {
                        Toggle("Values Only", isOn: $showExtractedValuesOnly)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help("Show only the extracted \(filterType?.displayTitle.lowercased() ?? "items") instead of full text")
                    }

                    Button {
                        bulkSelectedIDs = selectedEntryIDs.isEmpty
                            ? Set([selectedEntryID].compactMap { $0 })
                            : selectedEntryIDs
                        isSelectionMode = true
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                }
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
        if showExtractedValuesOnly && canShowValuesToggle, let filterType {
            // Show extracted values only mode
            extractedValuesListView(for: filterType)
        } else if isSelectionMode {
            // Use SwiftUI List for selection mode (less performance critical)
            selectionModeList
        } else {
            // Use high-performance NSTableView for normal browsing
            HighPerformanceListView(
                rows: buildHighPerfRows(),
                selectedID: $selectedEntryID,
                selectedIDs: $selectedEntryIDs,
                onPaste: { id in
                    if let entry = entryLookup[id] { onPaste(entry) }
                },
                onCopy: { id in
                    if let entry = entryLookup[id] { onCopy(entry) }
                },
                onCopyMultiple: { ids in
                    let selectedEntries = entries.filter { ids.contains($0.id) }
                    if selectedEntries.count == 1, let entry = selectedEntries.first {
                        onCopy(entry)
                    } else {
                        onCopyMultiple(selectedEntries)
                    }
                },
                onDelete: { id in
                    if let entry = entryLookup[id] { deleteConfirmEntry = entry }
                },
                onReveal: { id in
                    if let entry = entryLookup[id] { onReveal(entry) }
                },
                onOpenURL: onOpenURL.map { handler in
                    { id in
                        if let entry = entryLookup[id] { handler(entry) }
                    }
                },
                onTogglePin: onTogglePin.map { handler in
                    { id in
                        if let entry = entryLookup[id] { handler(entry) }
                    }
                }
            )
        }
    }

    /// Builds the row list for the NSTableView, prepending a "Pinned" section
    /// header + pinned entries when any pinned items exist.
    private func buildHighPerfRows() -> [ClipboardRowData] {
        var pinned: [ClipboardEntry] = []
        var unpinned: [ClipboardEntry] = []
        pinned.reserveCapacity(entries.count)
        unpinned.reserveCapacity(entries.count)
        for entry in entries {
            if entry.isPinned {
                pinned.append(entry)
            } else {
                unpinned.append(entry)
            }
        }

        guard !pinned.isEmpty else {
            return entries.map { ClipboardRowData(from: $0) }
        }

        var rows: [ClipboardRowData] = []
        rows.reserveCapacity(entries.count + 2)
        rows.append(.header("Pinned"))
        rows.append(contentsOf: pinned.map { ClipboardRowData(from: $0) })
        if !unpinned.isEmpty {
            rows.append(.header("History"))
            rows.append(contentsOf: unpinned.map { ClipboardRowData(from: $0) })
        }
        return rows
    }
    
    /// View showing only extracted values for the filtered type
    @ViewBuilder
    private func extractedValuesListView(for type: ContentType) -> some View {
        let allValues = extractedValuesForType(type)
        
        if allValues.isEmpty {
            ContentUnavailableView(
                "No \(type.displayTitle.lowercased()) found",
                systemImage: type.systemImageName,
                description: Text("No extracted values of this type.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(allValues) { item in
                        ExtractedValueRow(item: item)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        }
    }
    
    /// Extract all values of the given type from all displayed entries
    private func extractedValuesForType(_ type: ContentType) -> [ExtractedValueItem] {
        var results: [ExtractedValueItem] = []
        
        for entry in entries {
            let values = entry.extractedValues(for: type)
            for value in values {
                results.append(ExtractedValueItem(
                    value: value.value,
                    displayValue: value.displayValue,
                    type: type,
                    sourceEntryID: entry.id,
                    sourcePreview: String(entry.content.prefix(50))
                ))
            }
            
            // Also include the entry itself if its primary type matches
            if entry.contentType == type {
                results.append(ExtractedValueItem(
                    value: entry.content,
                    displayValue: String(entry.content.prefix(100)),
                    type: type,
                    sourceEntryID: entry.id,
                    sourcePreview: nil
                ))
            }
        }
        
        // Remove duplicates by value
        var seen: Set<String> = []
        return results.filter { item in
            if seen.contains(item.value) { return false }
            seen.insert(item.value)
            return true
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
                                isSelected: bulkSelectedIDs.contains(row.id)
                            )
                            .id(row.id)
                            .tag(row.id)
                            .onTapGesture {
                                if bulkSelectedIDs.contains(row.id) {
                                    bulkSelectedIDs.remove(row.id)
                                } else {
                                    bulkSelectedIDs.insert(row.id)
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
    var displayName: String { appDisplayName }
}

// MARK: - Extracted Value Types

/// Item representing an extracted value from an entry
private struct ExtractedValueItem: Identifiable {
    let id = UUID()
    let value: String
    let displayValue: String
    let type: ContentType
    let sourceEntryID: UUID
    let sourcePreview: String?  // nil if this IS the primary entry
}

/// Row view for displaying an extracted value
private struct ExtractedValueRow: View {
    let item: ExtractedValueItem
    @State private var copied = false
    
    var body: some View {
        Button {
            copyToClipboard()
        } label: {
            HStack(spacing: 10) {
                // Type icon
                Image(systemName: item.type.systemImageName)
                    .foregroundStyle(item.type.tint)
                    .frame(width: 20)
                
                // Value
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayValue)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    
                    if let source = item.sourcePreview {
                        Text("from: \(source)...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                
                Spacer(minLength: 4)
                
                // Copy indicator
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
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
        onCopyMultiple: { _ in },
        onPaste: { _ in },
        onDelete: { _ in },
        onReveal: { _ in }
    )
    .frame(width: 420, height: 600)
}
