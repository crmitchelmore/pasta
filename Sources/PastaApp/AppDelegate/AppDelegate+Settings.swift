import AppKit
import SwiftUI

import PastaCore
import PastaUI

extension AppDelegate {
    @objc func openSettings() {
        PastaLogger.app.info("Opening settings window...")
        AnalyticsManager.shared.capture(.settingsOpened)

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
                syncManager: BackgroundService.shared.syncManager,
                syncNow: {
                    try await BackgroundService.shared.syncNow()
                },
                resetSync: {
                    let service = BackgroundService.shared
                    try service.syncManager.resetSync(in: service.database)
                },
                syncedCount: {
                    (try? BackgroundService.shared.database.syncedCount()) ?? 0
                },
                openWalkthrough: { [weak self] in
                    self?.panelController?.show()
                    NotificationCenter.default.post(name: .openOnboarding, object: nil)
                },
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
}
