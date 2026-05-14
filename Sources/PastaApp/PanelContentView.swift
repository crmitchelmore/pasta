import AppKit
import SwiftUI

import PastaCore
import PastaDetectors
import PastaUI

/// The main content view shown inside the floating panel.
struct PanelContentView: View {
    private enum Defaults {
        static let didCompleteOnboarding = "pasta.onboarding.completed"
        static let multiCopyJoinSeparator = "pasta.multiCopyJoinSeparator"
    }

    @AppStorage(Defaults.didCompleteOnboarding) private var didCompleteOnboarding: Bool = false
    @AppStorage(Defaults.multiCopyJoinSeparator) private var multiCopyJoinSeparator: String = "\n"

    @ObservedObject private var backgroundService = BackgroundService.shared

    @State private var searchQuery: String = ""
    @State private var contentTypeFilter: ContentType? = nil
    @State private var urlDomainFilter: String? = nil
    @State private var filterSelection: FilterSelection? = .all
    @State private var sourceAppFilter: String = ""
    @State private var pinnedOnlyFilter: Bool = false

    @State private var selectedEntryID: UUID? = nil
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var showExtractedValuesOnly: Bool = false

    @State private var isShowingOnboarding: Bool = false
    @State private var isShowingErrorAlert: Bool = false
    @State private var isShowingContentTypePicker: Bool = false

    // Cache search service to avoid recreation per keystroke
    @State private var searchService: SearchService? = nil

    // Cached search results to avoid recomputing on every render
    @State private var displayedEntries: [ClipboardEntry] = []
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    private enum Preload {
        static let limit = 200
    }

    // Preloaded first-page results per type (and nil = All)
    @State private var preloadedEntriesByType: [ContentType?: [ClipboardEntry]] = [:]
    @State private var preloadedEffectiveTypeCounts: [ContentType: Int]? = nil
    @State private var preloadedSourceAppCounts: [String: Int]? = nil
    @State private var preloadedDomainCounts: [String: Int]? = nil
    @State private var preloadTask: Task<Void, Never>? = nil
    @State private var filterTask: Task<Void, Never>? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var database: DatabaseManager { backgroundService.database }

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

    private func schedulePreload(for entries: [ClipboardEntry]) {
        preloadTask?.cancel()
        let snapshot = entries

        preloadTask = Task {
            let result = await Task.detached(priority: .utility) { () -> (entriesByType: [ContentType?: [ClipboardEntry]], effectiveTypeCounts: [ContentType: Int], sourceAppCounts: [String: Int], domainCounts: [String: Int]) in
                func filePathIsImage(_ metadata: String?) -> Bool {
                    guard let meta = metadata,
                          let data = meta.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                          let paths = dict["filePaths"] as? [[String: Any]],
                          let first = paths.first,
                          let fileType = first["fileType"] as? String
                    else { return false }

                    return fileType == "image"
                }

                var out: [ContentType?: [ClipboardEntry]] = [:]
                out[nil] = Array(snapshot.prefix(Preload.limit))

                var counts: [ContentType: Int] = [:]
                var sourceAppCounts: [String: Int] = [:]
                var domainCounts: [String: Int] = [:]
                let urlDetector = URLDetector()

                for entry in snapshot {
                    counts[entry.contentType, default: 0] += 1
                    let app = entry.sourceApp ?? "Unknown"
                    sourceAppCounts[app, default: 0] += 1
                    if entry.contentType == .url {
                        let domains = Set(urlDetector.detect(in: entry.content).map(\.domain))
                        for domain in domains {
                            domainCounts[domain, default: 0] += 1
                        }
                    }
                }

                let imageFilePathCount = snapshot.reduce(0) { acc, entry in
                    guard entry.contentType == .filePath else { return acc }
                    return acc + (filePathIsImage(entry.metadata) ? 1 : 0)
                }

                if imageFilePathCount > 0 {
                    counts[.image, default: 0] += imageFilePathCount
                }

                for type in MetadataParser.extractableTypes {
                    var containsCount = 0
                    for entry in snapshot {
                        guard entry.contentType != type else { continue }
                        if MetadataParser.containsType(type, in: entry.metadata) {
                            containsCount += 1
                        }
                    }

                    if containsCount > 0 {
                        counts[type, default: 0] += containsCount
                    }
                }

                for type in ContentType.allCases {
                    var matches: [ClipboardEntry] = []
                    matches.reserveCapacity(Preload.limit)

                    if MetadataParser.extractableTypes.contains(type) {
                        for entry in snapshot {
                            if entry.containsType(type) {
                                matches.append(entry)
                                if matches.count >= Preload.limit { break }
                            }
                        }
                    } else {
                        for entry in snapshot {
                            if entry.contentType == type {
                                matches.append(entry)
                                if matches.count >= Preload.limit { break }
                            }
                        }
                    }

                    out[type] = matches
                }

                return (out, counts, sourceAppCounts, domainCounts)
            }.value

            await MainActor.run {
                preloadedEntriesByType = result.entriesByType
                preloadedEffectiveTypeCounts = result.effectiveTypeCounts
                preloadedSourceAppCounts = result.sourceAppCounts
                preloadedDomainCounts = result.domainCounts

                // Update display from fresh cache if applicable (resolves race with asyncFilterEntries)
                if let cached = preloadedEntriesForCurrentFilters() {
                    filterTask?.cancel()
                    displayedEntries = cached
                }
            }
        }
    }

    private func preloadedEntriesForCurrentFilters() -> [ClipboardEntry]? {
        // Only use preload cache for the common case: no query, no domain filter, no source app filter
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard urlDomainFilter == nil else { return nil }
        guard sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !pinnedOnlyFilter else { return nil }
        return preloadedEntriesByType[contentTypeFilter]
    }

    private func triggerSearchUpdate() {
        searchDebounceTask?.cancel()
        filterTask?.cancel()
        searchTask?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let cached = preloadedEntriesForCurrentFilters() {
                displayedEntries = cached
            } else {
                asyncFilterEntries()
            }
        } else {
            performSearch(query: trimmed)
        }
    }

    private nonisolated static func filterEntries(
        _ input: [ClipboardEntry],
        contentTypeFilter: ContentType?,
        sourceFilter: String,
        urlDomainFilter: String?,
        pinnedOnly: Bool,
        limit: Int
    ) -> [ClipboardEntry] {
        var out = input

        if pinnedOnly {
            out = out.filter { $0.isPinned }
        }

        if let contentTypeFilter {
            if MetadataParser.extractableTypes.contains(contentTypeFilter) {
                out = out.filter { $0.containsType(contentTypeFilter) }
            } else {
                out = out.filter { $0.contentType == contentTypeFilter }
            }
        }

        if !sourceFilter.isEmpty {
            out = out.filter { entry in
                entry.sourceApp?.localizedCaseInsensitiveContains(sourceFilter) == true
            }
        }

        if contentTypeFilter == .url, let urlDomainFilter {
            let detector = URLDetector()
            out = out.filter { entry in
                Set(detector.detect(in: entry.content).map(\.domain)).contains(urlDomainFilter)
            }
        }

        return Array(out.prefix(limit))
    }

    /// Run entry filtering off the main thread to avoid UI hangs on large datasets
    private func asyncFilterEntries() {
        filterTask?.cancel()
        let entries = backgroundService.entries
        let typeFilter = contentTypeFilter
        let srcFilter = sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let domainFilter = urlDomainFilter
        let pinnedOnly = pinnedOnlyFilter
        let limit = Preload.limit

        filterTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [ClipboardEntry] in
                Self.filterEntries(
                    entries,
                    contentTypeFilter: typeFilter,
                    sourceFilter: srcFilter,
                    urlDomainFilter: domainFilter,
                    pinnedOnly: pinnedOnly,
                    limit: limit
                )
            }.value

            guard !Task.isCancelled else { return }
            displayedEntries = result
        }
    }

    private func performSearch(query: String) {
        guard let service = searchService else {
            displayedEntries = []
            return
        }

        searchTask?.cancel()
        let typeFilter = contentTypeFilter
        let sourceFilter = sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let domainFilter = urlDomainFilter
        let pinnedOnly = pinnedOnlyFilter
        let limit = Preload.limit
        let searchContentType: ContentType?
        if let typeFilter, MetadataParser.extractableTypes.contains(typeFilter) {
            searchContentType = nil
        } else {
            searchContentType = typeFilter
        }

        searchTask = Task(priority: .userInitiated) {
            let result: [ClipboardEntry]
            do {
                let matches = try service.search(
                    query: query,
                    contentType: searchContentType,
                    limit: Preload.limit,
                    pinnedOnly: pinnedOnly
                )
                guard !Task.isCancelled else { return }
                result = Self.filterEntries(
                    matches.map { $0.entry },
                    contentTypeFilter: typeFilter,
                    sourceFilter: sourceFilter,
                    urlDomainFilter: domainFilter,
                    pinnedOnly: pinnedOnly,
                    limit: limit
                )
            } catch {
                result = []
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                displayedEntries = result
            }
        }
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

    private func refreshEntries() {
        backgroundService.refresh()
    }

    private func closePanel() {
        NSApp.keyWindow?.close()
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // If the content-type picker is open, Esc closes it without changing
        // the filter (so it never falls through to closing the panel).
        if isShowingContentTypePicker, keyPress.key == .escape {
            isShowingContentTypePicker = false
            return .handled
        }

        switch keyPress.key {
        case .escape:
            closePanel()
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
            if keyPress.modifiers.contains(.shift) {
                return .ignored
            }
            moveSelection(delta: -1)
            return .handled

        case .downArrow:
            if keyPress.modifiers.contains(.shift) {
                return .ignored
            }
            moveSelection(delta: 1)
            return .handled

        case .return:
            if keyPress.modifiers.contains(.shift) || keyPress.modifiers.contains(.option) {
                pasteSelectedEntry(asPlainText: true)
            } else {
                pasteSelectedEntry()
            }
            return .handled

        case .delete:
            if keyPress.modifiers.contains(.command), let id = selectedEntryID,
               let entry = displayedEntries.first(where: { $0.id == id }) {
                deleteEntry(entry)
                return .handled
            }
            return .ignored

        default:
            break
        }

        // Quick paste (Cmd+1-9)
        let chars = keyPress.characters
        if keyPress.modifiers.contains(.command), chars.lowercased() == "f" {
            searchFocused = true
            return .handled
        }
        if keyPress.modifiers.contains(.command), chars.lowercased() == "p" {
            // Toggle the content-type filter picker (Raycast-style).
            // ⌘P would normally trigger Print, but Pasta is a panel app with
            // no Print menu so the shortcut is safe to repurpose.
            isShowingContentTypePicker.toggle()
            return .handled
        }
        if listFocused, keyPress.modifiers == .command, chars.lowercased() == "c" {
            copySelectedEntries()
            return .handled
        }
        if keyPress.modifiers.contains(.command), chars.lowercased() == "o" {
            if openSelectedEntryURL() { return .handled }
            return .ignored
        }
        if keyPress.modifiers.contains(.control), keyPress.modifiers.contains(.shift), chars.lowercased() == "x" {
            confirmClearAllHistory()
            return .handled
        }
        if keyPress.modifiers.contains(.command), keyPress.modifiers.contains(.shift), chars.lowercased() == "p" {
            togglePinSelectedEntry()
            return .handled
        }
        if keyPress.modifiers.contains(.command), chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
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
        setSingleSelection(displayedEntries[nextIndex].id)
    }

    private func quickPaste(index: Int) {
        guard index >= 0, index < displayedEntries.count else { return }
        setSingleSelection(displayedEntries[index].id)
        pasteSelectedEntry()
    }

    private func setSingleSelection(_ id: UUID) {
        selectedEntryID = id
        selectedEntryIDs = [id]
    }

    private func copySelectedEntries() {
        let selectedEntries = displayedEntries.filter { selectedEntryIDs.contains($0.id) }

        if selectedEntries.count > 1 {
            copyEntries(selectedEntries)
        } else if let entry = selectedEntries.first ??
            displayedEntries.first(where: { $0.id == selectedEntryID }) {
            copyEntry(entry)
        }
    }

    private func pasteSelectedEntry(asPlainText: Bool = false) {
        guard let selectedEntryID,
              let entry = displayedEntries.first(where: { $0.id == selectedEntryID }) else { return }

        PastaLogger.ui.debug("Pasting entry: \(entry.contentType.rawValue) (plain=\(asPlainText)) (\(entry.content.prefix(50))...)")
        if asPlainText {
            _ = PasteService().pastePlainText(entry)
        } else {
            _ = PasteService().paste(entry)
        }

        closePanel()
    }

    private func togglePinSelectedEntry() {
        guard let selectedEntryID,
              let entry = displayedEntries.first(where: { $0.id == selectedEntryID }) else { return }
        togglePin(entry)
    }

    private func togglePin(_ entry: ClipboardEntry) {
        do {
            try backgroundService.setPinned(id: entry.id, pinned: !entry.isPinned)
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to toggle pin")
        }
    }

    private func deleteSelectedEntry() {
        guard let selectedEntryID else { return }

        PastaLogger.ui.debug("Deleting entry: \(selectedEntryID.uuidString)")
        do {
            let imageStorage = try ImageStorageManager()
            let deleteService = DeleteService(database: database, imageStorage: imageStorage)
            _ = try deleteService.delete(id: selectedEntryID)
            refreshEntries()
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to delete entry")
        }
    }

    private func deleteEntry(_ entry: ClipboardEntry) {
        PastaLogger.ui.debug("Deleting entry: \(entry.id.uuidString)")
        do {
            let imageStorage = try ImageStorageManager()
            let deleteService = DeleteService(database: database, imageStorage: imageStorage)
            _ = try deleteService.delete(id: entry.id)
            refreshEntries()
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to delete entry")
        }
    }

    private func deleteEntries(_ ids: [UUID]) {
        PastaLogger.ui.debug("Deleting \(ids.count) entries")
        do {
            let imageStorage = try ImageStorageManager()
            let deleteService = DeleteService(database: database, imageStorage: imageStorage)
            for id in ids {
                _ = try deleteService.delete(id: id)
            }
            refreshEntries()
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to delete entries")
        }
    }

    private func copyEntry(_ entry: ClipboardEntry) {
        PastaLogger.ui.debug("Copying entry: \(entry.contentType.rawValue)")
        _ = PasteService().copy(entry)
    }

    private func copyEntries(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        PastaLogger.ui.debug("Copying \(entries.count) entries")
        _ = PasteService().copy(entries, joinedBy: multiCopyJoinSeparator)
    }

    private func pasteEntry(_ entry: ClipboardEntry) {
        PastaLogger.ui.debug("Pasting entry: \(entry.contentType.rawValue)")
        _ = PasteService().paste(entry)
        closePanel()
    }

    /// If the selected entry's content is a URL, open it in the user's default browser
    /// and close the panel. Returns true when an open was performed.
    @discardableResult
    private func openSelectedEntryURL() -> Bool {
        guard let selectedEntryID,
              let entry = displayedEntries.first(where: { $0.id == selectedEntryID }) else {
            return false
        }
        return openEntryURL(entry)
    }

    @discardableResult
    private func openEntryURL(_ entry: ClipboardEntry) -> Bool {
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Only act on entries that look like URLs. We accept either the URL ContentType
        // or text whose first line parses as an http(s):// URL — the URL detector may
        // not have reclassified an older entry yet.
        let candidate: String
        if entry.contentType == .url {
            candidate = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        } else if entry.contentType == .text || entry.contentType == .prose {
            candidate = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            guard candidate.lowercased().hasPrefix("http://") || candidate.lowercased().hasPrefix("https://") else {
                return false
            }
        } else {
            return false
        }

        guard let url = URL(string: candidate), url.scheme?.hasPrefix("http") == true else {
            return false
        }

        PastaLogger.ui.info("Opening URL from clipboard entry: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
        closePanel()
        return true
    }

    private func revealEntry(_ entry: ClipboardEntry) {
        guard entry.contentType == .filePath else { return }
        let paths = entry.content
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func confirmClearAllHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This permanently deletes every saved entry, including any stored images. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        // Make the destructive button less likely to be hit by accident:
        // first button is default; user must explicitly arrow / click it.
        if let destructive = alert.buttons.first {
            destructive.hasDestructiveAction = true
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        do {
            let count = try BackgroundService.shared.deleteAll()
            PastaLogger.ui.info("Cleared all clipboard history (\(count) entries)")
            refreshEntries()
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to clear all history")
        }
    }
}

private struct ChromeAlertModifier: ViewModifier {
    @Binding var isShowingErrorAlert: Bool
    let lastError: PastaError?
    let clearError: () -> Void
    let errorMessage: (PastaError) -> String

    func body(content: Content) -> some View {
        content
            .alert(
                lastError?.errorDescription ?? "Error",
                isPresented: $isShowingErrorAlert,
                presenting: lastError
            ) { _ in
                Button("OK", action: clearError)
            } message: { error in
                Text(errorMessage(error))
            }
    }
}
