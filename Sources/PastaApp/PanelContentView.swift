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
        static let sidebarColumnWidth = "pasta.mainPanel.sidebarColumnWidth"
        static let listColumnWidth = "pasta.mainPanel.listColumnWidth"
    }

    @AppStorage(Defaults.didCompleteOnboarding) var didCompleteOnboarding: Bool = false
    @AppStorage(Defaults.multiCopyJoinSeparator) var multiCopyJoinSeparator: String = "\n"
    @AppStorage(Defaults.sidebarColumnWidth) var persistedSidebarColumnWidth: Double = 200
    @AppStorage(Defaults.listColumnWidth) var persistedListColumnWidth: Double = 320

    @ObservedObject var backgroundService = BackgroundService.shared

    @State var searchQuery: String = ""
    @State var contentTypeFilter: ContentType? = nil
    @State var urlDomainFilter: String? = nil
    @State var filterSelection: FilterSelection? = .all
    @State var sourceAppFilter: String = ""
    @State var pinnedOnlyFilter: Bool = false

    @State var selectedEntryID: UUID? = nil
    @State var selectedEntryIDs: Set<UUID> = []
    @State var lastSelectedEntryID: UUID? = nil
    @State var showExtractedValuesOnly: Bool = false

    @State var isShowingOnboarding: Bool = false
    @State var isAccessibilityTrusted: Bool = AccessibilityPermission.isTrusted()
    @State var isShowingErrorAlert: Bool = false
    @State var isShowingContentTypePicker: Bool = false
    @State var copyFeedbackMessage: String? = nil
    @State var copyFeedbackTask: Task<Void, Never>? = nil
    @State private var liveSidebarColumnWidth: CGFloat? = nil
    @State private var liveListColumnWidth: CGFloat? = nil
    @State private var activeSplitDrag: SplitDrag? = nil

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

    private var hasActiveListFilters: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            contentTypeFilter != nil ||
            urlDomainFilter != nil ||
            !sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            pinnedOnlyFilter
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

            // Once onboarding is done, a missing Accessibility grant is a
            // one-line banner, not a reason to replay the whole walkthrough.
            if didCompleteOnboarding && !isAccessibilityTrusted {
                AccessibilityPermissionBanner {
                    AccessibilityPermission.requestPrompt()
                    AccessibilityPermission.openAccessibilitySettings()
                }
                .transition(.opacity)
            }

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
        GeometryReader { proxy in
            let widths = columnWidths(totalWidth: proxy.size.width)

            HStack(spacing: 0) {
                FilterSidebarView(
                    entries: backgroundService.entries,
                    effectiveTypeCounts: preloadedEffectiveTypeCounts,
                    sourceAppCounts: preloadedSourceAppCounts,
                    domainCounts: preloadedDomainCounts,
                    selectedContentType: $contentTypeFilter,
                    selectedURLDomain: $urlDomainFilter,
                    selection: $filterSelection
                )
                .frame(width: widths.sidebar)
                .accessibilitySortPriority(3)

                SplitDivider(
                    label: "Drag to resize sidebar",
                    width: SplitLayout.dividerWidth
                )
                .gesture(sidebarDividerDrag(totalWidth: proxy.size.width, widths: widths))

                ClipboardListView(
                    entries: displayedEntries,
                    selectedEntryID: $selectedEntryID,
                    selectedEntryIDs: $selectedEntryIDs,
                    searchQuery: searchQuery,
                    filterType: contentTypeFilter,
                    showExtractedValuesOnly: $showExtractedValuesOnly,
                    hasClipboardHistory: !backgroundService.entries.isEmpty,
                    isFiltered: hasActiveListFilters,
                    isLoading: backgroundService.isLoadingEntries,
                    onClearSearch: clearSearch,
                    onClearFilters: clearFilters,
                    onCopy: { entry in copyEntry(entry) },
                    onCopyMultiple: { entries in copyEntries(entries) },
                    onPaste: { entry in pasteEntry(entry) },
                    onDelete: { entry in deleteEntry(entry) },
                    onDeleteMultiple: { ids in deleteEntries(ids) },
                    onReveal: { entry in revealEntry(entry) },
                    onOpenURL: { entry in _ = openEntryURL(entry) },
                    onTogglePin: { entry in togglePin(entry) }
                )
                .frame(width: widths.list)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .accessibilitySortPriority(2)

                SplitDivider(
                    label: "Drag to resize list and preview",
                    width: SplitLayout.dividerWidth
                )
                .gesture(previewDividerDrag(totalWidth: proxy.size.width, widths: widths))

                PreviewPanelView(
                    entry: displayedEntries.first(where: { $0.id == selectedEntryID }),
                    isListEmpty: backgroundService.entries.isEmpty && !backgroundService.isLoadingEntries,
                    onCopy: { copyEntry($0) }
                )
                    .frame(width: widths.preview)
                    .frame(maxHeight: .infinity)
                    .accessibilitySortPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var footerView: some View {
        Text(ShortcutHints.footerText())
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PastaTheme.Spacing.xs)
            .accessibilityLabel(ShortcutHints.footerAccessibilityText())
    }

    private func applyChrome<V: View>(to view: V) -> some View {
        view
            .padding(16)
            .frame(minWidth: 600, minHeight: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .topTrailing) {
                if let copyFeedbackMessage {
                    CopyFeedbackToast(message: copyFeedbackMessage)
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear(perform: handleOnAppear)
            .onDisappear {
                // Reset the content-type filter and close the picker when the
                // panel hides so each new session starts unfiltered.
                contentTypeFilter = nil
                isShowingContentTypePicker = false
                copyFeedbackTask?.cancel()
                copyFeedbackTask = nil
                copyFeedbackMessage = nil
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
            .onChange(of: searchQuery) { oldQuery, newQuery in
                // Debounce search to avoid lag
                searchDebounceTask?.cancel()
                let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                // Analytics: one event when a search session *starts*, not per
                // keystroke. The query text is never passed — only whether a
                // filter was active alongside it.
                if !trimmed.isEmpty,
                   oldQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AnalyticsManager.shared.capture(.searchPerformed(
                        hasFilter: contentTypeFilter != nil
                            || urlDomainFilter != nil
                            || pinnedOnlyFilter
                            || !sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ))
                }
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
            .onChange(of: selectedEntryID) { _, newValue in
                if let newValue {
                    lastSelectedEntryID = newValue
                }
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
        if !backgroundService.isLoadingEntries {
            refreshEntries()
        }

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
        isAccessibilityTrusted = AccessibilityPermission.isTrusted()
        isShowingOnboarding = !didCompleteOnboarding
        if isShowingOnboarding {
            PastaLogger.ui.debug("Showing onboarding (completed=\(didCompleteOnboarding), accessibilityTrusted=\(isAccessibilityTrusted))")
        }
    }

    private func handleDisplayedEntriesChange(_ oldValue: [UUID], _ ids: [UUID]) {
        let hadSelection = selectedEntryID != nil || !selectedEntryIDs.isEmpty
        let visibleIDs = Set(ids)
        let filteredSelection = selectedEntryIDs.intersection(visibleIDs)
        let rememberedID = lastSelectedEntryID.flatMap { visibleIDs.contains($0) ? $0 : nil }

        if filteredSelection != selectedEntryIDs {
            selectedEntryIDs = filteredSelection
        }

        if let selectedEntryID, !visibleIDs.contains(selectedEntryID) {
            self.selectedEntryID = filteredSelection.first ?? rememberedID
        }

        if self.selectedEntryID == nil,
           (hadSelection || oldValue.isEmpty),
           let fallbackID = filteredSelection.first ?? rememberedID ?? ids.first {
            self.selectedEntryID = fallbackID
            lastSelectedEntryID = fallbackID
        }

        if let selectedEntryID {
            lastSelectedEntryID = selectedEntryID
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

private enum SplitLayout {
    static let dividerWidth: CGFloat = 8
    static let sidebarMin: CGFloat = 150
    static let sidebarMax: CGFloat = 360
    static let listMin: CGFloat = 220
    static let previewMin: CGFloat = 180
}

private struct ColumnWidths {
    let sidebar: CGFloat
    let list: CGFloat
    let preview: CGFloat
}

private struct ColumnMinimums {
    let sidebar: CGFloat
    let list: CGFloat
    let preview: CGFloat
}

private struct SplitDrag {
    let sidebar: CGFloat
    let list: CGFloat
    let preview: CGFloat
}

private extension PanelContentView {
    func columnWidths(totalWidth: CGFloat) -> ColumnWidths {
        let minimums = columnMinimums(totalWidth: totalWidth)
        let available = max(totalWidth - (SplitLayout.dividerWidth * 2), 1)
        let requestedSidebar = liveSidebarColumnWidth ?? CGFloat(persistedSidebarColumnWidth)
        let requestedList = liveListColumnWidth ?? CGFloat(persistedListColumnWidth)
        let sidebarMax = min(
            SplitLayout.sidebarMax,
            max(minimums.sidebar, available - minimums.list - minimums.preview)
        )
        let sidebar = clamp(requestedSidebar, minimums.sidebar, sidebarMax)
        let listMax = max(minimums.list, available - sidebar - minimums.preview)
        let list = clamp(requestedList, minimums.list, listMax)
        let preview = max(minimums.preview, available - sidebar - list)
        return ColumnWidths(sidebar: sidebar, list: list, preview: preview)
    }

    func columnMinimums(totalWidth: CGFloat) -> ColumnMinimums {
        let available = max(totalWidth - (SplitLayout.dividerWidth * 2), 1)
        let fullMinimum = SplitLayout.sidebarMin + SplitLayout.listMin + SplitLayout.previewMin
        let compression = min(1, available / fullMinimum)
        return ColumnMinimums(
            sidebar: SplitLayout.sidebarMin * compression,
            list: SplitLayout.listMin * compression,
            preview: SplitLayout.previewMin * compression
        )
    }

    func sidebarDividerDrag(totalWidth: CGFloat, widths: ColumnWidths) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let drag = activeSplitDrag ?? SplitDrag(
                    sidebar: widths.sidebar,
                    list: widths.list,
                    preview: widths.preview
                )
                activeSplitDrag = drag

                let minimums = columnMinimums(totalWidth: totalWidth)
                let minimumDelta = minimums.sidebar - drag.sidebar
                let maximumDelta = drag.list - minimums.list
                let delta = clamp(value.translation.width, minimumDelta, maximumDelta)
                liveSidebarColumnWidth = drag.sidebar + delta
                liveListColumnWidth = drag.list - delta
            }
            .onEnded { _ in
                persistLiveColumnWidths(totalWidth: totalWidth)
            }
    }

    func previewDividerDrag(totalWidth: CGFloat, widths: ColumnWidths) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let drag = activeSplitDrag ?? SplitDrag(
                    sidebar: widths.sidebar,
                    list: widths.list,
                    preview: widths.preview
                )
                activeSplitDrag = drag

                let minimums = columnMinimums(totalWidth: totalWidth)
                let minimumDelta = minimums.list - drag.list
                let maximumDelta = drag.preview - minimums.preview
                let delta = clamp(value.translation.width, minimumDelta, maximumDelta)
                liveSidebarColumnWidth = drag.sidebar
                liveListColumnWidth = drag.list + delta
            }
            .onEnded { _ in
                persistLiveColumnWidths(totalWidth: totalWidth)
            }
    }

    func persistLiveColumnWidths(totalWidth: CGFloat) {
        let widths = columnWidths(totalWidth: totalWidth)
        persistedSidebarColumnWidth = Double(widths.sidebar)
        persistedListColumnWidth = Double(widths.list)
        liveSidebarColumnWidth = nil
        liveListColumnWidth = nil
        activeSplitDrag = nil
    }

    func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

private struct SplitDivider: View {
    let label: String
    let width: CGFloat
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width)
            .overlay {
                Capsule()
                    .fill(isHovering ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.28))
                    .frame(width: isHovering ? 3 : 1)
            }
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(label)
            .onHover { hovering in
                if hovering && !isHovering {
                    NSCursor.resizeLeftRight.push()
                } else if !hovering && isHovering {
                    NSCursor.pop()
                }
                isHovering = hovering
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

private struct CopyFeedbackToast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PastaTheme.success.opacity(0.92), in: Capsule())
            .shadow(radius: 8, y: 3)
            .accessibilityLabel(message)
    }
}

/// Compact reminder shown above the list when Accessibility has not been
/// granted after onboarding. Pasting into other apps needs it; capture does not.
private struct AccessibilityPermissionBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: PastaTheme.Spacing.md) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.secondary)
            Text("Grant Accessibility access so Pasta can paste into other apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Open System Settings", action: onOpenSettings)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, PastaTheme.Spacing.lg)
        .padding(.vertical, PastaTheme.Spacing.md)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: PastaTheme.Radius.medium, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}
