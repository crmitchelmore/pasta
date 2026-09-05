import Combine
import Foundation
import UserNotifications

@preconcurrency import PastaCore
import PastaDetectors
import PastaSync

#if canImport(AppKit)
import AppKit
#endif

/// Singleton service that runs clipboard monitoring in the background.
/// This ensures clipboard capture works even when the panel is closed.
@MainActor
final class BackgroundService: ObservableObject {
    static let shared = BackgroundService()
    
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isLoadingEntries: Bool = false
    @Published var lastError: PastaError? = nil
    
    let database: DatabaseManager
    let syncManager: SyncManager
    
    private let imageStorage: ImageStorageManager
    private let clipboardMonitor: ClipboardMonitor
    private let contentTypeDetector: ContentTypeDetector
    private let screenshotMonitor: ScreenshotMonitor
    private var detectorConfiguration: DetectorConfiguration
    
    private var cancellables: Set<AnyCancellable> = []
    private var pruneTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    /// Last pause state applied to the monitors, so the (debounced) defaults
    /// observer only starts/stops them when the setting actually flipped.
    private var monitorsPausedBySetting = UserDefaults.standard.bool(forKey: Defaults.pauseMonitoring)
    /// Whether the most recent `refresh()` finished paging the whole window
    /// in. Explicit state rather than an inference from counts: after a
    /// delete, the head-merged interim array can be LARGER than the fresh
    /// `totalEntryCount` (stale rows are only removed by the final wholesale
    /// replacement), so `entries.count >= total` must not be read as "fully
    /// loaded" or a cancelled reload would never be resumed.
    private var isHistoryPagingComplete = false
    /// Set by `start()` once the clipboard monitor is polling. Together with
    /// `isHistoryPagingComplete` this gates the `PASTA_CI` readiness marker.
    private var isMonitoringStarted = false
    private var hasSignalledCIReadiness = false

    private enum RefreshTuning {
        static let initialDisplayLimit = 200
        static let backgroundPageSize = 1_000
        static let minHeadFetchLimit = 100
        static let insertedCountMultiplier = 4
    }
    
    private enum Defaults {
        static let maxEntries = "pasta.maxEntries"
        static let retentionDays = "pasta.retentionDays"
        static let pauseMonitoring = "pasta.pauseMonitoring"
        static let playSounds = "pasta.playSounds"
        static let showNotifications = "pasta.showNotifications"
        static let storeImages = "pasta.storeImages"
        static let deduplicateEntries = "pasta.deduplicateEntries"
        static let skipAPIKeys = "pasta.skipAPIKeys"
        static let extractContent = "pasta.extractContent"
    }
    
    private init() {
        // Initialize database with fallback to in-memory on error.
        // If even the in-memory fallback fails (only possible under extreme
        // resource pressure or a broken GRDB build) we surface the error and
        // crash deliberately with a descriptive message rather than via try!.
        var dbError: PastaError? = nil
        let db: DatabaseManager = {
            do {
                return try DatabaseManager()
            } catch {
                let wrapped = (error as? PastaError) ?? PastaError.unknown(underlying: error)
                PastaLogger.logError(wrapped, logger: PastaLogger.database, context: "Database initialization failed, using in-memory fallback")
                SentryManager.capture(error: wrapped, context: ["stage": "database-init"])
                dbError = wrapped
                do {
                    return try DatabaseManager.inMemory()
                } catch {
                    SentryManager.capture(error: error, context: ["stage": "database-inmemory-fallback"])
                    PastaLogger.logError(error, logger: PastaLogger.database, context: "In-memory database fallback also failed")
                    fatalError("Pasta could not initialize even an in-memory database: \(error)")
                }
            }
        }()
        self.database = db

        // Initialize image storage with fallback to temporary directory.
        var storageError: PastaError? = nil
        let storage: ImageStorageManager = {
            do {
                return try ImageStorageManager()
            } catch {
                let wrapped = (error as? PastaError) ?? PastaError.unknown(underlying: error)
                PastaLogger.logError(wrapped, logger: PastaLogger.storage, context: "Image storage initialization failed, using temporary fallback")
                SentryManager.capture(error: wrapped, context: ["stage": "image-storage-init"])
                storageError = wrapped
                do {
                    return try ImageStorageManager(imagesDirectoryURL: .temporaryDirectory)
                } catch {
                    SentryManager.capture(error: error, context: ["stage": "image-storage-tmp-fallback"])
                    PastaLogger.logError(error, logger: PastaLogger.storage, context: "Temporary image-storage fallback also failed")
                    fatalError("Pasta could not initialize image storage in any location: \(error)")
                }
            }
        }()
        self.imageStorage = storage
        self.syncManager = SyncManager(containerIdentifier: "iCloud.com.pasta.ios")
        
        self.clipboardMonitor = ClipboardMonitor()
        self.contentTypeDetector = ContentTypeDetector()
        self.screenshotMonitor = ScreenshotMonitor()
        self.detectorConfiguration = DetectorConfigurationStore.load()
        
        // Set error after initialization completes
        if let error = dbError ?? storageError {
            self.lastError = error
        }
        
        subscribe()
        refresh()
        setupSync()
        
        // Run initial pruning
        pruneOldEntries()
    }
    
    func start() {
        let isPaused = UserDefaults.standard.bool(forKey: Defaults.pauseMonitoring)
        if isPaused {
            PastaLogger.app.info("Clipboard monitoring is paused by user setting")
            return
        }
        
        clipboardMonitor.start()
        screenshotMonitor.start()
        startPruneTimer()
        isMonitoringStarted = true
        PastaLogger.app.info("Background clipboard monitoring started")
        signalCIReadinessIfReady()
    }

    /// Under `PASTA_CI` the launch smoke test waits for this marker instead of
    /// merely checking the process is alive. It fires exactly once, when the
    /// database has answered the initial history load AND the clipboard
    /// monitor is running — the two things "the app started" actually means.
    private func signalCIReadinessIfReady() {
        guard CIReadiness.isEnabled,
              !hasSignalledCIReadiness,
              isMonitoringStarted,
              isHistoryPagingComplete else { return }
        hasSignalledCIReadiness = true
        CIReadiness.signal(entryCount: entries.count)
    }
    
    private func setupSync() {
        Task {
            do {
                let status = try await syncManager.checkAccountStatus()
                guard status == .available else {
                    PastaLogger.app.info("iCloud not available, sync disabled")
                    return
                }
                try await syncManager.setupZone()
                PastaLogger.app.info("CloudKit sync initialised")
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.app, context: "CloudKit sync setup failed")
            }
        }
    }
    
    func stop() {
        clipboardMonitor.stop()
        screenshotMonitor.stop()
        refreshTask?.cancel()
        refreshTask = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
        PastaLogger.app.info("Background clipboard monitoring stopped")
    }
    
    func refresh() {
        let db = self.database
        let limit = displayLimit
        let initialLimit = min(limit, RefreshTuning.initialDisplayLimit)
        let pageSize = RefreshTuning.backgroundPageSize

        refreshTask?.cancel()
        isLoadingEntries = true
        isHistoryPagingComplete = false

        refreshTask = Task {
            do {
                let totalTask = Task.detached(priority: .utility) {
                    try db.countEntries()
                }

                // Keyset paging: each page seeks the timestamp index at the
                // previous page's last (timestamp, rowid) instead of OFFSET,
                // which re-walked every skipped row on every page.
                let firstHistoryPage = try await Task.detached(priority: .userInitiated) {
                    try db.fetchHistoryPage(after: nil, limit: initialLimit)
                }.value
                guard !Task.isCancelled else { return }
                let firstPage = firstHistoryPage.entries
                var cursor = firstHistoryPage.nextCursor

                let total = try await totalTask.value
                let expectedCount = min(total, limit)
                if entries.isEmpty || firstPage.count >= expectedCount {
                    // Initial load, or the first page already holds the whole
                    // (post-change) library — it IS the fresh state. Assigning
                    // unconditionally here also covers deletes that shrink the
                    // library to a single page, which previously early-returned
                    // below without ever replacing the stale array.
                    entries = firstPage
                } else {
                    // Non-initial refresh (after a delete/prune/pin): publish the
                    // fresh head immediately instead of withholding every update
                    // until the full library has re-paged in. The stale tail is
                    // replaced once paging completes below.
                    entries = HistoryWindow.merge(head: firstPage, into: entries, limit: limit)
                }
                PastaLogger.ui.debug("Loaded initial clipboard history page: \(firstPage.count)/\(expectedCount) items")

                guard firstPage.count < expectedCount else {
                    isHistoryPagingComplete = true
                    isLoadingEntries = false
                    refreshTask = nil
                    signalCIReadinessIfReady()
                    return
                }

                var allEntries = firstPage
                allEntries.reserveCapacity(expectedCount)

                while allEntries.count < expectedCount, let pageCursor = cursor {
                    guard !Task.isCancelled else { return }
                    let nextLimit = min(pageSize, expectedCount - allEntries.count)
                    let nextPage = try await Task.detached(priority: .utility) {
                        try db.fetchHistoryPage(after: pageCursor, limit: nextLimit)
                    }.value
                    guard !Task.isCancelled else { return }
                    guard !nextPage.entries.isEmpty else { break }

                    allEntries.append(contentsOf: nextPage.entries)
                    cursor = nextPage.nextCursor
                }

                entries = allEntries
                isHistoryPagingComplete = true
                isLoadingEntries = false
                refreshTask = nil
                PastaLogger.ui.debug("Refreshed entries incrementally: \(allEntries.count) items")
                signalCIReadinessIfReady()
            } catch {
                guard !Task.isCancelled else { return }
                let wrapped = (error as? PastaError) ?? PastaError.unknown(underlying: error)
                PastaLogger.logError(wrapped, logger: PastaLogger.database, context: "Failed to refresh clipboard history")
                lastError = wrapped
                isLoadingEntries = false
                refreshTask = nil
            }
        }
    }

    private var displayLimit: Int {
        let configuredLimit = UserDefaults.standard.integer(forKey: Defaults.maxEntries)
        return configuredLimit > 0 ? configuredLimit : .max
    }

    private func refreshAfterInsert(insertedCount: Int) async {
        guard insertedCount > 0 else { return }

        // Cancelling a refresh that is still paging leaves `entries` without
        // its final wholesale replacement; `isHistoryPagingComplete` stays
        // false so the load is resumed below.
        refreshTask?.cancel()
        refreshTask = nil
        isLoadingEntries = false

        let displayLimit = self.displayLimit
        let headLimit = min(
            displayLimit,
            max(RefreshTuning.minHeadFetchLimit, insertedCount * RefreshTuning.insertedCountMultiplier)
        )
        let db = self.database
        let currentEntries = entries

        let latestHead = await Task.detached(priority: .userInitiated) {
            (try? db.fetchRecent(limit: headLimit)) ?? []
        }.value

        guard !latestHead.isEmpty else {
            refresh()
            return
        }

        let merged = await Task.detached(priority: .userInitiated) {
            HistoryWindow.merge(head: latestHead, into: currentEntries, limit: displayLimit)
        }.value

        entries = merged
        PastaLogger.ui.debug("Incrementally refreshed entries: \(entries.count) items")

        // The head merge only refreshes the top of the list. If the last full
        // load never finished (cancelled mid-paging, or it errored), restart
        // it — otherwise the visible history stays truncated, or keeps stale
        // rows that only the wholesale replacement removes. The completion
        // FLAG matters here: the merged array's count can exceed the fresh
        // database total after a delete, so counts cannot tell us whether
        // the load finished.
        guard !isHistoryPagingComplete else { return }

        PastaLogger.ui.debug("Resuming interrupted paged load after insert")
        refresh()
    }
    
    private func startPruneTimer() {
        // Prune every hour
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pruneOldEntries()
            }
        }
    }
    
    private func pruneOldEntries() {
        let retentionDays = UserDefaults.standard.integer(forKey: Defaults.retentionDays)
        let db = self.database
        let storage = self.imageStorage
        
        Task {
            // Run all database/file operations off the main thread
            let prunedByRetention = await Task.detached(priority: .utility) { () -> Bool in
                guard retentionDays > 0 else { return false }
                do {
                    let result = try db.pruneOlderThan(days: retentionDays)
                    try? db.deleteUnreferencedImages(paths: result.imagePaths, using: storage)
                    if !result.imagePaths.isEmpty {
                        PastaLogger.database.debug("Pruned \(result.imagePaths.count) images due to retention policy")
                    }
                    return result.didPrune
                } catch {
                    PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to prune old entries")
                    return false
                }
            }.value

            // enforceMaxEntriesLimit is already async and runs off main thread
            let prunedByMaxEntries = await self.enforceMaxEntriesLimit()

            // Only reload when rows actually went away. This runs hourly and at
            // startup; unconditionally refreshing meant every launch paid for
            // two full history loads (this one plus the one issued in `init`).
            if prunedByRetention || prunedByMaxEntries {
                self.refresh()
            }
        }
    }
    
    private func subscribe() {
        // Observe pause monitoring setting. This notification fires for EVERY
        // defaults write, including Pasta's own (window frames, sync dates,
        // …), and the handler re-decodes the detector-configuration JSON and
        // touches the monitors — so debounce it and only restart monitors when
        // the pause state actually changed.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let isPaused = UserDefaults.standard.bool(forKey: Defaults.pauseMonitoring)
                if isPaused != self.monitorsPausedBySetting {
                    self.monitorsPausedBySetting = isPaused
                    if isPaused {
                        self.clipboardMonitor.stop()
                        self.screenshotMonitor.stop()
                        PastaLogger.app.info("Clipboard monitoring paused")
                    } else {
                        self.clipboardMonitor.start()
                        self.screenshotMonitor.start()
                        PastaLogger.app.info("Clipboard monitoring resumed")
                    }
                }
                self.detectorConfiguration = DetectorConfigurationStore.load()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("pasta.entriesDidChange"))
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
        
        clipboardMonitor.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in
                guard let self else { return }
                
                // Check if paused
                if UserDefaults.standard.bool(forKey: Defaults.pauseMonitoring) {
                    return
                }
                
                PastaLogger.clipboard.debug("New clipboard entry received: \(entry.contentType.rawValue)")
                
                let db = self.database
                let storage = self.imageStorage
                let detector = self.contentTypeDetector
                let storeImages = UserDefaults.standard.bool(forKey: Defaults.storeImages)
                let deduplicate = UserDefaults.standard.bool(forKey: Defaults.deduplicateEntries)
                let skipAPIKeys = UserDefaults.standard.bool(forKey: Defaults.skipAPIKeys)
                let extractContent = UserDefaults.standard.bool(forKey: Defaults.extractContent)
                let detectorConfiguration = self.detectorConfiguration
                let syncManager = self.syncManager
                
                Task.detached {
                    let result: EnrichResult
                    do {
                        result = try Self.enrich(
                            entry,
                            detector: detector,
                            imageStorage: storage,
                            storeImages: storeImages,
                            extractContent: extractContent,
                            detectorConfiguration: detectorConfiguration
                        )
                    } catch {
                        PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Failed to enrich entry")
                        result = EnrichResult(primaryEntry: entry, extractedEntries: [], envVarSplitEntries: [])
                    }

                    // Insert all entries
                    var insertedEntries: [ClipboardEntry] = []
                    var firstInsertionError: PastaError?
                    for e in result.allEntries {
                        // Skip API keys if setting is enabled
                        if skipAPIKeys && e.contentType == .apiKey {
                            PastaLogger.clipboard.debug("Skipped API key entry - disabled in settings")
                            continue
                        }
                        
                        do {
                            try db.insert(e, deduplicate: deduplicate)
                            insertedEntries.append(e)
                            PastaLogger.clipboard.debug("Inserted entry: \(e.contentType.rawValue)\(e.isExtracted ? " (extracted)" : "")")
                        } catch {
                            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert entry")
                            if firstInsertionError == nil {
                                firstInsertionError = (error as? PastaError) ?? .unknown(underlying: error)
                            }
                        }
                    }

                    // Push to CloudKit (fire-and-forget)
                    if !insertedEntries.isEmpty {
                        let db = self.database
                        let entriesToPush = insertedEntries
                        Task.detached(priority: .utility) {
                            var syncedIDs: [UUID] = []
                            for entry in entriesToPush {
                                do {
                                    try await syncManager.pushEntry(entry)
                                    syncedIDs.append(entry.id)
                                } catch {}
                            }
                            if !syncedIDs.isEmpty {
                                try? db.markSynced(ids: syncedIDs)
                            }
                        }
                    }

                    let captureError = firstInsertionError ?? result.storageError
                    let feedbackEntry = insertedEntries.first
                    await self.enforceMaxEntriesLimit()
                    await self.refreshAfterInsert(insertedCount: insertedEntries.count)
                    await MainActor.run {
                        if let captureError {
                            self.lastError = captureError
                        } else {
                            // No success sound/notification for failed or fully
                            // excluded captures. Partial failures surface the error.
                            self.provideFeedback(for: feedbackEntry)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        screenshotMonitor.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in
                guard let self else { return }
                
                // Check if paused
                if UserDefaults.standard.bool(forKey: Defaults.pauseMonitoring) {
                    return
                }
                
                // Check if storing images is enabled
                if !UserDefaults.standard.bool(forKey: Defaults.storeImages) {
                    PastaLogger.clipboard.debug("Skipped screenshot - image storage disabled")
                    return
                }
                
                PastaLogger.clipboard.debug("New screenshot entry received: \(entry.content)")
                
                let db = self.database
                let storage = self.imageStorage
                let detector = self.contentTypeDetector
                let storeImages = UserDefaults.standard.bool(forKey: Defaults.storeImages)
                let deduplicate = UserDefaults.standard.bool(forKey: Defaults.deduplicateEntries)
                let detectorConfiguration = self.detectorConfiguration
                let syncManager = self.syncManager
                
                Task.detached {
                    let result: EnrichResult
                    do {
                        // Screenshots don't need content extraction
                        result = try Self.enrich(
                            entry,
                            detector: detector,
                            imageStorage: storage,
                            storeImages: storeImages,
                            extractContent: false,
                            detectorConfiguration: detectorConfiguration
                        )
                    } catch {
                        PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Failed to enrich screenshot entry")
                        result = EnrichResult(primaryEntry: entry, extractedEntries: [], envVarSplitEntries: [])
                    }

                    var insertedScreenshots: [ClipboardEntry] = []
                    var firstInsertionError: PastaError?
                    for e in result.allEntries {
                        do {
                            try db.insert(e, deduplicate: deduplicate)
                            insertedScreenshots.append(e)
                            PastaLogger.clipboard.debug("Inserted entry: \(e.contentType.rawValue)")
                        } catch {
                            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert screenshot entry")
                            if firstInsertionError == nil {
                                firstInsertionError = (error as? PastaError) ?? .unknown(underlying: error)
                            }
                        }
                    }

                    // Push to CloudKit (fire-and-forget)
                    if !insertedScreenshots.isEmpty {
                        let db = self.database
                        let screenshotsToPush = insertedScreenshots
                        Task.detached(priority: .utility) {
                            var syncedIDs: [UUID] = []
                            for entry in screenshotsToPush {
                                do {
                                    try await syncManager.pushEntry(entry)
                                    syncedIDs.append(entry.id)
                                } catch {}
                            }
                            if !syncedIDs.isEmpty {
                                try? db.markSynced(ids: syncedIDs)
                            }
                        }
                    }

                    let captureError = firstInsertionError ?? result.storageError
                    let feedbackEntry = insertedScreenshots.first
                    await self.enforceMaxEntriesLimit()
                    await self.refreshAfterInsert(insertedCount: insertedScreenshots.count)
                    await MainActor.run {
                        if let captureError {
                            self.lastError = captureError
                        } else {
                            self.provideFeedback(for: feedbackEntry)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func provideFeedback(for entry: ClipboardEntry?) {
        guard let entry else { return }
        
        // Play sound
        if UserDefaults.standard.bool(forKey: Defaults.playSounds) {
            #if canImport(AppKit)
            NSSound(named: .init("Tink"))?.play()
            #endif
        }
        
        // Show notification
        if UserDefaults.standard.bool(forKey: Defaults.showNotifications) {
            let content = UNMutableNotificationContent()
            content.title = "Clipboard captured"
            content.body = entry.content.prefix(100).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.body.isEmpty {
                content.body = entry.contentType.rawValue.capitalized
            }
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    PastaLogger.app.warning("Failed to show notification: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// - Returns: whether any entries were actually pruned.
    @discardableResult
    private func enforceMaxEntriesLimit() async -> Bool {
        let maxEntries = UserDefaults.standard.integer(forKey: Defaults.maxEntries)
        guard maxEntries > 0 else { return false }

        let db = self.database
        let storage = self.imageStorage
        return await Task.detached(priority: .utility) { () -> Bool in
            guard let result = try? db.pruneToMaxEntries(maxEntries) else { return false }
            if !result.imagePaths.isEmpty {
                PastaLogger.database.debug("Pruned \(result.imagePaths.count) images due to max entries limit")
            }
            try? db.deleteUnreferencedImages(paths: result.imagePaths, using: storage)
            return result.didPrune
        }.value
    }
    
    /// Result of enriching a clipboard entry with detected content types.
    struct EnrichResult {
        /// The primary entry (enriched with detected type and metadata).
        var primaryEntry: ClipboardEntry
        /// Entries extracted from the primary (emails, URLs, etc. found within).
        var extractedEntries: [ClipboardEntry]
        /// Whether this was an env var block that should be split (legacy behavior).
        var envVarSplitEntries: [ClipboardEntry]
        /// Non-fatal file-storage failure; inline image bytes remain available.
        var storageError: PastaError? = nil

        /// All entries to insert: either the split entries OR (primary + extracted).
        var allEntries: [ClipboardEntry] {
            if !envVarSplitEntries.isEmpty {
                return envVarSplitEntries
            }
            return [primaryEntry] + extractedEntries
        }
    }

    private nonisolated static func enrich(
        _ entry: ClipboardEntry,
        detector: ContentTypeDetector,
        imageStorage: ImageStorageManager,
        storeImages: Bool,
        extractContent: Bool,
        detectorConfiguration: DetectorConfiguration
    ) throws -> EnrichResult {
        var entry = entry

        if entry.contentType == .image || entry.contentType == .screenshot, entry.rawData != nil {
            var storageError: PastaError?
            if storeImages {
                do {
                    try imageStorage.persistImageData(in: &entry)
                } catch {
                    PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to save image file, retaining image bytes in database")
                    storageError = (error as? PastaError) ?? .imageSaveFailed(underlying: error)
                }
            } else {
                // Don't store image data, just record that an image was copied
                entry.rawData = nil
                PastaLogger.clipboard.debug("Skipped storing image data - disabled in settings")
            }
            return EnrichResult(primaryEntry: entry, extractedEntries: [], envVarSplitEntries: [], storageError: storageError)
        }

        let output = detector.detect(in: entry.content, configuration: detectorConfiguration)

        // Handle env var block splitting (legacy behavior - these don't have parent links)
        if output.primaryType == .envVarBlock, !output.splitEntries.isEmpty {
            let splitEntries = output.splitEntries.map { split in
                ClipboardEntry(
                    content: split.content,
                    contentType: split.contentType,
                    timestamp: entry.timestamp,
                    sourceApp: entry.sourceApp,
                    metadata: split.metadataJSON
                )
            }
            return EnrichResult(primaryEntry: entry, extractedEntries: [], envVarSplitEntries: splitEntries)
        }

        // Keep the monitor's `.filePath` type: it comes from real file URLs on
        // the pasteboard, which is stronger evidence than any text heuristic.
        // For a multi-file Finder copy no single path covers most of the joined
        // text, so the detector would re-type the entry as prose and
        // PasteService would paste plain text instead of file URLs (pasta-af5).
        if entry.contentType != .filePath {
            entry.contentType = output.primaryType
        }
        entry.metadata = output.metadataJSON

        // Create extracted entries with parentEntryId set to the primary entry's ID
        var extractedEntries: [ClipboardEntry] = []
        if extractContent && !output.extractedItems.isEmpty {
            extractedEntries = output.extractedItems.map { item in
                ClipboardEntry(
                    content: item.content,
                    contentType: item.contentType,
                    timestamp: entry.timestamp,
                    sourceApp: entry.sourceApp,
                    metadata: item.metadataJSON,
                    parentEntryId: entry.id // Link to parent
                )
            }
            PastaLogger.clipboard.debug("Extracted \(extractedEntries.count) items from entry")
        }

        return EnrichResult(primaryEntry: entry, extractedEntries: extractedEntries, envVarSplitEntries: [])
    }
    
    // MARK: - Delete Operations
    
    /// Deletes entries from the last X minutes and refreshes the entries list.
    ///
    /// The delete (a write transaction plus image-file removal) runs off the
    /// main actor; only the reload is hopped back on.
    @discardableResult
    func deleteRecent(minutes: Int) async throws -> Int {
        let deleteService = DeleteService(database: database, imageStorage: imageStorage)
        let count = try await Task.detached(priority: .userInitiated) {
            try deleteService.deleteRecent(minutes: minutes)
        }.value
        refresh()
        return count
    }

    /// Deletes all entries and refreshes the entries list.
    ///
    /// - Parameter includePinned: when `false` (the default), pinned entries are
    ///   preserved. Pass `true` from explicit "wipe everything" UI.
    @discardableResult
    func deleteAll(includePinned: Bool = false) async throws -> Int {
        let deleteService = DeleteService(database: database, imageStorage: imageStorage)
        let count = try await Task.detached(priority: .userInitiated) {
            try deleteService.deleteAll(includePinned: includePinned)
        }.value
        refresh()
        return count
    }

    /// Deletes many entries in one transaction, off the main actor, then
    /// refreshes.
    @discardableResult
    func delete(ids: [UUID]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let deleteService = DeleteService(database: database, imageStorage: imageStorage)
        let count = try await Task.detached(priority: .userInitiated) {
            try deleteService.delete(ids: ids)
        }.value
        refresh()
        return count
    }

    /// Sets the pinned state of a single entry, then refreshes if it changed.
    @discardableResult
    func setPinned(id: UUID, pinned: Bool) throws -> Bool {
        let changed = try database.setPinned(id: id, pinned: pinned)
        if changed {
            refresh()
        }
        return changed
    }
}
