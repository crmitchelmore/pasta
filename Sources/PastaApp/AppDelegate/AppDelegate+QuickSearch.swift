import AppKit
import Foundation

import PastaCore
import PastaUI

extension AppDelegate {
    func setupQuickSearch() {
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

    func setupCommandHandlers() {
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

        // Note: `openMainWindow` is intentionally not wired as a handler.
        // The result is observed in `handleCommandResult` so we can both
        // open the window and broadcast the optional contentType filter
        // via NotificationCenter.

        CommandRegistry.shared.handlers = handlers
    }

    func handleCommandResult(_ command: Command) async -> CommandResult {
        let result = await CommandRegistry.shared.execute(command)

        // Handle special results that need app-level actions
        if case .openMainWindow(let contentType) = result {
            quickSearchController?.hide()
            showMainWindow()
            NotificationCenter.default.post(
                name: .applyContentTypeFilter,
                object: nil,
                userInfo: [ApplyContentTypeFilterKey.contentType: contentType as Any]
            )
        }

        return result
    }

    func showMainWindow() {
        panelController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func pasteEntry(_ entry: ClipboardEntry) {
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
}
