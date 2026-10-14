import SwiftUI
import PastaCore
import PastaSync

struct EntryListView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedFilter: ContentType?
    @State private var isRefreshing = false
    @State private var typeCounts: [ContentType: Int] = [:]
    // Filtering and time grouping are O(n). Computed properties re-ran them on
    // every body pass, including each sync status change, so cache them.
    @State private var sections: [(String, [ClipboardEntry])] = []

    var body: some View {
        entryList
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("history.list")
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
            // `$entries` publishes before the property changes, so use the
            // delivered value rather than reading `appState.entries`.
            .onReceive(appState.$entries) { entries in
                rebuild(from: entries)
            }
            .onChange(of: selectedFilter) { _, _ in
                rebuild(from: appState.entries)
            }
            .onAppear {
                rebuild(from: appState.entries)
            }
            // Re-bucket relative sections ("Last Minute") as time passes.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { rebuild(from: appState.entries) }
            }
    }

    private var entryList: some View {
        List {
            filterChips

            if sections.isEmpty {
                // Before the first rebuild, avoid flashing the empty state.
                if appState.entries.isEmpty || selectedFilter != nil {
                    emptyState
                }
            } else {
                ForEach(sections, id: \.0) { section, entries in
                    Section(section) {
                        ForEach(entries, id: \.id) { entry in
                            NavigationLink(destination: EntryDetailView(entry: entry)) {
                                EntryRowView(entry: entry)
                            }
                            .accessibilityIdentifier("history.row")
                        }
                    }
                }
            }
        }
    }

    private func rebuild(from entries: [ClipboardEntry]) {
        var counts: [ContentType: Int] = [:]
        for entry in entries {
            counts[entry.contentType, default: 0] += 1
        }
        typeCounts = counts
        let filtered = selectedFilter.map { type in entries.filter { $0.contentType == type } } ?? entries
        sections = TimeGrouper.group(filtered)
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("history.emptyState")
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
