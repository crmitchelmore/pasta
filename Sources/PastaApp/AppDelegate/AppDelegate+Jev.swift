import AppKit
import PastaCore
import PastaDetectors
import PastaUI
import SwiftUI
import UniformTypeIdentifiers

extension AppDelegate {
    @objc func compareClassificationWithJev() { startRemoteClassification(reclassify: false) }
    @objc func reclassifyHistoryWithJev() { startRemoteClassification(reclassify: true) }

    private func startRemoteClassification(reclassify: Bool) {
        if jevComparisonTask != nil {
            jevComparisonWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var connections: [(configuration: JevConfiguration, apiKey: String)] = []
        let providers: [RemoteClassificationProvider] = reclassify ? [.jev] : RemoteClassificationProvider.allCases
        do {
            for provider in providers {
                let configuration = JevConfiguration.load(provider: provider)
                guard configuration.isEnabled else { continue }
                guard let key = try JevKeychain.read(provider: provider), configuration.isComparisonAllowed(apiKey: key) else {
                    throw JevConfigurationError.validationRequired
                }
                connections.append((configuration, key))
            }
        } catch {
            showJevMessage(title: "Classification connection required", message: error.localizedDescription)
            return
        }
        guard !connections.isEmpty else {
            showJevMessage(title: "No classifier enabled", message: "Configure, test and enable \(reclassify ? "Jev" : "Jev or Microsoft Decision-1") in Settings → Detection first.")
            return
        }

        let database = BackgroundService.shared.database
        let detectorConfiguration = DetectorConfigurationStore.load()
        let extractContent = UserDefaults.standard.bool(forKey: "pasta.extractContent")
        let selectedConnections = connections
        let state = JevComparisonRunState(total: 0, destination: connections.compactMap { $0.configuration.endpointHost }.joined(separator: ", "),
                                          title: "Preparing classification", changesHistory: reclassify)
        state.detail = "Reading history and running local detectors. Nothing is sent until you confirm."
        let window = makeJevWindow(title: state.title, rootView: JevComparisonProgressView(state: state))
        window.styleMask = [.titled]
        window.setContentSize(NSSize(width: 480, height: 190))
        window.center()
        presentJevWindow(window)
        state.onCancel = { [weak self] in self?.jevComparisonTask?.cancel() }
        jevComparisonTask = Task { @MainActor [weak self] in
            defer {
                self?.jevComparisonTask = nil
                window.close()
            }
            let loaded = await withCancellableDetachedTask(priority: .userInitiated) {
                Result { try database.fetchPrimaryEntries() }
            }
            guard let self, !Task.isCancelled else { return }
            let originals: [ClipboardEntry]
            do { originals = try loaded.get() }
            catch {
                self.showJevMessage(title: "Could not load clipboard history", message: error.localizedDescription)
                return
            }
            let inputs = await withCancellableDetachedTask(priority: .userInitiated) {
                let detector = ContentTypeDetector()
                return originals.map { original -> ClipboardEntry in
                    guard original.contentType != .image, original.contentType != .screenshot,
                          original.contentType != .filePath else { return original }
                    var input = original
                    let local = detector.detect(in: original.content, configuration: detectorConfiguration)
                    // Preserve a saved sensitive label for privacy even if current rules
                    // no longer recognize it. It will not enter agreement statistics.
                    input.contentType = JevEligibility.sensitiveCategories.contains(original.contentType) ? original.contentType : local.primaryType
                    if let sensitive = JevEligibility.sensitiveCategories.first(where: { original.contentTypeMask.contains($0) }) {
                        input.contentType = sensitive
                    }
                    input.metadata = local.metadataJSON
                    return input
                }
            }
            guard !Task.isCancelled else { return }
            guard selectedConnections.allSatisfy({ Self.isCurrentConnection($0.configuration, apiKey: $0.apiKey) }),
                  DetectorConfigurationStore.load() == detectorConfiguration else {
                self.showJevMessage(title: "Classification settings changed", message: "Start a new comparison with the current configuration.")
                return
            }
            let totals = await withCancellableDetachedTask(priority: .userInitiated) {
                selectedConnections.map { connection in
                    inputs.filter { JevEligibility.skipReason(for: $0, configuration: connection.configuration) == nil }.count
                }
            }
            guard !Task.isCancelled else { return }
            let total = totals.reduce(0, +)
            guard total > 0 else {
                self.showJevMessage(title: "Nothing to classify", message: "Images, file pastes, empty content and sensitive entries without opt-in are excluded.")
                return
            }

            let destinations = selectedConnections.enumerated().map { index, connection in
                let config = connection.configuration
                let privacy = config.includeSensitiveContent ? "Sensitive entries included." : "Sensitive entries excluded."
                return "\(config.provider.title): \(totals[index]) entries to \(config.endpointHost ?? config.endpoint), model \(config.effectiveModel). \(privacy)"
            }
            let alert = NSAlert()
            alert.messageText = reclassify ? "Reclassify history with Jev?" : "Compare clipboard classifiers?"
            let mutation = reclassify
                ? "Successful, known Jev results will update saved content types and rebuild extracted items. Original content, pins and copy counts are preserved. Failures, Unknown and changed/deleted entries are not overwritten."
                : "Fresh local detector results are compared with each enabled model. Saved classifications remain unchanged."
            alert.informativeText = destinations.joined(separator: "\n") + "\n\nText is truncated to the first \(JevSystemOneRequest.maxContentCharacters) characters.\n\n" + mutation
            alert.addButton(withTitle: reclassify ? "Reclassify" : "Compare")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            state.title = reclassify ? "Reclassifying with Jev" : "Comparing classifiers"
            window.title = state.title
            state.progress = JevComparisonProgress(total: total, completed: 0, agreements: 0, failed: 0)
            state.detail = "Sending confirmed entries to \(state.destination). "
                + (reclassify ? "Known decisions update unchanged saved entries." : "Saved classifications remain unchanged.")

            var reports: [JevComparisonReport] = []
            var completed = 0
            var agreements = 0
            var failed = 0
            for connection in selectedConnections {
                let offset = JevComparisonProgress(total: total, completed: completed, agreements: agreements, failed: failed)
                let report = await JevComparisonService().compare(
                    entries: inputs, configuration: connection.configuration, apiKey: connection.apiKey,
                    onProgress: { progress in
                        Task { @MainActor in
                            let combined = JevComparisonProgress(total: total, completed: offset.completed + progress.completed,
                                                                 agreements: offset.agreements + progress.agreements,
                                                                 failed: offset.failed + progress.failed)
                            if combined.completed >= state.progress.completed { state.progress = combined }
                        }
                    },
                    authorizationCheck: { Self.isCurrentConnection(connection.configuration, apiKey: connection.apiKey) }
                )
                reports.append(report)
                completed += report.compared + report.failed
                agreements += report.agreements
                failed += report.failed
            }
            guard var report = reports.first else { window.close(); return }
            if reports.count > 1 { report = report.including(Array(reports.dropFirst())) }

            if reclassify, let connection = selectedConnections.first {
                state.detail = "Applying completed decisions to unchanged saved entries."
                let rows = report.rows
                let summary = await withCancellableDetachedTask(priority: .utility) {
                    let byID = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
                    var applied = 0
                    var retained = 0
                    var conflicts = 0
                    var stopped: String?
                    for row in rows {
                        if Task.isCancelled { stopped = "Cancelled; unapplied entries retained."; break }
                        guard Self.isCurrentConnection(connection.configuration, apiKey: connection.apiKey),
                              DetectorConfigurationStore.load() == detectorConfiguration,
                              UserDefaults.standard.bool(forKey: "pasta.extractContent") == extractContent else {
                            stopped = "Configuration changed; remaining entries retained."
                            break
                        }
                        guard row.error == nil, row.skipReason == nil, let category = row.jevCategory,
                              let snapshot = byID[row.id] else { retained += 1; continue }
                        do {
                            let classification = JevClassification(category: category, modelVersion: row.jevModel)
                            let outcome = try await BackgroundService.shared.applyJevClassification(
                                classification, to: snapshot, configuration: connection.configuration, apiKey: connection.apiKey,
                                detectorConfiguration: detectorConfiguration, extractContent: extractContent
                            )
                            switch outcome {
                            case .applied: applied += 1
                            case .retained: retained += 1
                            case .changedSinceRequest: conflicts += 1
                            }
                        } catch {
                            PastaLogger.logError(error, logger: PastaLogger.database, context: "Jev history reclassification failed")
                            stopped = "Stopped: \(error.localizedDescription)"
                            break
                        }
                    }
                    let remaining = max(0, originals.count - applied - retained - conflicts)
                    return "\(applied) updated · \(retained + remaining) retained · \(conflicts) changed/deleted · \(rows.filter { $0.error != nil }.count) provider failures."
                        + (stopped.map { " \($0)" } ?? "")
                }
                report = report.withApplicationSummary(summary)
                NotificationCenter.default.post(name: Notification.Name("pasta.entriesDidChange"), object: nil)
            }
            let snapshots = await withCancellableDetachedTask(priority: .utility) {
                Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
            }
            window.close()
            self.showJevReport(report, originalEntries: snapshots)
        }
    }

    private nonisolated static func isCurrentConnection(_ configuration: JevConfiguration, apiKey: String) -> Bool {
        guard JevConfiguration.load(provider: configuration.provider) == configuration,
              configuration.isComparisonAllowed(apiKey: apiKey) else { return false }
        do { return try JevKeychain.read(provider: configuration.provider) == apiKey }
        catch {
            PastaLogger.logError(error, logger: PastaLogger.app, context: "Could not recheck classification credentials")
            return false
        }
    }

    private func showJevReport(_ report: JevComparisonReport, originalEntries: [UUID: ClipboardEntry]) {
        let view = JevComparisonView(report: report, originalEntries: originalEntries, onCopy: { [weak self] entry in
            if !PasteService().copy(entry) {
                self?.showJevMessage(title: "Could not copy the original item", message: "Its image or file may no longer be available locally.")
            }
        }) { [weak self] format in self?.exportJevReport(report, format: format) }
        let window = makeJevWindow(title: "Clipboard Classification Comparison", rootView: view)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: report.additionalReports?.isEmpty == false ? 1220 : 1000, height: 760))
        window.center()
        presentJevWindow(window)
    }

    private func exportJevReport(_ report: JevComparisonReport, format: JevComparisonView.ExportFormat) {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter.string(from: report.generatedAt, timeZone: .current, formatOptions: [.withFullDate])
        panel.allowedContentTypes = format == .json ? [.json] : [.commaSeparatedText]
        panel.nameFieldStringValue = "pasta-classification-comparison-\(stamp).\(format == .json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == .json ? try report.jsonData() : Data(report.csv().utf8)
            try data.write(to: url, options: .atomic)
        } catch { showJevMessage(title: "Could not export the classification report", message: error.localizedDescription) }
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
