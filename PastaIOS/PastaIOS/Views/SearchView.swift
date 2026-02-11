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
