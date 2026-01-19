import AppKit
import SwiftUI

import PastaCore
import PastaUI

@main
struct PastaApp: App {
    // Keep this alive for the lifetime of the app.
    private let hotkeyManager: HotkeyManager

    init() {
        // Menu-bar-only experience (no Dock icon).
        NSApplication.shared.setActivationPolicy(.accessory)

        hotkeyManager = HotkeyManager {
            // Best-effort: make the app active so the user can interact with the menu bar popover.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
        } label: {
            Image("MenuBarIcon", bundle: .module)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}

private struct PopoverRootView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ClipboardEntry] = []

    @State private var searchQuery: String = ""
    @State private var isFuzzySearch: Bool = false
    @State private var contentTypeFilter: ContentType? = nil

    @State private var selectedEntryID: UUID? = nil

    private let database: DatabaseManager = {
        // UI fallback if the on-disk DB can't be created for any reason.
        (try? DatabaseManager()) ?? (try! DatabaseManager.inMemory())
    }()

    private var displayedEntries: [ClipboardEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if let contentTypeFilter {
                return entries.filter { $0.contentType == contentTypeFilter }
            }
            return entries
        }

        let searchService = SearchService(database: database)
        do {
            let matches = try searchService.search(
                query: trimmed,
                mode: isFuzzySearch ? .fuzzy : .exact,
                contentType: contentTypeFilter,
                limit: 200
            )
            return matches.map { $0.entry }
        } catch {
            return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pasta")
                    .font(.headline)

                Spacer()

                Button("Close") { dismiss() }
            }

            SearchBarView(
                query: $searchQuery,
                isFuzzy: $isFuzzySearch,
                contentType: $contentTypeFilter,
                resultCount: displayedEntries.count
            )

            HStack(alignment: .top, spacing: 12) {
                ClipboardListView(entries: displayedEntries, selectedEntryID: $selectedEntryID)
                    .frame(width: 320)

                PreviewPanelView(entry: displayedEntries.first(where: { $0.id == selectedEntryID }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Refresh") {
                    entries = (try? database.fetchRecent(limit: 1_000)) ?? []
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 900, height: 640)
        .onAppear {
            entries = (try? database.fetchRecent(limit: 1_000)) ?? []
        }
        .onChange(of: displayedEntries.map(\.id)) { _, ids in
            if let selectedEntryID, !ids.contains(selectedEntryID) {
                self.selectedEntryID = nil
            }
        }
    }
}
