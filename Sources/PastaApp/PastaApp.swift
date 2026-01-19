import AppKit
import SwiftUI

import PastaCore
import PastaDetectors
import PastaUI

// (PastaTheme lives in PastaUI)

@main
struct PastaApp: App {
    // Keep this alive for the lifetime of the app.
    @StateObject private var hotkeyManager: HotkeyManager

    init() {
        // Menu-bar-only experience (no Dock icon).
        NSApplication.shared.setActivationPolicy(.accessory)

        _hotkeyManager = StateObject(wrappedValue: HotkeyManager {
            // Best-effort: make the app active so the user can interact with the menu bar popover.
            NSApplication.shared.activate(ignoringOtherApps: true)
        })
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
        } label: {
            Image("MenuBarIcon", bundle: .module)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

private struct PopoverRootView: View {
    private enum Defaults {
        static let didCompleteOnboarding = "pasta.onboarding.completed"
    }

    @Environment(\.dismiss) private var dismiss

    @AppStorage(Defaults.didCompleteOnboarding) private var didCompleteOnboarding: Bool = false

    @State private var entries: [ClipboardEntry] = []

    @State private var searchQuery: String = ""
    @State private var isFuzzySearch: Bool = false
    @State private var contentTypeFilter: ContentType? = nil
    @State private var urlDomainFilter: String? = nil

    @State private var selectedEntryID: UUID? = nil

    @State private var isShowingDeleteConfirmation: Bool = false
    @State private var isShowingBulkDelete: Bool = false
    @State private var lastBulkDeleteSummary: String? = nil

    @State private var isShowingOnboarding: Bool = false

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private let database: DatabaseManager = {
        // UI fallback if the on-disk DB can't be created for any reason.
        (try? DatabaseManager()) ?? (try! DatabaseManager.inMemory())
    }()

    private var displayedEntries: [ClipboardEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        func applyFilters(_ input: [ClipboardEntry]) -> [ClipboardEntry] {
            var out = input
            if let contentTypeFilter {
                out = out.filter { $0.contentType == contentTypeFilter }
            }
            if contentTypeFilter == .url, let urlDomainFilter {
                let detector = URLDetector()
                out = out.filter { entry in
                    Set(detector.detect(in: entry.content).map(\.domain)).contains(urlDomainFilter)
                }
            }
            return out
        }

        if trimmed.isEmpty {
            return applyFilters(entries)
        }

        let searchService = SearchService(database: database)
        do {
            let matches = try searchService.search(
                query: trimmed,
                mode: isFuzzySearch ? .fuzzy : .exact,
                contentType: contentTypeFilter,
                limit: 200
            )
            return applyFilters(matches.map { $0.entry })
        } catch {
            return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pasta")
                    .font(.headline)
                    .foregroundStyle(PastaTheme.accent)

                Spacer()

                Button("Close") { dismiss() }
            }

            SearchBarView(
                query: $searchQuery,
                isFuzzy: $isFuzzySearch,
                contentType: $contentTypeFilter,
                resultCount: displayedEntries.count,
                searchFocused: $searchFocused
            )

            HStack(alignment: .top, spacing: 12) {
                FilterSidebarView(
                    entries: entries,
                    selectedContentType: $contentTypeFilter,
                    selectedURLDomain: $urlDomainFilter
                )
                .frame(width: 180)

                ClipboardListView(entries: displayedEntries, selectedEntryID: $selectedEntryID)
                    .frame(width: 320)
                    .focusable()
                    .focused($listFocused)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(listFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 2)
                    }

                PreviewPanelView(entry: displayedEntries.first(where: { $0.id == selectedEntryID }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Refresh") {
                    refreshEntries()
                }

                Button("Delete…") {
                    isShowingDeleteConfirmation = true
                }
                .disabled(selectedEntryID == nil)

                Button("Delete Recent…") {
                    isShowingBulkDelete = true
                }
                .disabled(entries.isEmpty)

                if let lastBulkDeleteSummary {
                    Text(lastBulkDeleteSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .tint(PastaTheme.accent)
        .frame(width: 900, height: 640)
        .onAppear {
            refreshEntries()
            if selectedEntryID == nil {
                selectedEntryID = displayedEntries.first?.id
            }
            DispatchQueue.main.async {
                searchFocused = true
            }

            isShowingOnboarding = !didCompleteOnboarding || !AccessibilityPermission.isTrusted()
        }
        .onChange(of: contentTypeFilter) { _, newValue in
            if newValue != .url {
                urlDomainFilter = nil
            }
        }
        .onChange(of: displayedEntries.map(\.id)) { _, ids in
            if let selectedEntryID, !ids.contains(selectedEntryID) {
                self.selectedEntryID = nil
            }
            if self.selectedEntryID == nil, let first = ids.first {
                self.selectedEntryID = first
            }
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .sheet(isPresented: $isShowingDeleteConfirmation) {
            DeleteConfirmationView(entry: displayedEntries.first(where: { $0.id == selectedEntryID })) {
                deleteSelectedEntry()
            }
        }
        .sheet(isPresented: $isShowingBulkDelete) {
            BulkDeleteView(entries: entries) { minutes in
                do {
                    let imageStorage = try ImageStorageManager()
                    let deleteService = DeleteService(database: database, imageStorage: imageStorage)
                    let count = try deleteService.deleteRecent(minutes: minutes)
                    lastBulkDeleteSummary = "Deleted \(count)"
                    refreshEntries()
                } catch {
                    lastBulkDeleteSummary = "Delete failed"
                }
            }
        }
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView { completion in
                switch completion {
                case .dismissed:
                    isShowingOnboarding = false
                case .completed:
                    didCompleteOnboarding = true
                    isShowingOnboarding = false
                }
            }
        }
    }

    private func refreshEntries() {
        entries = (try? database.fetchRecent(limit: 1_000)) ?? []
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .escape:
            dismiss()
            return .handled

        case .tab:
            if keyPress.modifiers.contains(.shift) {
                // Shift+Tab: reverse cycle.
                if listFocused {
                    listFocused = false
                    searchFocused = true
                } else {
                    searchFocused = false
                    listFocused = true
                }
            } else {
                if searchFocused {
                    searchFocused = false
                    listFocused = true
                } else {
                    listFocused = false
                    searchFocused = true
                }
            }
            return .handled

        case .upArrow:
            moveSelection(delta: -1)
            return .handled

        case .downArrow:
            moveSelection(delta: 1)
            return .handled

        case .return:
            pasteSelectedEntry()
            return .handled

        case .delete:
            if keyPress.modifiers.contains(.command) {
                isShowingDeleteConfirmation = true
                return .handled
            }
            return .ignored

        default:
            break
        }

        // Quick paste (1-9)
        let chars = keyPress.characters
        if keyPress.modifiers.isEmpty, chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
            quickPaste(index: digit - 1)
            return .handled
        }

        return .ignored
    }

    private func moveSelection(delta: Int) {
        guard !displayedEntries.isEmpty else { return }

        let currentIndex: Int
        if let selectedEntryID, let idx = displayedEntries.firstIndex(where: { $0.id == selectedEntryID }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }

        let nextIndex = min(max(currentIndex + delta, 0), displayedEntries.count - 1)
        selectedEntryID = displayedEntries[nextIndex].id
    }

    private func quickPaste(index: Int) {
        guard index >= 0, index < displayedEntries.count else { return }
        selectedEntryID = displayedEntries[index].id
        pasteSelectedEntry()
    }

    private func pasteSelectedEntry() {
        guard let selectedEntryID,
              let entry = displayedEntries.first(where: { $0.id == selectedEntryID }) else { return }

        _ = PasteService().paste(entry)

        dismiss()
        NSApplication.shared.hide(nil)
    }

    private func deleteSelectedEntry() {
        guard let selectedEntryID else { return }

        do {
            let imageStorage = try ImageStorageManager()
            let deleteService = DeleteService(database: database, imageStorage: imageStorage)
            _ = try deleteService.delete(id: selectedEntryID)
            refreshEntries()
        } catch {
            // Ignore and keep UI responsive.
        }
    }
}
