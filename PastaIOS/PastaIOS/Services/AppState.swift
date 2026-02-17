import CloudKit
import Foundation
import os.log
import PastaCore
import PastaSync
#if canImport(UIKit)
import UIKit
#endif

/// Manages app-level state: local database, sync orchestration, and entry loading.
@MainActor
final class AppState: ObservableObject {
    @Published var entries: [ClipboardEntry] = []
    @Published var isLoading = true
    @Published var hasCompletedOnboarding: Bool
    @Published var iCloudAvailable = false
    @Published var errorMessage: String?

    private var database: DatabaseManager?
    private let logger = Logger(subsystem: "com.pasta.ios", category: "AppState")
    private var lastObservedPasteboardChangeCount: Int?

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    func initialise(syncManager: SyncManager) async {
        do {
            database = try DatabaseManager(databaseURL: Self.databaseURL())
            try loadEntries()
        } catch {
            logger.error("Database initialisation failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        // Attempt sync separately — CloudKit may be unavailable
        do {
            let status = try await syncManager.checkAccountStatus()
            iCloudAvailable = (status == .available)

            if iCloudAvailable {
                try await syncManager.setupZone()
                try await syncManager.registerSubscription()
                await performSync(syncManager: syncManager)
                try loadEntries()
            }
        } catch {
            logger.warning("CloudKit sync unavailable: \(error.localizedDescription)")
            // Non-fatal — app works offline without sync
        }

        await captureCurrentClipboardIfNeeded(syncManager: syncManager)

        isLoading = false
    }

    func captureCurrentClipboardIfNeeded(syncManager: SyncManager) async {
        #if canImport(UIKit)
        guard let database,
              UIPasteboard.general.hasStrings,
              let clipboardString = UIPasteboard.general.string,
              !clipboardString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let changeCount = UIPasteboard.general.changeCount
        if lastObservedPasteboardChangeCount == changeCount {
            return
        }

        let entry = ClipboardEntry(
            content: clipboardString,
            contentType: inferredContentType(for: clipboardString),
            sourceApp: "iOS Pasteboard"
        )

        do {
            let alreadyExists = try database.existsWithHash(entry.contentHash)
            lastObservedPasteboardChangeCount = changeCount
            guard !alreadyExists else { return }

            try database.insert(entry, deduplicate: false)

            if iCloudAvailable {
                do {
                    try await syncManager.setupZone()
                    try await syncManager.pushEntry(entry)
                    try database.markSynced(ids: [entry.id])
                } catch {
                    logger.warning("Clipboard capture push failed: \(error.localizedDescription)")
                }
            }

            try loadEntries()
            logger.info("Captured current clipboard on app activation")
        } catch {
            logger.error("Failed to capture current clipboard: \(error.localizedDescription)")
            errorMessage = "Clipboard capture failed: \(error.localizedDescription)"
        }
        #endif
    }

    func performSync(syncManager: SyncManager) async {
        guard let database else { return }
        do {
            let changes = try await syncManager.fetchChanges()

            for entry in changes.modified {
                try database.insert(entry, deduplicate: true)
            }

            for id in changes.deleted {
                try database.delete(id: id)
            }

            try loadEntries()
        } catch {
            logger.error("Sync failed: \(error.localizedDescription)")
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    func loadEntries() throws {
        guard let database else { return }
        entries = try database.fetchAll()
    }

    func searchEntries(query: String, contentType: ContentType? = nil) -> [ClipboardEntry] {
        guard let database else { return [] }
        do {
            return try database.searchFTS(query: query, contentType: contentType, limit: 200)
        } catch {
            logger.error("Search failed: \(error.localizedDescription)")
            return []
        }
    }

    func filteredEntries(contentType: ContentType?) -> [ClipboardEntry] {
        guard let contentType else { return entries }
        return entries.filter { $0.contentType == contentType }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    private func inferredContentType(for content: String) -> ContentType {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.host != nil,
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp"].contains(scheme) {
            return .url
        }
        return .text
    }

    static func databaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pasta", isDirectory: true)
            .appendingPathComponent("pasta.sqlite")
    }
}
