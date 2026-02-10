import AppKit
import HotKey
import Sentry
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

    init() {
        // Initialize Sentry as early as possible
        SentryManager.start()
    }

    var body: some Scene {
        Settings {
            SettingsView(
                checkForUpdates: { UpdaterManager.shared.checkForUpdates() },
                automaticallyChecksForUpdates: Binding(
                    get: { UpdaterManager.shared.automaticallyChecksForUpdates },
                    set: { UpdaterManager.shared.automaticallyChecksForUpdates = $0 }
                )
            )
            .frame(minWidth: 450, minHeight: 400)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdaterManager.shared.checkForUpdates()
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController<PanelContentView>?
    private var quickSearchController: QuickSearchController?
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var hotKey: HotKey?

    private enum Defaults {
        static let appMode = "pasta.appMode"
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        PastaLogger.app.info("Pasta app initializing...")
        
        // Check if running from DMG and offer to move to Applications
        checkAndOfferMoveToApplications()
        
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
        
        // Initialize quick search manager with entries publisher and database for FTS5 search
        QuickSearchManager.shared.initialize(
            entriesPublisher: BackgroundService.shared.$entries.eraseToAnyPublisher(),
            initialEntries: BackgroundService.shared.entries,
            database: BackgroundService.shared.database
        )
        
        // Configure command handlers
        setupCommandHandlers()
        
        // Create the floating panel controller (main window)
        panelController = PanelController(
            size: NSSize(width: 900, height: 640),
            content: { PanelContentView() }
        )
        
        // Create quick search controller and pre-create window
        quickSearchController = QuickSearchController()
        setupQuickSearch()
        quickSearchController?.preCreateWindow()
        
        // Show the main window on launch
        panelController?.show()
        
        // Setup hotkey to toggle quick search using HotKey (Cmd+Ctrl+V)
        hotKey = HotKey(key: .v, modifiers: [.control, .command])
        hotKey?.keyUpHandler = { [weak self] in
            PastaLogger.app.debug("Hotkey triggered, toggling quick search")
            Task { @MainActor in
                self?.toggleQuickSearch()
            }
        }
        
        PastaLogger.app.info("Pasta app initialized successfully")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Called when user clicks dock icon or switches to app via Cmd+Tab
        if !flag {
            // No visible windows - show the main panel immediately
            panelController?.show()
        }
        return true
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        // Ensure we have a visible window when becoming active
        // This handles Cmd+Tab activation
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
        if !hasVisibleWindow {
            panelController?.show()
        }
    }
    
    private func setupQuickSearch() {
        quickSearchController?.setContent { [weak self] in
            let isDockOnly = UserDefaults.standard.string(forKey: "pasta.appMode") == "dock"
            return QuickSearchView(
                onDismiss: {
                    self?.quickSearchController?.hide()
                },
                onPaste: { entry in
                    self?.pasteEntry(entry)
                },
                onOpenFullApp: {
                    self?.showMainWindow()
                },
                showOpenFullAppButton: isDockOnly,
                onExecuteCommand: { command in
                    await self?.handleCommandResult(command) ?? .dismissed
                }
            )
        }
    }
    
    private func setupCommandHandlers() {
        var handlers = CommandHandlers()
        
        handlers.deleteRecent = { minutes in
            try BackgroundService.shared.deleteRecent(minutes: minutes)
        }
        
        handlers.deleteAll = {
            try BackgroundService.shared.deleteAll()
        }
        
        handlers.openSettings = { [weak self] in
            self?.openSettings()
        }
        
        handlers.checkForUpdates = {
            UpdaterManager.shared.checkForUpdates()
        }
        
        handlers.openReleaseNotes = {
            if let url = URL(string: "https://github.com/crmitchelmore/pasta/releases") {
                NSWorkspace.shared.open(url)
            }
        }
        
        handlers.quitApp = {
            NSApplication.shared.terminate(nil)
        }
        
        handlers.openMainWindow = { [weak self] contentType in
            self?.quickSearchController?.hide()
            self?.showMainWindow()
            // TODO: Apply filter in main window if contentType is provided
        }
        
        CommandRegistry.shared.handlers = handlers
    }
    
    private func handleCommandResult(_ command: Command) async -> CommandResult {
        let result = await CommandRegistry.shared.execute(command)
        
        // Handle special results that need app-level actions
        if case .openMainWindow(let contentType) = result {
            quickSearchController?.hide()
            showMainWindow()
            // TODO: Apply contentType filter in main window
        }
        
        return result
    }
    
    private func showMainWindow() {
        panelController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func toggleQuickSearch() {
        // Just toggle - content and data are pre-warmed
        quickSearchController?.toggle()
    }
    
    private func pasteEntry(_ entry: ClipboardEntry) {
        // Hide quick search first if visible
        quickSearchController?.hide()
        
        // Copy content to clipboard
        let pasteService = PasteService()
        _ = pasteService.copy(entry)
        
        // Deactivate our app and return focus to previous app, then paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.hide(nil)
            
            // Small delay to ensure previous app has focus before pasting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                SystemPasteEventSimulator().simulateCommandV()
            }
        }
    }
    
    // MARK: - DMG Installation Helper
    
    private func checkAndOfferMoveToApplications() {
        guard let bundlePath = Bundle.main.bundlePath as NSString? else { return }
        
        // Check if we're already in Applications
        let applicationsPath = "/Applications"
        if bundlePath.deletingLastPathComponent == applicationsPath {
            // Running from Applications - check for mounted Pasta DMG to clean up
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.checkForMountedPastaDMG()
            }
            return
        }
        
        // Check if running from a DMG (mounted volume)
        let volumesPrefix = "/Volumes/"
        guard bundlePath.hasPrefix(volumesPrefix) else { return }
        
        // Check if already asked this session
        let hasAskedKey = "pasta.hasAskedToMoveToApplications"
        if UserDefaults.standard.bool(forKey: hasAskedKey) {
            return
        }
        UserDefaults.standard.set(true, forKey: hasAskedKey)
        
        // Show alert after a short delay to let the app finish launching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showMoveToApplicationsAlert(bundlePath: bundlePath as String)
        }
    }
    
    private func checkForMountedPastaDMG() {
        let fileManager = FileManager.default
        
        // Only show eject dialog once per volume - track which volumes we've asked about
        // This prevents the dialog from appearing after Sparkle auto-updates
        let askedVolumesKey = "pasta.askedToEjectVolumes"
        var askedVolumes = Set(UserDefaults.standard.stringArray(forKey: askedVolumesKey) ?? [])
        
        do {
            let volumes = try fileManager.contentsOfDirectory(atPath: "/Volumes")
            
            for volume in volumes {
                let volumePath = "/Volumes/\(volume)"
                let appPath = "\(volumePath)/Pasta.app"
                
                // Check if this looks like our Pasta DMG
                if volume.lowercased().contains("pasta") || fileManager.fileExists(atPath: appPath) {
                    // Skip if we've already asked about this volume
                    if askedVolumes.contains(volume) {
                        PastaLogger.app.debug("Already asked about volume: \(volume), skipping")
                        return
                    }
                    
                    // Remember we asked about this volume
                    askedVolumes.insert(volume)
                    UserDefaults.standard.set(Array(askedVolumes), forKey: askedVolumesKey)
                    
                    showEjectDMGAlert(volumeName: volume)
                    return
                }
            }
        } catch {
            PastaLogger.app.debug("Could not check for mounted DMG: \(error.localizedDescription)")
        }
    }
    
    private func showEjectDMGAlert(volumeName: String) {
        let alert = NSAlert()
        alert.messageText = "Eject Installer?"
        alert.informativeText = "Pasta has been installed. Would you like to eject the installer disk image and move it to Trash?"
        alert.addButton(withTitle: "Eject & Trash")
        alert.addButton(withTitle: "Just Eject")
        alert.addButton(withTitle: "Keep Mounted")
        alert.alertStyle = .informational
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            Task.detached {
                await self.ejectAndDeleteDMG(volumePath: "/Volumes/\(volumeName)")
            }
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.unmountAndEjectDevice(atPath: "/Volumes/\(volumeName)")
        }
    }
    
    private func showMoveToApplicationsAlert(bundlePath: String) {
        let alert = NSAlert()
        alert.messageText = "Move Pasta to Applications?"
        alert.informativeText = "Pasta is running from a disk image. Would you like to move it to your Applications folder for permanent installation?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        
        // Set app icon in the alert
        if let appIcon = NSApplication.shared.applicationIconImage {
            alert.icon = appIcon
        }
        
        // Add checkbox for deleting DMG
        let checkbox = NSButton(checkboxWithTitle: "Delete disk image after moving", target: nil, action: nil)
        checkbox.state = .on
        alert.accessoryView = checkbox
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            moveToApplications(from: bundlePath, deleteDMG: checkbox.state == .on)
        }
    }
    
    private func moveToApplications(from sourcePath: String, deleteDMG: Bool) {
        let fileManager = FileManager.default
        let appName = (sourcePath as NSString).lastPathComponent
        let destinationPath = "/Applications/\(appName)"
        
        // Extract volume path for DMG deletion
        let volumePath = extractVolumePath(from: sourcePath)
        
        do {
            // Remove existing app if present
            if fileManager.fileExists(atPath: destinationPath) {
                try fileManager.removeItem(atPath: destinationPath)
            }
            
            // Copy to Applications
            try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)
            
            PastaLogger.app.info("Successfully moved app to Applications")
            
            // Prepare to relaunch from new location
            let newAppURL = URL(fileURLWithPath: destinationPath)
            
            // Delete DMG if requested
            if deleteDMG, let volumePath = volumePath {
                // Eject the DMG (run in Task to handle actor isolation)
                Task.detached {
                    await self.ejectAndDeleteDMG(volumePath: volumePath)
                }
            }
            
            // Relaunch from Applications
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSWorkspace.shared.openApplication(
                    at: newAppURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error = error {
                        PastaLogger.app.error("Failed to relaunch: \(error.localizedDescription)")
                    }
                }
                
                // Quit current instance
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
            
        } catch {
            PastaLogger.app.error("Failed to move to Applications: \(error.localizedDescription)")
            
            let errorAlert = NSAlert()
            errorAlert.messageText = "Failed to Move"
            errorAlert.informativeText = "Could not move Pasta to Applications: \(error.localizedDescription)"
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }
    
    private func extractVolumePath(from appPath: String) -> String? {
        // Extract /Volumes/VolumeName from the path
        let components = appPath.split(separator: "/")
        guard components.count >= 2,
              components[0] == "Volumes" else {
            return nil
        }
        return "/Volumes/\(components[1])"
    }
    
    private func ejectAndDeleteDMG(volumePath: String) {
        // Find the DMG file associated with this volume
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["info", "-plist"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let images = plist["images"] as? [[String: Any]] {
                
                for image in images {
                    if let systemEntities = image["system-entities"] as? [[String: Any]] {
                        for entity in systemEntities {
                            if let mountPoint = entity["mount-point"] as? String,
                               mountPoint == volumePath,
                               let imagePath = image["image-path"] as? String {
                                
                                // Eject the volume
                                let ejectTask = Process()
                                ejectTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                                ejectTask.arguments = ["detach", volumePath, "-force"]
                                try ejectTask.run()
                                ejectTask.waitUntilExit()
                                
                                // Delete the DMG file
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: imagePath), resultingItemURL: nil)
                                    PastaLogger.app.info("Moved DMG to trash: \(imagePath)")
                                }
                                return
                            }
                        }
                    }
                }
            }
        } catch {
            PastaLogger.app.error("Failed to eject/delete DMG: \(error.localizedDescription)")
        }
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
        
        // Quick clear options
        let clearSubmenu = NSMenu()
        clearSubmenu.addItem(NSMenuItem(title: "Last 10 Minutes", action: #selector(clearLast10Minutes), keyEquivalent: ""))
        clearSubmenu.addItem(NSMenuItem(title: "Last Hour", action: #selector(clearLastHour), keyEquivalent: ""))
        let clearItem = NSMenuItem(title: "Clear History…", action: nil, keyEquivalent: "")
        clearItem.submenu = clearSubmenu
        menu.addItem(clearItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
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
            window.contentView = NSHostingView(rootView: SettingsView(
                checkForUpdates: { UpdaterManager.shared.checkForUpdates() },
                automaticallyChecksForUpdates: Binding(
                    get: { UpdaterManager.shared.automaticallyChecksForUpdates },
                    set: { UpdaterManager.shared.automaticallyChecksForUpdates = $0 }
                )
            ))
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
    
    @objc private func checkForUpdates() {
        UpdaterManager.shared.checkForUpdates()
    }
    
    @objc private func clearLast10Minutes() {
        do {
            let count = try BackgroundService.shared.deleteRecent(minutes: 10)
            PastaLogger.app.info("Cleared \(count) entries from last 10 minutes")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.app, context: "Failed to clear recent entries")
        }
    }
    
    @objc private func clearLastHour() {
        do {
            let count = try BackgroundService.shared.deleteRecent(minutes: 60)
            PastaLogger.app.info("Cleared \(count) entries from last hour")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.app, context: "Failed to clear recent entries")
        }
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
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.applyAppMode()
            }
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
    @State private var showExtractedValuesOnly: Bool = false

    @State private var isShowingOnboarding: Bool = false
    @State private var isShowingErrorAlert: Bool = false
    
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
    @State private var preloadTask: Task<Void, Never>? = nil

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var database: DatabaseManager { backgroundService.database }

    private var displayedEntryIDs: [UUID] {
        displayedEntries.map(\.id)
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
                selectedContentType: $contentTypeFilter,
                selectedURLDomain: $urlDomainFilter,
                selection: $filterSelection
            )
            .frame(width: 180)
            .accessibilitySortPriority(3)

            ClipboardListView(
                entries: displayedEntries,
                selectedEntryID: $selectedEntryID,
                filterType: contentTypeFilter,
                showExtractedValuesOnly: $showExtractedValuesOnly,
                onCopy: { entry in copyEntry(entry) },
                onPaste: { entry in pasteEntry(entry) },
                onDelete: { entry in deleteEntry(entry) },
                onDeleteMultiple: { ids in deleteEntries(ids) },
                onReveal: { entry in revealEntry(entry) }
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
            .onReceive(backgroundService.$lastError) { error in
                if error != nil {
                    isShowingErrorAlert = true
                }
            }
            .onReceive(backgroundService.$entries) { entries in
                // Keep preload cache warm so type switching is instant
                schedulePreload(for: entries)

                // Update displayed entries when source changes (new items, deletions)
                // Always use applyFiltersToEntries with fresh entries - don't use stale preload cache
                let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    displayedEntries = applyFiltersToEntries(entries)
                } else {
                    triggerSearchUpdate()
                }
            }
            .onChange(of: searchQuery) { _, newQuery in
                // Debounce search to avoid lag
                searchDebounceTask?.cancel()
                let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // Empty query - update immediately
                    displayedEntries = preloadedEntriesForCurrentFilters() ?? applyFiltersToEntries(backgroundService.entries)
                } else {
                    // Debounce for typing - search runs on main actor after debounce
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
                } else if case .type = newValue {
                    sourceAppFilter = ""
                } else if case .domain = newValue {
                    sourceAppFilter = ""
                } else if newValue == .all || newValue == nil {
                    sourceAppFilter = ""
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
            let result = await Task.detached(priority: .utility) { () -> (entriesByType: [ContentType?: [ClipboardEntry]], effectiveTypeCounts: [ContentType: Int], sourceAppCounts: [String: Int]) in
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

                for entry in snapshot {
                    counts[entry.contentType, default: 0] += 1
                    let app = entry.sourceApp ?? "Unknown"
                    sourceAppCounts[app, default: 0] += 1
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

                return (out, counts, sourceAppCounts)
            }.value

            await MainActor.run {
                preloadedEntriesByType = result.entriesByType
                preloadedEffectiveTypeCounts = result.effectiveTypeCounts
                preloadedSourceAppCounts = result.sourceAppCounts
            }
        }
    }

    private func preloadedEntriesForCurrentFilters() -> [ClipboardEntry]? {
        // Only use preload cache for the common case: no query, no domain filter, no source app filter
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard urlDomainFilter == nil else { return nil }
        guard sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return preloadedEntriesByType[contentTypeFilter]
    }

    private func applyFiltersToEntries(_ input: [ClipboardEntry]) -> [ClipboardEntry] {
        var out = input
        
        // Apply type filter - include entries that CONTAIN the type in metadata, not just primary type
        if let contentTypeFilter {
            if MetadataParser.extractableTypes.contains(contentTypeFilter) {
                // For extractable types, include entries that contain the type in metadata
                out = out.filter { $0.containsType(contentTypeFilter) }
            } else {
                // For non-extractable types, use primary type only
                out = out.filter { $0.contentType == contentTypeFilter }
            }
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
        
        // Limit AFTER filtering to avoid processing thousands on main thread
        return Array(out.prefix(200))
    }
    
    private func triggerSearchUpdate() {
        searchDebounceTask?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            displayedEntries = preloadedEntriesForCurrentFilters() ?? applyFiltersToEntries(backgroundService.entries)
        } else {
            performSearch(query: trimmed)
        }
    }
    
    private func performSearch(query: String) {
        guard let service = searchService else {
            displayedEntries = []
            return
        }
        
        do {
            let matches = try service.search(
                query: query,
                contentType: contentTypeFilter,
                limit: 200
            )
            displayedEntries = applyFiltersToEntries(matches.map { $0.entry })
        } catch {
            displayedEntries = []
        }
    }

    private func handleOnAppear() {
        PastaLogger.ui.debug("Panel appeared")
        refreshEntries()
        
        // Initialize search service if needed
        if searchService == nil {
            searchService = SearchService(database: database)
        }
        
        // Initialize preload cache + displayed entries
        schedulePreload(for: backgroundService.entries)
        displayedEntries = preloadedEntriesForCurrentFilters() ?? applyFiltersToEntries(backgroundService.entries)
        
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

        // Quick paste (Cmd+1-9)
        let chars = keyPress.characters
        if keyPress.modifiers.contains(.command), chars.lowercased() == "f" {
            searchFocused = true
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
