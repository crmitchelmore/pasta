import AppKit
import PastaCore
import SwiftUI

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
    private let isLoading: Bool
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

    /// Entries awaiting the delete confirmation; empty while the alert is hidden.
    @State private var deleteConfirmEntries: [ClipboardEntry] = []

    /// Memoizes per-entry row models across body evaluations (reference type:
    /// mutating it during body must not invalidate the view).
    @State private var rowModelCache = ClipboardRowModelCache()

    /// Whether we can show the "values only" toggle (filtering by extractable type)
    private var canShowValuesToggle: Bool {
        guard let filterType else { return false }
        return MetadataParser.extractableTypes.contains(filterType)
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
        isLoading: Bool = false,
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
        self.isLoading = isLoading
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

    /// Resolves a row callback to the current entry. `entries` is at most one
    /// page (200), so a linear scan beats a cached lookup that could go stale.
    private func entry(for id: UUID) -> ClipboardEntry? {
        entries.first { $0.id == id }
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
        .alert(deleteConfirmTitle, isPresented: .init(
            get: { !deleteConfirmEntries.isEmpty },
            set: { if !$0 { deleteConfirmEntries = [] } }
        )) {
            Button("Cancel", role: .cancel) { deleteConfirmEntries = [] }
            Button("Delete", role: .destructive, action: performConfirmedDelete)
        } message: {
            Text(deleteConfirmMessage)
        }
    }

    private var deleteConfirmTitle: String {
        deleteConfirmEntries.count > 1 ? "Delete \(deleteConfirmEntries.count) Entries?" : "Delete Entry?"
    }

    private var deleteConfirmMessage: String {
        if deleteConfirmEntries.count == 1, let entry = deleteConfirmEntries.first {
            return "Delete \"\(entry.content.prefix(50))\"?"
        }
        return "This permanently deletes the selected entries."
    }

    private func performConfirmedDelete() {
        let pending = deleteConfirmEntries
        deleteConfirmEntries = []
        if pending.count == 1, let entry = pending.first {
            onDelete(entry)
        } else if !pending.isEmpty {
            onDeleteMultiple(pending.map(\.id))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            ContentUnavailableView(
                "Loading clipboard history",
                systemImage: "clock.arrow.circlepath",
                description: Text("Recent items will appear shortly.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasClipboardHistory && isFiltered {
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
        let selectedEntries = selectedEntriesInDisplayOrder
        let selectedCount = selectedEntries.count
        let primaryEntry = primarySelectedEntry

        HStack {
            Text(selectedCount > 0 ? "\(selectedCount) selected" : "\(entries.count) items")
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
                .disabled(selectedCount != 1 || primaryEntry == nil)
                .help("Paste selected item")

                if let onTogglePin, let primaryEntry, selectedCount == 1 {
                    Button {
                        onTogglePin(primaryEntry)
                    } label: {
                        Image(systemName: primaryEntry.isPinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(primaryEntry.isPinned ? "Unpin selected item" : "Pin selected item")
                }

                Button(role: .destructive) {
                    deleteConfirmEntries = selectedEntries
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(selectedCount > 1 ? "Delete selected items" : "Delete selected item")
            }

            // Show "Values Only" toggle when filtering by extractable type
            if canShowValuesToggle {
                Toggle("Values Only", isOn: $showExtractedValuesOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show only the extracted \(filterType?.displayTitle.lowercased() ?? "items") instead of full text")
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
                Text("API key capture is disabled in Settings → Clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("API keys are being captured. Disable in Settings → Clipboard if needed.")
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
        } else {
            // High-performance NSTableView; ⇧/⌘-click and ⌘A multi-select.
            HighPerformanceListView(
                rows: buildHighPerfRows(),
                selectedID: $selectedEntryID,
                selectedIDs: $selectedEntryIDs,
                onPaste: { id in
                    if let entry = entry(for: id) { onPaste(entry) }
                },
                onCopy: { id in
                    if let entry = entry(for: id) { onCopy(entry) }
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
                    if let entry = entry(for: id) { deleteConfirmEntries = [entry] }
                },
                onReveal: { id in
                    if let entry = entry(for: id) { onReveal(entry) }
                },
                onOpenURL: onOpenURL.map { handler in
                    { id in
                        if let entry = entry(for: id) { handler(entry) }
                    }
                },
                onTogglePin: onTogglePin.map { handler in
                    { id in
                        if let entry = entry(for: id) { handler(entry) }
                    }
                }
            )
        }
    }

    /// Builds the row list for the NSTableView, prepending a "Pinned" section
    /// header + pinned entries when any pinned items exist. Row models are
    /// memoized in `rowModelCache` so body evaluations don't redo per-row
    /// string work for unchanged entries.
    private func buildHighPerfRows() -> [ClipboardRowData] {
        let allRows = rowModelCache.rows(for: entries)

        var pinned: [ClipboardRowData] = []
        var unpinned: [ClipboardRowData] = []
        pinned.reserveCapacity(allRows.count)
        unpinned.reserveCapacity(allRows.count)
        for row in allRows {
            if row.isPinned {
                pinned.append(row)
            } else {
                unpinned.append(row)
            }
        }

        guard !pinned.isEmpty else {
            return allRows
        }

        var rows: [ClipboardRowData] = []
        rows.reserveCapacity(allRows.count + 2)
        rows.append(.header("Pinned"))
        rows.append(contentsOf: pinned)
        if !unpinned.isEmpty {
            rows.append(.header("History"))
            rows.append(contentsOf: unpinned)
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
                        CopyableValueRow(
                            type: item.type,
                            value: item.value,
                            displayValue: item.displayValue,
                            sourcePreview: item.sourcePreview,
                            style: .list
                        )
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
