import AppKit
import SwiftUI

import PastaCore
import PastaUI

extension PanelContentView {
    func pasteSelectedEntry(asPlainText: Bool = false) {
        guard let selectedEntryID,
              let entry = displayedEntries.first(where: { $0.id == selectedEntryID }) else { return }

        PastaLogger.ui.debug("Pasting entry: \(entry.contentType.rawValue) (plain=\(asPlainText)) (\(entry.content.prefix(50))...)")
        if asPlainText {
            _ = PasteService().pastePlainText(entry)
        } else {
            _ = PasteService().paste(entry)
        }
        AnalyticsManager.shared.capture(.pastePerformed(contentType: entry.contentType))

        closePanel()
    }

    func togglePinSelectedEntry() {
        guard let selectedEntryID,
              let entry = displayedEntries.first(where: { $0.id == selectedEntryID }) else { return }
        togglePin(entry)
    }

    func togglePin(_ entry: ClipboardEntry) {
        do {
            try backgroundService.setPinned(id: entry.id, pinned: !entry.isPinned)
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to toggle pin")
        }
    }

    func deleteSelectedEntry() {
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

    func deleteEntry(_ entry: ClipboardEntry) {
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

    func deleteEntries(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        PastaLogger.ui.debug("Deleting \(ids.count) entries")
        Task { @MainActor in
            do {
                _ = try await backgroundService.delete(ids: ids)
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to delete entries")
            }
        }
    }

    func copyEntry(_ entry: ClipboardEntry) {
        PastaLogger.ui.debug("Copying entry: \(entry.contentType.rawValue)")
        if PasteService().copy(entry) {
            showCopyFeedback("Copied")
        }
    }

    func copyEntries(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        PastaLogger.ui.debug("Copying \(entries.count) entries")
        if PasteService().copy(entries, joinedBy: multiCopyJoinSeparator) {
            showCopyFeedback(entries.count == 1 ? "Copied" : "Copied \(entries.count) items")
        }
    }

    func showCopyFeedback(_ message: String) {
        copyFeedbackTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            copyFeedbackMessage = message
        }

        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                copyFeedbackMessage = nil
            }
        }
    }

    func clearSearch() {
        searchQuery = ""
        triggerSearchUpdate()
    }

    func clearFilters() {
        searchQuery = ""
        contentTypeFilter = nil
        urlDomainFilter = nil
        filterSelection = .all
        sourceAppFilter = ""
        pinnedOnlyFilter = false
        showExtractedValuesOnly = false
        isShowingContentTypePicker = false
        triggerSearchUpdate()
    }

    func pasteEntry(_ entry: ClipboardEntry) {
        PastaLogger.ui.debug("Pasting entry: \(entry.contentType.rawValue)")
        _ = PasteService().paste(entry)
        AnalyticsManager.shared.capture(.pastePerformed(contentType: entry.contentType))
        closePanel()
    }

    /// If the selected entry's content is a URL, open it in the user's default browser
    /// and close the panel. Returns true when an open was performed.
    @discardableResult
    func openSelectedEntryURL() -> Bool {
        guard let selectedEntryID,
              let entry = displayedEntries.first(where: { $0.id == selectedEntryID }) else {
            return false
        }
        return openEntryURL(entry)
    }

    @discardableResult
    func openEntryURL(_ entry: ClipboardEntry) -> Bool {
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Only act on entries that look like URLs. We accept either the URL ContentType
        // or text whose first line parses as an http(s):// URL — the URL detector may
        // not have reclassified an older entry yet.
        let candidate: String
        if entry.contentType == .url {
            candidate = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        } else if entry.contentType == .text || entry.contentType == .prose {
            candidate = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            let lowercaseCandidate = candidate.lowercased()
            guard lowercaseCandidate.hasPrefix("http://") || lowercaseCandidate.hasPrefix("https://") else {
                return false
            }
        } else {
            return false
        }

        guard let url = URL(string: candidate), url.scheme?.hasPrefix("http") == true else {
            return false
        }

        PastaLogger.ui.info("Opening URL from clipboard entry: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
        closePanel()
        return true
    }

    func revealEntry(_ entry: ClipboardEntry) {
        guard entry.contentType == .filePath else { return }
        let paths = entry.content
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func confirmClearAllHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This permanently deletes every saved entry, including any stored images. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        // Make the destructive button less likely to be hit by accident:
        // first button is default; user must explicitly arrow / click it.
        if let destructive = alert.buttons.first {
            destructive.hasDestructiveAction = true
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            do {
                let count = try await BackgroundService.shared.deleteAll()
                PastaLogger.ui.info("Cleared all clipboard history (\(count) entries)")
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.ui, context: "Failed to clear all history")
            }
        }
    }
}
