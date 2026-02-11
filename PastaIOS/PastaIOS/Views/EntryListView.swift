import SwiftUI
import PastaCore
import PastaSync

struct EntryListView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var appState: AppState
    @State private var selectedFilter: ContentType?
    @State private var isRefreshing = false

    private var displayedEntries: [ClipboardEntry] {
        appState.filteredEntries(contentType: selectedFilter)
    }

    private var groupedEntries: [(String, [ClipboardEntry])] {
        TimeGrouper.group(displayedEntries)
    }

    var body: some View {
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
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", isSelected: selectedFilter == nil) {
                    selectedFilter = nil
                }
                ForEach(availableTypes, id: \.self) { type in
                    FilterChip(
                        title: type.displayName,
                        icon: type.iconName,
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
    }

    private var availableTypes: [ContentType] {
        let typesInEntries = Set(appState.entries.map(\.contentType))
        return ContentType.allCases.filter { typesInEntries.contains($0) && $0 != .unknown }
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
