import AppKit
import Foundation

import PastaCore
import PastaUI

extension AppDelegate {
    @objc func openSnippetPicker() {
        panelController?.hide()
        quickSearchController?.show(initialQuery: "!snippet ")
    }

    func setupQuickSearch() {
        quickSearchController?.setContent { [weak self] in
            let isDockOnly = UserDefaults.standard.string(forKey: AppDelegate.Defaults.appMode) == AppDelegate.AppMode.dock.rawValue
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
                },
                onDelete: { entry in
                    Task { @MainActor in
                        do {
                            _ = try await BackgroundService.shared.delete(ids: [entry.id])
                        } catch {
                            PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to delete entry from Quick Search")
                        }
                    }
                }
            )
        }
    }

    func setupCommandHandlers() {
        var handlers = CommandHandlers()

        handlers.deleteRecent = { minutes in
            try await BackgroundService.shared.deleteRecent(minutes: minutes)
        }

        handlers.deleteAll = {
            try await BackgroundService.shared.deleteAll()
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

    private func handleCommandResult(_ command: Command) async -> CommandResult {
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

        if case .pasteSnippet(let id) = result {
            return await pasteSnippet(id: id)
        }
        return result
    }

    private func pasteSnippet(id: UUID) async -> CommandResult {
        let database = BackgroundService.shared.database
        let clipboard = NSPasteboard.general.string(forType: .string)
        do {
            let evaluation = try await Task.detached(priority: .userInitiated) {
                try SnippetRenderer(database: database).render(id: id, clipboardText: clipboard)
            }.value
            guard let evaluation else { return .error("This snippet was deleted. Search again.") }
            pasteEntry(ClipboardEntry(content: evaluation.text, contentType: .text), cursorMoveCount: evaluation.cursorMoveCount)
            return .dismissed
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.ui, context: "Snippet paste failed")
            return .error("Could not load this snippet.")
        }
    }

    func showMainWindow() {
        panelController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func pasteEntry(_ entry: ClipboardEntry, cursorMoveCount: Int = 0) {
        ExternalPasteCoordinator.shared.paste(entry, cursorMoveCount: cursorMoveCount) {
            quickSearchController?.hide()
            panelController?.hide()
        }
        AnalyticsManager.shared.capture(.pastePerformed(contentType: entry.contentType))
    }
}
