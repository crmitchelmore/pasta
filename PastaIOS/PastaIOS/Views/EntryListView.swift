import SwiftUI
import PastaCore
import PastaSync

struct EntryListView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var appState: AppState
    @State private var selectedFilter: ContentType?
    @State private var isRefreshing = false
    @State private var typeCounts: [ContentType: Int] = [:]

    private var displayedEntries: [ClipboardEntry] {
        appState.filteredEntries(contentType: selectedFilter)
    }

    private var groupedEntries: [(String, [ClipboardEntry])] {
        TimeGrouper.group(displayedEntries)
    }

    var body: some View {
        entryList
            .listStyle(.insetGrouped)
            .navigationTitle("Clipboard History")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await appState.performSync(syncManager: syncManager)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    syncStatusView
                }
            }
            .onChange(of: appState.entries.count) { _, _ in
                updateTypeCounts(appState.entries)
            }
            .onAppear {
                updateTypeCounts(appState.entries)
            }
    }

    private var entryList: some View {
        List {
            filterChips

            if displayedEntries.isEmpty {
                emptyState
            } else {
                ForEach(groupedEntries, id: \.0) { section, entries in
                    Section(section) {
                        ForEach(entries, id: \.id) { entry in
                            NavigationLink(destination: EntryDetailView(entry: entry)) {
                                EntryRowView(entry: entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func updateTypeCounts(_ entries: [ClipboardEntry]) {
        var counts: [ContentType: Int] = [:]
        for entry in entries {
            counts[entry.contentType, default: 0] += 1
        }
        typeCounts = counts
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "All",
                    count: appState.entries.count,
                    isSelected: selectedFilter == nil
                ) {
                    selectedFilter = nil
                }
                ForEach(availableTypes, id: \.self) { type in
                    FilterChip(
                        title: type.displayName,
                        icon: type.iconName,
                        count: typeCounts[type],
                        tintColor: type.tintColor,
                        isSelected: selectedFilter == type
                    ) {
                        selectedFilter = (selectedFilter == type) ? nil : type
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Content type filters")
    }

    private var availableTypes: [ContentType] {
        typeCounts.keys
            .filter { $0 != .unknown }
            .sorted { (typeCounts[$0] ?? 0) > (typeCounts[$1] ?? 0) }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "clipboard")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("No entries yet")
                    .font(.headline)
                Text("Copy something on your Mac and it will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Sync Status

    private var syncStatusView: some View {
        Group {
            switch syncManager.syncState {
            case .idle:
                if let date = syncManager.lastSyncDate {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .syncing:
                ProgressView()
                    .controlSize(.small)
            case .error:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.red)
            }
        }
    }
}
