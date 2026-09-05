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
    private enum Defaults {
        static let iCloudSyncConsent = "pasta.ios.iCloudSyncConsent.v1"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    @Published var entries: [ClipboardEntry] = []
    @Published var isLoading = true
    @Published var hasCompletedOnboarding: Bool
    @Published var isShowingOnboarding = false
    @Published var isShowingWhatsNew = false
    @Published private(set) var isICloudSyncEnabled: Bool
    @Published var iCloudStatus: SyncAccountRecovery.Availability = .disabled
    @Published private(set) var isCheckingSync = false
    @Published private(set) var syncErrorMessage: String?
    var iCloudAvailable: Bool { iCloudStatus == .available }
    private let accountRecovery = SyncAccountRecovery()
    @Published var errorMessage: String?

    private var database: DatabaseManager?
    private let logger = Logger(subsystem: "com.pasta.ios", category: "AppState")
    private var lastObservedPasteboardChangeCount: Int?
    private var isSyncInProgress = false
    private var isClipboardCaptureInProgress = false
    private let activationRequests = SyncRequestQueue()
    private let syncRequests = SyncRequestQueue()

    init() {
        // No-op unless launched by the XCUITest suite with `-uiTesting`.
        UITestConfiguration.applyIfNeeded(
            databaseURL: Self.databaseURL(),
            currentAppVersion: Self.currentAppVersion(),
            currentAppBuild: Self.currentAppBuild()
        )
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Defaults.hasCompletedOnboarding)
        // Existing onboarding and old sync timestamps are not consent.
        self.isICloudSyncEnabled = UserDefaults.standard.bool(forKey: Defaults.iCloudSyncConsent)
    }

    func initialise(syncManager: SyncManager) async {
        syncManager.setSyncEnabled(isICloudSyncEnabled)
        do {
            database = try DatabaseManager(databaseURL: Self.databaseURL())
            try loadEntries()
        } catch {
            logger.error("Database initialisation failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        // Local history and offline release notes must not wait for CloudKit.
        isLoading = false
        evaluateWhatsNewIfNeeded()
        await performSync(syncManager: syncManager)

        await captureCurrentClipboardIfNeeded(syncManager: syncManager)
    }

    func handleAppDidBecomeActive(syncManager: SyncManager) async {
        await activationRequests.run {
            await self.performSync(syncManager: syncManager)
            await self.captureCurrentClipboardIfNeeded(syncManager: syncManager)
        }
    }

    func setICloudSyncEnabled(_ enabled: Bool, syncManager: SyncManager) {
        isICloudSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Defaults.iCloudSyncConsent)
        syncManager.setSyncEnabled(enabled)
        if enabled {
            Task { await self.performSync(syncManager: syncManager) }
        } else {
            syncRequests.cancelAll()
            iCloudStatus = .disabled
            syncErrorMessage = nil
        }
    }

    func captureCurrentClipboardIfNeeded(syncManager: SyncManager) async {
        #if canImport(UIKit)
        guard !isClipboardCaptureInProgress else { return }
        isClipboardCaptureInProgress = true
        defer { isClipboardCaptureInProgress = false }

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
            contentType: .text,
            sourceApp: "iOS Pasteboard"
        )

        do {
            let alreadyExists = try database.existsWithHash(entry.contentHash)
            if alreadyExists {
                lastObservedPasteboardChangeCount = changeCount
                return
            }

            try database.insert(entry, deduplicate: false)
            lastObservedPasteboardChangeCount = changeCount

            var persistedEntry = entry

            if isICloudSyncEnabled && iCloudAvailable {
                do {
                    try await syncManager.pushEntry(entry)
                    try database.markSynced(ids: [entry.id])
                    persistedEntry.isSynced = true
                } catch {
                    logger.warning("Clipboard capture push failed: \(error.localizedDescription)")
                }
            }

            entries.removeAll { $0.id == persistedEntry.id }
            entries.insert(persistedEntry, at: 0)
            logger.info("Captured current clipboard on app activation")
        } catch {
            logger.error("Failed to capture current clipboard: \(error.localizedDescription)")
            errorMessage = "Clipboard capture failed: \(error.localizedDescription)"
        }
        #endif
    }

    func resetSync(syncManager: SyncManager) async {
        guard let database, !isSyncInProgress else { return }
        do {
            try syncManager.resetSync(in: database)
            await performSync(syncManager: syncManager)
        } catch {
            errorMessage = "Sync reset failed: \(error.localizedDescription)"
        }
    }

    func performSync(syncManager: SyncManager) async {
        guard isICloudSyncEnabled else { return }
        await syncRequests.run {
            await self.performSyncAttempt(syncManager: syncManager)
        }
    }

    private func performSyncAttempt(syncManager: SyncManager) async {
        guard isICloudSyncEnabled, !Task.isCancelled, let database else { return }
        guard !isSyncInProgress else { return }
        isSyncInProgress = true
        defer { isSyncInProgress = false }
        isCheckingSync = true
        defer { isCheckingSync = false }
        await accountRecovery.run(
            checkAccount: { try await syncManager.checkAccountStatus() },
            prepare: {
                try Task.checkCancellation()
                try await syncManager.setupZone()
                try Task.checkCancellation()
                try await syncManager.registerSubscription()
            },
            sync: {
                let backfilled = try await database.backfillUnsynced { entries, onBatchSynced in
                    try await syncManager.pushEntries(entries, onBatchSynced: onBatchSynced)
                }
                if backfilled > 0 {
                    self.logger.info("Backfilled \(backfilled) local clipboard entries to CloudKit")
                }
                try Task.checkCancellation()
                try await syncManager.pullChanges(into: database)
                try self.loadEntries()
            }
        )
        iCloudStatus = isICloudSyncEnabled ? accountRecovery.availability : .disabled
        syncErrorMessage = isICloudSyncEnabled ? accountRecovery.errorMessage : nil
        if let syncErrorMessage {
            logger.warning("\(syncErrorMessage)")
        }
    }

    func loadEntries() throws {
        guard let database else { return }
        entries = try database.fetchAll()
    }

    func searchEntries(query: String, contentType: ContentType? = nil) async -> [ClipboardEntry] {
        guard let database else { return [] }
        // Capture the thread-safe database on MainActor, then do the read off
        // the UI executor. Calling a synchronous MainActor method from a
        // detached task does not move the method's database work off-main.
        let logger = logger
        return await withCancellableDetachedTask(priority: .userInitiated) {
            guard !Task.isCancelled else { return [] }
            do {
                return try database.searchFTS(query: query, contentType: contentType, limit: 200)
            } catch {
                logger.error("Search failed: \(error.localizedDescription)")
                return []
            }
        }
    }

    func filteredEntries(contentType: ContentType?) -> [ClipboardEntry] {
        guard let contentType else { return entries }
        return entries.filter { $0.contentType == contentType }
    }

    func completeOnboarding() {
        let isFirstRun = !hasCompletedOnboarding
        hasCompletedOnboarding = true
        isShowingOnboarding = false
        UserDefaults.standard.set(true, forKey: Defaults.hasCompletedOnboarding)
        if isFirstRun { acknowledgeCurrentRelease() }
    }

    func replayOnboarding() {
        isShowingOnboarding = true
    }

    func dismissOnboarding() {
        isShowingOnboarding = false
    }

    func showWhatsNew() {
        isShowingWhatsNew = true
    }

    func dismissWhatsNew() {
        acknowledgeCurrentRelease()
        isShowingWhatsNew = false
    }

    static func databaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pasta", isDirectory: true)
            .appendingPathComponent("pasta.sqlite")
    }

    private func evaluateWhatsNewIfNeeded() {
        guard !isShowingOnboarding else { return }
        isShowingWhatsNew = ReleaseNotesPresentation.shouldPresent(
            onboardingCompleted: hasCompletedOnboarding,
            acknowledged: UserDefaults.standard.string(forKey: ReleaseNotesPresentation.acknowledgedKey),
            version: Self.currentAppVersion(), build: Self.currentAppBuild()
        )
    }

    private func acknowledgeCurrentRelease() {
        UserDefaults.standard.set(
            ReleaseNotesPresentation.identity(version: Self.currentAppVersion(), build: Self.currentAppBuild()),
            forKey: ReleaseNotesPresentation.acknowledgedKey
        )
    }

    static func currentAppVersion() -> String {
        if let version = UITestConfiguration.releaseVersion { return version }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static func currentAppBuild() -> String {
        if let build = UITestConfiguration.releaseBuild { return build }
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
