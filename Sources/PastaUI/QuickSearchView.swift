import AppKit
import PastaCore
import SwiftUI

// MARK: - Quick Search View (Spotlight-like)

public struct QuickSearchView: View {
    @ObservedObject private var manager = QuickSearchManager.shared
    private let onDismiss: () -> Void
    private let onPaste: (ClipboardEntry) -> Void
    private let onOpenFullApp: (() -> Void)?
    private let showOpenFullAppButton: Bool
    private let onExecuteCommand: ((Command) async -> CommandResult)?
    private let onDelete: ((ClipboardEntry) -> Void)?

    @FocusState private var isSearchFocused: Bool
    @State private var commandFeedback: String? = nil
    @State private var showingConfirmation: Bool = false
    @State private var pendingConfirmAction: (@Sendable @MainActor () async -> CommandResult)? = nil
    @State private var confirmationMessage: String = ""
    @State private var isPreviewVisible: Bool = false

    public init(
        onDismiss: @escaping () -> Void,
        onPaste: @escaping (ClipboardEntry) -> Void,
        onOpenFullApp: (() -> Void)? = nil,
        showOpenFullAppButton: Bool = false,
        onExecuteCommand: ((Command) async -> CommandResult)? = nil,
        onDelete: ((ClipboardEntry) -> Void)? = nil
    ) {
        self.onDismiss = onDismiss
        self.onPaste = onPaste
        self.onOpenFullApp = onOpenFullApp
        self.showOpenFullAppButton = showOpenFullAppButton
        self.onExecuteCommand = onExecuteCommand
        self.onDelete = onDelete
    }

    public var body: some View {
        QuickSearchKeyHandler(
            onArrowUp: { manager.moveSelection(by: -1) },
            onArrowDown: { manager.moveSelection(by: 1) },
            onArrowRight: { if !manager.isCommandMode { isPreviewVisible = true } },
            onArrowLeft: { isPreviewVisible = false },
            onReturn: { handleReturn() },
            onEscape: {
                if isPreviewVisible {
                    isPreviewVisible = false
                } else {
                    onDismiss()
                }
            },
            onCommandNumber: { digit in
                let index = digit - 1
                if manager.isCommandMode {
                    if let command = manager.commandResults[safe: index] {
                        executeCommand(command)
                    }
                } else {
                    if let entry = manager.results[safe: index] {
                        onPaste(entry)
                        onDismiss()
                    }
                }
            },
            onCommandDelete: { deleteSelectedEntry() }
        ) {
            ZStack {
                VStack(spacing: 0) {
                    // Search field - always full width
                    searchField

                    // Quick filters (hidden in command mode) - always full width
                    if !manager.isCommandMode {
                        filterBar
                    }

                    Divider()
                        .opacity(0.5)

                    // Results area - changes layout when preview is visible
                    if manager.isCommandMode {
                        commandsList
                    } else if manager.results.isEmpty && !manager.query.isEmpty {
                        emptyState
                    } else {
                        HStack(spacing: 0) {
                            // Results list - shrinks to micro view when preview visible
                            if isPreviewVisible {
                                microResultsList
                                    .frame(width: 100)

                                Divider()
                                    .opacity(0.5)

                                // Preview panel fills remaining space
                                if let entry = manager.selectedEntry {
                                    QuickSearchPreviewPanel(entry: entry)
                                        .frame(maxWidth: .infinity)
                                }
                            } else {
                                resultsList
                            }
                        }

                        if !isPreviewVisible && !manager.results.isEmpty {
                            Divider().opacity(0.3)
                            HStack(spacing: 4) {
                                Text("→")
                                    .font(.system(.caption, design: .rounded).weight(.medium))
                                Text("Preview")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }

                    // Command feedback
                    if let feedback = commandFeedback {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(PastaTheme.success)
                            Text(feedback)
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PastaTheme.success.opacity(0.1))
                    }
                }
                .frame(width: 680, height: dynamicHeight)
                .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                .animation(.easeInOut(duration: 0.2), value: isPreviewVisible)

                // Confirmation dialog overlay
                if showingConfirmation {
                    confirmationOverlay
                }
            }
        }
        .onAppear {
            manager.prepareForSearch()
            isSearchFocused = true
        }
        .onChange(of: manager.query) { _, _ in
            manager.searchQueryChanged()
        }
        .onChange(of: manager.selectedFilter) { _, _ in
            manager.searchQueryChanged()
        }
        .onChange(of: manager.showPinnedOnly) { _, _ in
            manager.searchQueryChanged()
        }
    }

    private var dynamicHeight: CGFloat {
        let itemCount = manager.isCommandMode ? manager.commandResults.count : manager.results.count
        let baseHeight: CGFloat = manager.isCommandMode ? 80 : 100 // Less for command mode (no filter bar)
        return max(400, min(500, baseHeight + CGFloat(itemCount * 52)))
    }

    private func handleReturn() {
        if manager.isCommandMode {
            if let command = manager.selectedCommand {
                executeCommand(command)
            }
        } else {
            pasteSelectedEntry()
        }
    }

    private func pasteSelectedEntry() {
        if let entry = manager.selectedEntry {
            onPaste(entry)
            onDismiss()
        }
    }

    /// ⌘⌫: delete the highlighted entry without leaving Quick Search. The
    /// results list refreshes through the manager's entries publisher.
    private func deleteSelectedEntry() {
        guard !manager.isCommandMode, let onDelete, let entry = manager.selectedEntry else { return }
        onDelete(entry)
    }

    private func executeCommand(_ command: Command) {
        Task { @MainActor in
            let result: CommandResult
            if let handler = onExecuteCommand {
                result = await handler(command)
            } else {
                result = await CommandRegistry.shared.execute(command)
            }

            switch result {
            case .success(let message):
                commandFeedback = message
                // Auto-dismiss after brief feedback
                try? await Task.sleep(nanoseconds: 800_000_000)
                onDismiss()

            case .needsConfirmation(let message, let confirmAction):
                confirmationMessage = message
                pendingConfirmAction = confirmAction
                showingConfirmation = true

            case .error(let message):
                commandFeedback = "Error: \(message)"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                commandFeedback = nil

            case .openMainWindow:
                onDismiss()
                // The handler in AppDelegate will open the main window

            case .dismissed:
                onDismiss()
            }
        }
    }

    private var confirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)

                Text(confirmationMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        showingConfirmation = false
                        pendingConfirmAction = nil
                    }
                    .keyboardShortcut(.escape)

                    Button("Confirm") {
                        Task { @MainActor in
                            showingConfirmation = false
                            if let action = pendingConfirmAction {
                                let result = await action()
                                pendingConfirmAction = nil

                                if case .success(let message) = result {
                                    commandFeedback = message
                                    try? await Task.sleep(nanoseconds: 800_000_000)
                                    onDismiss()
                                }
                            }
                        }
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .tint(PastaTheme.destructive)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10)
        }
    }

    private var commandsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(manager.commandResults.prefix(9).enumerated()), id: \.element.id) { index, command in
                        CommandRow(
                            command: command,
                            index: index + 1,
                            isSelected: manager.selectedIndex == index
                        )
                        .id(command.id)
                        .onTapGesture {
                            executeCommand(command)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: manager.selectedIndex) { _, newIndex in
                if let command = manager.commandResults[safe: newIndex] {
                    proxy.scrollTo(command.id, anchor: .center)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: manager.isCommandMode ? "terminal" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(manager.isCommandMode ? PastaTheme.command : .secondary)

            TextField(manager.isCommandMode ? "Type a command..." : "Search clipboard history... (! for commands)", text: $manager.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit {
                    handleReturn()
                }

            if !manager.query.isEmpty {
                Button {
                    manager.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            let hasItems = manager.isCommandMode ? !manager.commandResults.isEmpty : !manager.results.isEmpty
            Text("⌘\(hasItems ? "1-9" : "")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

            if showOpenFullAppButton, let onOpenFullApp {
                Button {
                    onDismiss()
                    onOpenFullApp()
                } label: {
                    Image(systemName: "macwindow")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open full app")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ContentTypeFilterChip.filterBar(
                    title: "All",
                    icon: "tray.full",
                    isSelected: manager.selectedFilter == nil && !manager.showPinnedOnly,
                    count: nil
                ) {
                    manager.showPinnedOnly = false
                    manager.selectedFilter = nil
                }

                if manager.pinnedCount > 0 {
                    ContentTypeFilterChip.filterBar(
                        title: "Pinned",
                        icon: "pin.fill",
                        isSelected: manager.showPinnedOnly,
                        count: manager.pinnedCount
                    ) {
                        manager.showPinnedOnly.toggle()
                    }
                }

                ForEach(manager.availableFilters, id: \.type) { filter in
                    ContentTypeFilterChip.filterBar(
                        title: filter.type.displayTitle,
                        icon: filter.type.systemImageName,
                        isSelected: manager.selectedFilter == filter.type,
                        count: filter.count
                    ) {
                        manager.selectedFilter = filter.type
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No results for \"\(manager.query)\"")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    /// Sections to render in the results list. Used to inject "Pinned" /
    /// "History" headers when no query/filter is active (mirrors the main
    /// panel's grouping in HighPerformanceListView).
    private struct ResultSection: Identifiable {
        let id: String
        let title: String?
        let items: [(index: Int, entry: ClipboardEntry)]
    }

    private var resultSections: [ResultSection] {
        let indexed = Array(manager.results.enumerated()).map { (index: $0.offset, entry: $0.element) }

        // When the user has explicitly filtered to pinned-only, label the
        // single section "Pinned" so they know what they're looking at.
        if manager.showPinnedOnly {
            return [ResultSection(id: "pinned", title: "Pinned", items: indexed)]
        }

        // Auto-injected Pinned/History split is opt-in — by default users
        // reach pinned items via the Pinned filter chip.
        let showPinnedSection = UserDefaults.standard.bool(forKey: "pasta.showPinnedSectionInQuickSearch")
        guard showPinnedSection else {
            return [ResultSection(id: "all", title: nil, items: indexed)]
        }

        // Only inject Pinned/History split when no other filter/query is
        // narrowing the list — otherwise headers would be misleading.
        let isUnfiltered = manager.selectedFilter == nil
            && manager.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isUnfiltered else {
            return [ResultSection(id: "all", title: nil, items: indexed)]
        }

        let pinned = indexed.filter { $0.entry.isPinned }
        let unpinned = indexed.filter { !$0.entry.isPinned }
        guard !pinned.isEmpty else {
            return [ResultSection(id: "all", title: nil, items: indexed)]
        }

        var sections: [ResultSection] = [ResultSection(id: "pinned", title: "Pinned", items: pinned)]
        if !unpinned.isEmpty {
            sections.append(ResultSection(id: "history", title: "History", items: unpinned))
        }
        return sections
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(resultSections) { section in
                        Section {
                            ForEach(section.items, id: \.entry.id) { item in
                                QuickSearchRow(
                                    entry: item.entry,
                                    index: item.index + 1,
                                    isSelected: manager.selectedIndex == item.index,
                                    query: manager.query
                                )
                                .id(item.entry.id)
                                .onTapGesture {
                                    onPaste(item.entry)
                                    onDismiss()
                                }
                            }
                        } header: {
                            if let title = section.title {
                                QuickSearchSectionHeader(title: title)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: manager.selectedIndex) { _, newIndex in
                if let entry = manager.results[safe: newIndex] {
                    proxy.scrollTo(entry.id, anchor: .center)
                }
            }
        }
    }

    private var microResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(manager.results.enumerated()), id: \.element.id) { index, entry in
                        QuickSearchRow(
                            entry: entry,
                            index: index + 1,
                            isSelected: manager.selectedIndex == index,
                            style: .micro
                        )
                        .id(entry.id)
                        .onTapGesture {
                            manager.selectedIndex = index
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .onChange(of: manager.selectedIndex) { _, newIndex in
                if let entry = manager.results[safe: newIndex] {
                    proxy.scrollTo(entry.id, anchor: .center)
                }
            }
        }
    }
}

// Subviews and helper types extracted to QuickSearch/:
//   - QuickSearchKeyHandler.swift  (NSEvent key interception)
//   - QuickSearchRow.swift         (standard + micro row)
//   - ImageThumbnail.swift         (thumbnail loader/cache)
//   - QuickSearchPreviewPanel.swift (preview panel)
//   - QuickSearchSupport.swift     (CommandRow, section header,
//                                   Array safe subscript)
