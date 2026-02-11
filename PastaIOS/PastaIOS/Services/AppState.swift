import CloudKit
import Foundation
import os.log
import PastaCore
import PastaSync

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

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    func initialise(syncManager: SyncManager) async {
        do {
            let status = try await syncManager.checkAccountStatus()
            iCloudAvailable = (status == .available)

            database = try DatabaseManager(databaseURL: Self.databaseURL())

            try await syncManager.setupZone()
            try await syncManager.registerSubscription()

            await performSync(syncManager: syncManager)

            try loadEntries()
            isLoading = false
        } catch {
            logger.error("Initialisation failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            isLoading = false
        }
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

    static func databaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pasta", isDirectory: true)
            .appendingPathComponent("pasta.sqlite")
    }
}
