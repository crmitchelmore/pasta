import AppKit
import SwiftUI
import os.log

import PastaCore
import PastaDetectors
import PastaUI

// (PastaTheme lives in PastaUI)

@main
struct PastaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController<PanelContentView>?
    private var hotkeyManager: HotkeyManager?
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    private enum Defaults {
        static let appMode = "pasta.appMode"
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        PastaLogger.app.info("Pasta app initializing...")
        
        configureAppIcon()
        applyAppMode()
        observeDefaults()
        
        // Start background clipboard monitoring (runs even when panel is closed)
        BackgroundService.shared.start()
        
        // Create the floating panel controller
        panelController = PanelController(
            size: NSSize(width: 900, height: 640),
            content: { PanelContentView() }
        )
        
        // Setup hotkey to toggle panel
        hotkeyManager = HotkeyManager { [weak self] in
            PastaLogger.app.debug("Hotkey triggered, toggling panel")
            Task { @MainActor in
                self?.panelController?.toggle()
            }
        }
        
        PastaLogger.app.info("Pasta app initialized successfully")
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }
    
    private func updateStatusItem(enabled: Bool) {
        if !enabled {
            statusItem = nil
            return
        }
        if statusItem != nil { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Pasta")
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Pasta", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Pasta", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }
    
    @objc private func statusItemClicked() {
        panelController?.toggle()
    }
    
    @objc private func showPanel() {
        panelController?.show()
    }
    
    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func configureAppIcon() {
        let iconName = NSImage.Name("AppIcon")
        let image = NSImage(named: iconName) ?? Self.makeFallbackIcon(size: 512)
        NSApplication.shared.applicationIconImage = image
        NSApplication.shared.dockTile.display()
    }

    private func observeDefaults() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppMode()
        }
    }

    private func applyAppMode() {
        let raw = UserDefaults.standard.string(forKey: Defaults.appMode) ?? AppMode.both.rawValue
        let mode = AppMode(rawValue: raw) ?? .both

        switch mode {
        case .menuBar:
            NSApplication.shared.setActivationPolicy(.accessory)
            updateStatusItem(enabled: true)
        case .dock:
            NSApplication.shared.setActivationPolicy(.regular)
            updateStatusItem(enabled: false)
        case .both:
            NSApplication.shared.setActivationPolicy(.regular)
            updateStatusItem(enabled: true)
        }
    }

    private enum AppMode: String {
        case menuBar
        case dock
        case both
    }

    private static func makeFallbackIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let corner = size * 0.22
        let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        let bgGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.90, alpha: 1.0),
            NSColor(calibratedRed: 0.93, green: 0.89, blue: 0.82, alpha: 1.0)
        ])
        bgGradient?.draw(in: backgroundPath, angle: -90)

        let plateRect = rect.insetBy(dx: size * 0.16, dy: size * 0.16)
        let platePath = NSBezierPath(ovalIn: plateRect)
        NSColor.white.setFill()
        platePath.fill()
        NSColor(calibratedRed: 0.88, green: 0.86, blue: 0.82, alpha: 1.0).setStroke()
        platePath.lineWidth = size * 0.03
        platePath.stroke()

        let innerRect = rect.insetBy(dx: size * 0.25, dy: size * 0.25)
        let innerPath = NSBezierPath(ovalIn: innerRect)
        NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.94, alpha: 1.0).setFill()
        innerPath.fill()
        NSColor(calibratedRed: 0.90, green: 0.88, blue: 0.84, alpha: 1.0).setStroke()
        innerPath.lineWidth = size * 0.02
        innerPath.stroke()

        let center = NSPoint(x: rect.midX, y: rect.midY + size * 0.02)
        let spiral = NSBezierPath()
        let turns: CGFloat = 4.2
        let steps = 260
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps - 1) * .pi * turns
            let radius = size * 0.03 + t * size * 0.02
            let x = center.x + radius * cos(t)
            let y = center.y + radius * sin(t)
            if i == 0 {
                spiral.move(to: NSPoint(x: x, y: y))
            } else {
                spiral.line(to: NSPoint(x: x, y: y))
            }
        }
        spiral.lineWidth = size * 0.08
        spiral.lineCapStyle = .round
        NSColor(calibratedRed: 0.94, green: 0.74, blue: 0.18, alpha: 1.0).setStroke()
        spiral.stroke()

        let basil = NSBezierPath(ovalIn: NSRect(
            x: center.x + size * 0.14,
            y: center.y + size * 0.08,
            width: size * 0.18,
            height: size * 0.10
        ))
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.30, alpha: 1.0).setFill()
        basil.fill()

        for (dx, dy, r) in [(-0.14, -0.10, 0.035), (-0.05, -0.05, 0.028), (0.12, -0.02, 0.024)] {
            let dotRect = NSRect(
                x: center.x + size * dx - size * r,
                y: center.y + size * dy - size * r,
                width: size * r * 2,
                height: size * r * 2
            )
            let dot = NSBezierPath(ovalIn: dotRect)
            NSColor(calibratedRed: 0.84, green: 0.22, blue: 0.18, alpha: 1.0).setFill()
            dot.fill()
        }

        return image
    }
}

/// The main content view shown inside the floating panel.
struct PanelContentView: View {
    private enum Defaults {
        static let didCompleteOnboarding = "pasta.onboarding.completed"
    }

    @AppStorage(Defaults.didCompleteOnboarding) private var didCompleteOnboarding: Bool = false

    @ObservedObject private var backgroundService = BackgroundService.shared

    @State private var searchQuery: String = ""
    @State private var isFuzzySearch: Bool = false
    @State private var contentTypeFilter: ContentType? = nil
    @State private var urlDomainFilter: String? = nil
    @State private var filterSelection: FilterSelection? = .all
    @State private var sourceAppFilter: String = ""

    @State private var selectedEntryID: UUID? = nil

    @State private var isShowingDeleteConfirmation: Bool = false
    @State private var isShowingBulkDelete: Bool = false
    @State private var lastBulkDeleteSummary: String? = nil

    @State private var isShowingOnboarding: Bool = false
    @State private var isShowingErrorAlert: Bool = false

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var database: DatabaseManager { backgroundService.database }

    private var displayedEntries: [ClipboardEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        func applyFilters(_ input: [ClipboardEntry]) -> [ClipboardEntry] {
            var out = input
            if let contentTypeFilter {
                out = out.filter { $0.contentType == contentTypeFilter }
            }
            let sourceFilter = sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            return out
        }

        if trimmed.isEmpty {
            return applyFilters(backgroundService.entries)
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

    private var displayedEntryIDs: [UUID] {
        displayedEntries.map(\.id)
    }

    var body: some View {
        applyChrome(to: baseView)
    }

    @ViewBuilder
    private var baseView: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView

            SearchBarView(
                query: $searchQuery,
                isFuzzy: $isFuzzySearch,
                contentType: $contentTypeFilter,
                resultCount: displayedEntries.count,
                sourceAppFilter: $sourceAppFilter,
                onOpenSettings: { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) },
                searchFocused: $searchFocused
            )

            mainContentView

            footerView
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Close") { closePanel() }
                .keyboardShortcut("w", modifiers: [.command])
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var mainContentView: some View {
        HStack(alignment: .top, spacing: 12) {
            FilterSidebarView(
                entries: backgroundService.entries,
                selectedContentType: $contentTypeFilter,
                selectedURLDomain: $urlDomainFilter,
                selection: $filterSelection
            )
            .frame(width: 180)
            .accessibilitySortPriority(3)

            ClipboardListView(
                entries: displayedEntries,
                selectedEntryID: $selectedEntryID,
                onCopy: { entry in copyEntry(entry) },
                onPaste: { entry in pasteEntry(entry) },
                onDelete: { _ in isShowingDeleteConfirmation = true },
                onReveal: { entry in revealEntry(entry) }
            )
            .frame(width: 320)
            .focusable()
            .focused($listFocused)
            .accessibilitySortPriority(2)

            PreviewPanelView(entry: displayedEntries.first(where: { $0.id == selectedEntryID }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilitySortPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footerView: some View {
        HStack {
            Button("Refresh") {
                refreshEntries()
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Delete Selected…") {
                isShowingDeleteConfirmation = true
            }
            .disabled(selectedEntryID == nil)

            Button("Delete Recent Items…") {
                isShowingBulkDelete = true
            }
            .disabled(backgroundService.entries.isEmpty)

            if let lastBulkDeleteSummary {
                Text(lastBulkDeleteSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func applyChrome<V: View>(to view: V) -> some View {
        view
            .padding(16)
            .frame(minWidth: 600, minHeight: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .onAppear(perform: handleOnAppear)
            .onReceive(backgroundService.$lastError) { error in
                if error != nil {
                    isShowingErrorAlert = true
                }
            }
            .onChange(of: contentTypeFilter) { _, newValue in
                if newValue != .url {
                    urlDomainFilter = nil
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
            .modifier(ChromeSheetsModifier(
                isShowingDeleteConfirmation: $isShowingDeleteConfirmation,
                isShowingBulkDelete: $isShowingBulkDelete,
                isShowingOnboarding: $isShowingOnboarding,
                deleteConfirmationContent: {
                    DeleteConfirmationView(entry: displayedEntries.first(where: { $0.id == selectedEntryID })) {
                        deleteSelectedEntry()
                    }
                },
                bulkDeleteContent: {
                    BulkDeleteView(entries: backgroundService.entries) { minutes in
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
                },
                onboardingContent: {
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
            ))
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
        if selectedEntryID == nil {
            selectedEntryID = displayedEntries.first?.id
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
        if let selectedEntryID, !ids.contains(selectedEntryID) {
            self.selectedEntryID = nil
        }
        if self.selectedEntryID == nil, let first = ids.first {
            self.selectedEntryID = first
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
        if keyPress.modifiers.contains(.command), chars.lowercased() == "f" {
            searchFocused = true
            return .handled
        }
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

        PastaLogger.ui.debug("Pasting entry: \(entry.contentType.rawValue) (\(entry.content.prefix(50))...)")
        _ = PasteService().paste(entry)

        closePanel()
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

    private func copyEntry(_ entry: ClipboardEntry) {
        PastaLogger.ui.debug("Copying entry: \(entry.contentType.rawValue)")
        _ = PasteService().copy(entry)
    }

    private func pasteEntry(_ entry: ClipboardEntry) {
        PastaLogger.ui.debug("Pasting entry: \(entry.contentType.rawValue)")
        _ = PasteService().paste(entry)
        closePanel()
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
}

private struct ChromeSheetsModifier<DeleteContent: View, BulkDeleteContent: View, OnboardingContent: View>: ViewModifier {
    @Binding var isShowingDeleteConfirmation: Bool
    @Binding var isShowingBulkDelete: Bool
    @Binding var isShowingOnboarding: Bool
    let deleteConfirmationContent: () -> DeleteContent
    let bulkDeleteContent: () -> BulkDeleteContent
    let onboardingContent: () -> OnboardingContent

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowingDeleteConfirmation, content: deleteConfirmationContent)
            .sheet(isPresented: $isShowingBulkDelete, content: bulkDeleteContent)
            .sheet(isPresented: $isShowingOnboarding, content: onboardingContent)
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
