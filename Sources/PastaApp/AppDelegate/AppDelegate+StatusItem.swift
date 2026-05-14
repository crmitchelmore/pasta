import AppKit
import PastaCore

extension AppDelegate {
    func updateStatusItem(enabled: Bool) {
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

    @objc func showPanel() {
        panelController?.show()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func checkForUpdates() {
        UpdaterManager.shared.checkForUpdates()
    }

    @objc func clearLast10Minutes() {
        do {
            let count = try BackgroundService.shared.deleteRecent(minutes: 10)
            PastaLogger.app.info("Cleared \(count) entries from last 10 minutes")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.app, context: "Failed to clear recent entries")
        }
    }

    @objc func clearLastHour() {
        do {
            let count = try BackgroundService.shared.deleteRecent(minutes: 60)
            PastaLogger.app.info("Cleared \(count) entries from last hour")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.app, context: "Failed to clear recent entries")
        }
    }
}
