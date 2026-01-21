import AppKit
import SwiftUI
import os.log

import PastaCore
import PastaDetectors
import PastaUI

// (PastaTheme lives in PastaUI)

extension Notification.Name {
    static let openSettings = Notification.Name("pasta.openSettings")
}

@main
struct PastaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .frame(minWidth: 450, minHeight: 400)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController<PanelContentView>?
    private var hotkeyManager: HotkeyManager?
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?

    private enum Defaults {
        static let appMode = "pasta.appMode"
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        PastaLogger.app.info("Pasta app initializing...")
        
        // Register default values for settings
        UserDefaults.standard.register(defaults: [
            "pasta.storeImages": true,
            "pasta.deduplicateEntries": true,
            "pasta.appMode": "both"
        ])
        
        configureAppIcon()
        applyAppMode()
        observeDefaults()
        
        // Observe settings open notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .openSettings,
            object: nil
        )
        
        // Start background clipboard monitoring (runs even when panel is closed)
        BackgroundService.shared.start()
        
        // Create the floating panel controller
        panelController = PanelController(
            size: NSSize(width: 900, height: 640),
            content: { PanelContentView() }
        )
        
        // Show the window on launch
        panelController?.show()
        
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
        PastaLogger.app.info("Opening settings window...")
        
        // Create settings window if needed
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Pasta Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        
        // Show and activate
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        
        // Background gradient - modern blue-purple
        let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        let bgGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 1.0),  // Blue
            NSColor(calibratedRed: 0.42, green: 0.35, blue: 0.80, alpha: 1.0)   // Purple
        ])
        bgGradient?.draw(in: backgroundPath, angle: -45)
        
        // Draw stacked clipboard pages (history effect)
        let pageColors = [
            NSColor(white: 1.0, alpha: 0.3),
            NSColor(white: 1.0, alpha: 0.5),
            NSColor(white: 1.0, alpha: 0.85)
        ]
        
        for (index, color) in pageColors.enumerated() {
            let offset = CGFloat(2 - index) * size * 0.03
            let pageRect = NSRect(
                x: size * 0.18 + offset,
                y: size * 0.15 - offset,
                width: size * 0.64,
                height: size * 0.70
            )
            let pagePath = NSBezierPath(roundedRect: pageRect, xRadius: size * 0.06, yRadius: size * 0.06)
            color.setFill()
            pagePath.fill()
        }
        
        // Main clipboard page
        let mainPageRect = NSRect(x: size * 0.18, y: size * 0.15, width: size * 0.64, height: size * 0.70)
        let mainPage = NSBezierPath(roundedRect: mainPageRect, xRadius: size * 0.06, yRadius: size * 0.06)
        NSColor.white.setFill()
        mainPage.fill()
        
        // Clipboard clip at top
        let clipWidth = size * 0.28
        let clipHeight = size * 0.12
        let clipRect = NSRect(
            x: rect.midX - clipWidth / 2,
            y: size * 0.78,
            width: clipWidth,
            height: clipHeight
        )
        let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: size * 0.03, yRadius: size * 0.03)
        NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0).setFill()
        clipPath.fill()
        
        // Inner clip detail
        let innerClipRect = clipRect.insetBy(dx: size * 0.03, dy: size * 0.025)
        let innerClipPath = NSBezierPath(roundedRect: innerClipRect, xRadius: size * 0.015, yRadius: size * 0.015)
        NSColor(calibratedRed: 0.70, green: 0.70, blue: 0.72, alpha: 1.0).setFill()
        innerClipPath.fill()
        
        // Text lines on clipboard (representing content)
        let lineColor = NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.87, alpha: 1.0)
        let accentColor = NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 0.6)
        
        let lineY: [CGFloat] = [0.62, 0.52, 0.42, 0.32]
        let lineWidths: [CGFloat] = [0.42, 0.38, 0.32, 0.25]
        
        for (y, width) in zip(lineY, lineWidths) {
            let lineRect = NSRect(
                x: size * 0.26,
                y: size * y,
                width: size * width,
                height: size * 0.045
            )
            let linePath = NSBezierPath(roundedRect: lineRect, xRadius: size * 0.02, yRadius: size * 0.02)
            (y == 0.62 ? accentColor : lineColor).setFill()
            linePath.fill()
        }
        
        // Copy symbol (two overlapping squares) in corner
        let symbolSize = size * 0.14
        let symbolX = size * 0.58
        let symbolY = size * 0.22
        
        // Back square
        let backSquare = NSBezierPath(roundedRect: NSRect(
            x: symbolX + size * 0.03,
            y: symbolY + size * 0.03,
            width: symbolSize,
            height: symbolSize
        ), xRadius: size * 0.02, yRadius: size * 0.02)
        NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 0.4).setFill()
        backSquare.fill()
        
        // Front square
        let frontSquare = NSBezierPath(roundedRect: NSRect(
            x: symbolX,
            y: symbolY,
            width: symbolSize,
            height: symbolSize
        ), xRadius: size * 0.02, yRadius: size * 0.02)
        NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 0.8).setFill()
        frontSquare.fill()

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
    @State private var contentTypeFilter: ContentType? = nil
    @State private var urlDomainFilter: String? = nil
    @State private var filterSelection: FilterSelection? = .all
    @State private var sourceAppFilter: String = ""

    @State private var selectedEntryID: UUID? = nil

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
                contentType: $contentTypeFilter,
                resultCount: displayedEntries.count,
                sourceAppFilter: $sourceAppFilter,
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
                onDelete: { entry in deleteEntry(entry) },
                onDeleteMultiple: { ids in deleteEntries(ids) },
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
        EmptyView()
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
            if keyPress.modifiers.contains(.command), let id = selectedEntryID,
               let entry = displayedEntries.first(where: { $0.id == id }) {
                deleteEntry(entry)
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
