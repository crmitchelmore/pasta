import SwiftUI
import PastaCore
import PastaSync

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedFilter: ContentType?
    @State private var results: [ClipboardEntry] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            filterChips

            if searchText.isEmpty {
                recentSearchesSection
            } else if results.isEmpty {
                noResultsView
            } else {
                ForEach(results, id: \.id) { entry in
                    NavigationLink(destination: EntryDetailView(entry: entry)) {
                        EntryRowView(entry: entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Search clipboard history")
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
        }
        .onChange(of: selectedFilter) { _, _ in
            performSearch(query: searchText)
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "All Types",
                    isSelected: selectedFilter == nil
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilter = nil
                    }
                }
                ForEach(availableTypes, id: \.self) { type in
                    FilterChip(
                        title: type.displayName,
                        icon: type.iconName,
                        tintColor: type.tintColor,
                        isSelected: selectedFilter == type
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFilter = (selectedFilter == type) ? nil : type
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search type filters")
    }

    private var availableTypes: [ContentType] {
        let typesInEntries = Set(appState.entries.map(\.contentType))
        return ContentType.allCases.filter { typesInEntries.contains($0) && $0 != .unknown }
    }

    private var recentSearchesSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Search your clipboard history")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Find text, URLs, code, emails, and more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .listRowBackground(Color.clear)
    }

    private var noResultsView: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No results for \"\(searchText)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .listRowBackground(Color.clear)
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            results = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            guard !Task.isCancelled else { return }

            let searchResults = await Task.detached(priority: .userInitiated) {
                appState.searchEntries(query: trimmed, contentType: selectedFilter)
            }.value

            await MainActor.run {
                guard !Task.isCancelled else { return }
                results = searchResults
            }
        }
    }
}
