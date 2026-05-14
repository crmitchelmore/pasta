import AppKit
import SwiftUI

import PastaCore
import PastaDetectors
import PastaUI

/// The main content view shown inside the floating panel.
struct PanelContentView: View {
    enum Defaults {
        static let didCompleteOnboarding = "pasta.onboarding.completed"
        static let multiCopyJoinSeparator = "pasta.multiCopyJoinSeparator"
    }

    @AppStorage(Defaults.didCompleteOnboarding) var didCompleteOnboarding: Bool = false
    @AppStorage(Defaults.multiCopyJoinSeparator) var multiCopyJoinSeparator: String = "\n"

    @ObservedObject var backgroundService = BackgroundService.shared

    @State var searchQuery: String = ""
    @State var contentTypeFilter: ContentType? = nil
    @State var urlDomainFilter: String? = nil
    @State var filterSelection: FilterSelection? = .all
    @State var sourceAppFilter: String = ""
    @State var pinnedOnlyFilter: Bool = false

    @State var selectedEntryID: UUID? = nil
    @State var selectedEntryIDs: Set<UUID> = []
    @State var showExtractedValuesOnly: Bool = false

    @State var isShowingOnboarding: Bool = false
    @State var isShowingErrorAlert: Bool = false
    @State var isShowingContentTypePicker: Bool = false

    // Cache search service to avoid recreation per keystroke
    @State var searchService: SearchService? = nil

    // Cached search results to avoid recomputing on every render
    @State var displayedEntries: [ClipboardEntry] = []
    @State var searchDebounceTask: Task<Void, Never>? = nil

    // Preloaded first-page results per type (and nil = All)
    @State var preloadedEntriesByType: [ContentType?: [ClipboardEntry]] = [:]
    @State var preloadedEffectiveTypeCounts: [ContentType: Int]? = nil
    @State var preloadedSourceAppCounts: [String: Int]? = nil
    @State var preloadedDomainCounts: [String: Int]? = nil
    @State var preloadTask: Task<Void, Never>? = nil
    @State var filterTask: Task<Void, Never>? = nil
    @State var searchTask: Task<Void, Never>? = nil

    @FocusState var searchFocused: Bool
    @FocusState var listFocused: Bool

    var database: DatabaseManager { backgroundService.database }

    private var displayedEntryIDs: [UUID] {
        displayedEntries.map(\.id)
    }

    /// Content types that have at least one entry in the current history,
    /// sorted by descending count (most common first). Powers the ⌘P picker.
    private var availableContentTypesInHistory: [ContentType] {
        if let counts = preloadedEffectiveTypeCounts, !counts.isEmpty {
            return counts
                .filter { $0.value > 0 }
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key.rawValue < rhs.key.rawValue
                }
                .map(\.key)
        }
        // Fallback: derive from entries directly when preload cache hasn't run yet.
        var seen: [ContentType: Int] = [:]
        for entry in backgroundService.entries {
            seen[entry.contentType, default: 0] += 1
        }
        return seen
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    var body: some View {
        applyChrome(to: baseView)
            .withAppearance()
            .tint(PastaTheme.accent)
    }

    @ViewBuilder
    private var baseView: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView

            SearchBarView(
                query: $searchQuery,
                contentType: $contentTypeFilter,
                resultCount: displayedEntries.count,
                sourceAppFilter: $sourceAppFilter,
                availableContentTypes: availableContentTypesInHistory,
                showContentTypePicker: $isShowingContentTypePicker,
                onOpenSettings: {
                    // Post notification to open settings via AppDelegate
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                },
                searchFocused: $searchFocused
            )

            mainContentView

            footerView
        }
    }

    @ViewBuilder
    private var headerView: some View {
        EmptyView()
    }

    @ViewBuilder
    private var mainContentView: some View {
        HStack(alignment: .top, spacing: 12) {
            FilterSidebarView(
                entries: backgroundService.entries,
                effectiveTypeCounts: preloadedEffectiveTypeCounts,
                sourceAppCounts: preloadedSourceAppCounts,
                domainCounts: preloadedDomainCounts,
                selectedContentType: $contentTypeFilter,
                selectedURLDomain: $urlDomainFilter,
                selection: $filterSelection
            )
            .frame(width: 180)
            .accessibilitySortPriority(3)

            ClipboardListView(
                entries: displayedEntries,
                selectedEntryID: $selectedEntryID,
                selectedEntryIDs: $selectedEntryIDs,
                filterType: contentTypeFilter,
                showExtractedValuesOnly: $showExtractedValuesOnly,
                onCopy: { entry in copyEntry(entry) },
                onCopyMultiple: { entries in copyEntries(entries) },
                onPaste: { entry in pasteEntry(entry) },
                onDelete: { entry in deleteEntry(entry) },
                onDeleteMultiple: { ids in deleteEntries(ids) },
                onReveal: { entry in revealEntry(entry) },
                onOpenURL: { entry in _ = openEntryURL(entry) },
                onTogglePin: { entry in togglePin(entry) }
            )
            .frame(width: 320)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .accessibilitySortPriority(2)

            PreviewPanelView(entry: displayedEntries.first(where: { $0.id == selectedEntryID }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilitySortPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footerView: some View {
        EmptyView()
    }

    private func applyChrome<V: View>(to view: V) -> some View {
        view
            .padding(16)
            .frame(minWidth: 600, minHeight: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .onAppear(perform: handleOnAppear)
            .onDisappear {
                // Reset the content-type filter and close the picker when the
                // panel hides so each new session starts unfiltered.
                contentTypeFilter = nil
                isShowingContentTypePicker = false
            }
            .onReceive(backgroundService.$lastError) { error in
                if error != nil {
                    isShowingErrorAlert = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openOnboarding)) { _ in
                isShowingOnboarding = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .applyContentTypeFilter)) { note in
                let value = note.userInfo?[ApplyContentTypeFilterKey.contentType]
                let type = value as? ContentType
                contentTypeFilter = type
                filterSelection = type.map { .type($0) } ?? .all
            }
            .onReceive(backgroundService.$entries) { entries in
                // Keep preload cache warm so type switching is instant
                schedulePreload(for: entries)

                // Update displayed entries — uses preload cache if available, async filter otherwise
                triggerSearchUpdate()
            }
            .onChange(of: searchQuery) { _, newQuery in
                // Debounce search to avoid lag
                searchDebounceTask?.cancel()
                let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // Empty query - restore filtered view (uses preload cache or async)
                    triggerSearchUpdate()
                } else {
                    // Debounce for typing before background search work
                    searchDebounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 25_000_000) // 25ms debounce
                        guard !Task.isCancelled else { return }
                        performSearch(query: trimmed)
                    }
                }
            }
            .onChange(of: contentTypeFilter) { _, newValue in
                if newValue != .url {
                    urlDomainFilter = nil
                }
                // Reset "values only" toggle when filter changes
                showExtractedValuesOnly = false
                triggerSearchUpdate()
            }
            .onChange(of: sourceAppFilter) { _, _ in
                triggerSearchUpdate()
            }
            .onChange(of: urlDomainFilter) { _, _ in
                triggerSearchUpdate()
            }
            .onChange(of: filterSelection) { _, newValue in
                // Handle source app filter from sidebar selection
                if case .sourceApp(let app) = newValue {
                    sourceAppFilter = app
                    contentTypeFilter = nil
                    urlDomainFilter = nil
                    pinnedOnlyFilter = false
                } else if case .pinned = newValue {
                    pinnedOnlyFilter = true
                    sourceAppFilter = ""
                    contentTypeFilter = nil
                    urlDomainFilter = nil
                    triggerSearchUpdate()
                } else if case .type = newValue {
                    sourceAppFilter = ""
                    pinnedOnlyFilter = false
                } else if case .domain = newValue {
                    sourceAppFilter = ""
                    pinnedOnlyFilter = false
                } else if newValue == .all || newValue == nil {
                    sourceAppFilter = ""
                    pinnedOnlyFilter = false
                    triggerSearchUpdate()
                }
            }
            .onChange(of: displayedEntryIDs) { oldValue, newValue in
                handleDisplayedEntriesChange(oldValue, newValue)
            }
            .onKeyPress { keyPress in
                handleKeyPress(keyPress)
            }
            .onChange(of: searchFocused) { _, newValue in
                if newValue { listFocused = false }
            }
            .onChange(of: listFocused) { _, newValue in
                if newValue { searchFocused = false }
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
            .modifier(ChromeAlertModifier(
                isShowingErrorAlert: $isShowingErrorAlert,
                lastError: backgroundService.lastError,
                clearError: { backgroundService.lastError = nil },
                errorMessage: errorMessage
            ))
    }

    private func handleOnAppear() {
        PastaLogger.ui.debug("Panel appeared")
        refreshEntries()

        // Initialize search service if needed
        if searchService == nil {
            searchService = SearchService(database: database)
        }

        // Initialize preload cache + displayed entries (async to avoid main thread blocking)
        schedulePreload(for: backgroundService.entries)
        triggerSearchUpdate()

        if selectedEntryID == nil, let firstID = displayedEntries.first?.id {
            setSingleSelection(firstID)
        }
        DispatchQueue.main.async {
            searchFocused = true
        }
        isShowingOnboarding = !didCompleteOnboarding || !AccessibilityPermission.isTrusted()
        if isShowingOnboarding {
            PastaLogger.ui.debug("Showing onboarding (completed=\(didCompleteOnboarding), accessibilityTrusted=\(AccessibilityPermission.isTrusted()))")
        }
    }

    private func handleDisplayedEntriesChange(_ oldValue: [UUID], _ ids: [UUID]) {
        let visibleIDs = Set(ids)
        let filteredSelection = selectedEntryIDs.intersection(visibleIDs)

        if filteredSelection != selectedEntryIDs {
            selectedEntryIDs = filteredSelection
        }

        if let selectedEntryID, !visibleIDs.contains(selectedEntryID) {
            self.selectedEntryID = filteredSelection.first
        }

        if self.selectedEntryID == nil, let fallbackID = filteredSelection.first ?? ids.first {
            self.selectedEntryID = fallbackID
        }

        if let selectedEntryID {
            if selectedEntryIDs.isEmpty {
                selectedEntryIDs = [selectedEntryID]
            } else if !selectedEntryIDs.contains(selectedEntryID),
                      let fallbackID = selectedEntryIDs.first {
                self.selectedEntryID = fallbackID
            }
        } else if !selectedEntryIDs.isEmpty {
            selectedEntryIDs.removeAll()
        }
    }

    private func errorMessage(for error: PastaError) -> String {
        var message = ""
        if let reason = error.failureReason {
            message += reason
        }
        if let suggestion = error.recoverySuggestion {
            message += "\n\n" + suggestion
        }
        return message
    }

    func refreshEntries() {
        backgroundService.refresh()
    }

    func closePanel() {
        NSApp.keyWindow?.close()
    }
}
