import AppKit
import PastaCore
import PastaUI
import SwiftUI

extension AppDelegate {
    @objc func compareClassificationWithJev() {
        let configuration = JevConfiguration.load()
        guard configuration.isEnabled else {
            showJevMessage(title: "Jev comparison is disabled", message: "Enable Experimental Jev Classification in Settings → Detection first.")
            return
        }

        let apiKey: String
        do {
            guard let storedKey = try JevKeychain.read(), !storedKey.isEmpty else {
                showJevMessage(title: "Jev API key required", message: "Add a Jev API key in Settings → Detection before running a comparison.")
                return
            }
            apiKey = storedKey
        } catch {
            showJevMessage(title: "Could not read Jev API key", message: error.localizedDescription)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Compare current history with Jev?"
        alert.informativeText = "Supported text entries will be sent to Jev. Existing Pasta classifications will not be changed."
        alert.addButton(withTitle: "Compare")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let database = BackgroundService.shared.database
        Task { @MainActor [weak self] in
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try database.fetchPrimaryEntries()
                }.value
                let report = await JevComparisonService().compare(entries: entries, configuration: configuration, apiKey: apiKey)
                self?.showJevReport(report)
            } catch {
                self?.showJevMessage(title: "Jev comparison failed", message: error.localizedDescription)
            }
        }
    }

    private func showJevReport(_ report: JevComparisonReport) {
        let controller = NSHostingController(rootView: JevComparisonView(report: report))
        let window = NSWindow(contentViewController: controller)
        window.title = "Jev Classification Comparison"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 860, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        jevComparisonWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showJevMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
