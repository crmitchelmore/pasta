import AppKit
import PastaCore
import PastaUI
import SwiftUI
import UniformTypeIdentifiers

extension AppDelegate {
    @objc func compareClassificationWithJev() {
        if jevComparisonTask != nil {
            jevComparisonWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configuration = JevConfiguration.load()
        guard configuration.isEnabled else {
            showJevMessage(title: "Jev comparison is disabled", message: "Enable Experimental Jev Classification in Settings → Detection first.")
            return
        }
        guard configuration.endpointURL != nil else {
            showJevMessage(title: "Invalid Jev endpoint", message: JevConfigurationError.invalidEndpoint.localizedDescription)
            return
        }

        let apiKey: String
        do {
            guard let storedKey = try JevKeychain.read(), !storedKey.isEmpty else {
                showJevMessage(title: "TypeSafe API key required", message: "Add a TypeSafe API key in Settings → Detection before running a comparison.")
                return
            }
            apiKey = storedKey
            guard configuration.isValidated(apiKey: apiKey) else {
                showJevMessage(title: "TypeSafe connection test required", message: JevConfigurationError.validationRequired.localizedDescription)
                return
            }
        } catch {
            showJevMessage(title: "Could not read the TypeSafe API key", message: error.localizedDescription)
            return
        }

        let database = BackgroundService.shared.database
        Task { @MainActor [weak self] in
            let entries: [ClipboardEntry]
            do {
                entries = try await Task.detached(priority: .userInitiated) {
                    try database.fetchPrimaryEntries()
                }.value
            } catch {
                self?.showJevMessage(title: "Could not load clipboard history", message: error.localizedDescription)
                return
            }
            self?.confirmAndRunJevComparison(entries: entries, configuration: configuration, apiKey: apiKey)
        }
    }

    private func confirmAndRunJevComparison(entries: [ClipboardEntry], configuration: JevConfiguration, apiKey: String) {
        guard JevConfiguration.load() == configuration, configuration.isComparisonAllowed(apiKey: apiKey) else {
            showJevMessage(title: "Jev configuration changed", message: JevConfigurationError.validationRequired.localizedDescription)
            return
        }
        let eligible = entries.filter { JevEligibility.skipReason(for: $0, configuration: configuration) == nil }.count
        let destination = configuration.endpointHost ?? configuration.endpoint
        guard eligible > 0 else {
            showJevMessage(title: "Nothing to compare", message: "None of the \(entries.count) history entries can be sent to Jev. Images, empty entries and sensitive entries are skipped.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Compare \(eligible) entries with Jev?"
        var details = "The text of \(eligible) of \(entries.count) history entries will be sent to TypeSafe (\(destination)) using model \(configuration.effectiveModel). Long entries are truncated to the first \(JevSystemOneRequest.maxContentCharacters) characters. Pasta's existing classifications will not be changed."
        if !configuration.includeSensitiveContent {
            details += " Entries Pasta classifies as API keys, tokens, environment variables or financial data are not sent."
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Compare")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let state = JevComparisonRunState(total: eligible, destination: destination)
        let window = makeJevWindow(title: "Jev Classification Comparison", rootView: JevComparisonProgressView(state: state))
        window.styleMask = [.titled]
        window.setContentSize(NSSize(width: 440, height: 170))
        window.center()
        presentJevWindow(window)

        jevComparisonTask = Task { @MainActor [weak self] in
            let report = await JevComparisonService().compare(entries: entries, configuration: configuration, apiKey: apiKey) { progress in
                Task { @MainActor in
                    if progress.completed >= state.progress.completed { state.progress = progress }
                }
            }
            guard let self else { return }
            self.jevComparisonTask = nil
            window.close()
            self.showJevReport(report)
        }
        state.onCancel = { [weak self] in self?.jevComparisonTask?.cancel() }
    }

    private func showJevReport(_ report: JevComparisonReport) {
        let view = JevComparisonView(report: report) { [weak self] format in
            self?.exportJevReport(report, format: format)
        }
        let window = makeJevWindow(title: "Jev Classification Comparison", rootView: view)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1000, height: 620))
        window.center()
        presentJevWindow(window)
    }

    private func exportJevReport(_ report: JevComparisonReport, format: JevComparisonView.ExportFormat) {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter.string(from: report.generatedAt, timeZone: .current, formatOptions: [.withFullDate])
        switch format {
        case .json:
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "pasta-jev-comparison-\(stamp).json"
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "pasta-jev-comparison-\(stamp).csv"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == .json ? try report.jsonData() : Data(report.csv().utf8)
            try data.write(to: url, options: .atomic)
        } catch {
            showJevMessage(title: "Could not export the Jev report", message: error.localizedDescription)
        }
    }

    private func makeJevWindow<Content: View>(title: String, rootView: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    private func presentJevWindow(_ window: NSWindow) {
        jevComparisonWindow?.close()
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
