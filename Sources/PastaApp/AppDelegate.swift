import AppKit
import Sentry
import SwiftUI
import os.log

import PastaCore
import PastaDetectors
import PastaUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NOTE: Properties below were originally `private`. They are kept at
    // module-internal access so that extensions split across files in the
    // `AppDelegate/` subdirectory can reach them. No external module touches
    // these symbols.
    var panelController: PanelController<PanelContentView>?
    var quickSearchController: QuickSearchController?
    var statusItem: NSStatusItem?
    var defaultsObserver: NSObjectProtocol?
    let hotKeyManager = CarbonHotKeyManager()
    var hotKeyPauseObserver: NSObjectProtocol?
    var hotKeyChangeObserver: NSObjectProtocol?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PastaLogger.app.info("Pasta app initializing...")

        // Check if running from DMG and offer to move to Applications
        checkAndOfferMoveToApplications()

        // Register default values for settings
        UserDefaults.standard.register(defaults: [
            "pasta.storeImages": true,
            "pasta.deduplicateEntries": true,
            "pasta.appMode": "both",
            "pasta.multiCopyJoinSeparator": "\n",
            "pasta.respectTransientPasteboard": true
        ])

        configureAppIcon()
        applyAppMode()
        observeDefaults()

        // Opt-in product analytics. No-op unless the user enabled it AND a project
        // key is configured; always a no-op under PASTA_CI.
        AnalyticsManager.shared.start()

        // PASTA_CI only: let the smoke test quit us with SIGTERM through the
        // normal terminate path so it can assert a clean exit code.
        CIReadiness.installGracefulTerminationHandler()

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

        // Setup hotkey to toggle quick search (user-customisable, default ⌃⌘V)
        registerHotKey()
        observeHotKeyNotifications()

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

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }
}
