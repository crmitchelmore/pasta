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
    @Published private(set) var loadedEntryCount: Int = 0
    @Published private(set) var totalEntryCount: Int? = nil
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

    private enum RefreshTuning {
        static let fallbackDisplayLimit = 10_000
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
        PastaLogger.app.info("Background clipboard monitoring started")
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
        loadedEntryCount = entries.isEmpty ? 0 : min(entries.count, limit)
        totalEntryCount = nil

        refreshTask = Task {
            do {
                let totalTask = Task.detached(priority: .utility) {
                    try db.countEntries()
                }

                let firstPage = try await Task.detached(priority: .userInitiated) {
                    try db.fetchRecent(limit: initialLimit, offset: 0)
                }.value
                guard !Task.isCancelled else { return }

                let total = try await totalTask.value
                let expectedCount = min(total, limit)
                totalEntryCount = expectedCount
                if entries.isEmpty {
                    entries = firstPage
                }
                loadedEntryCount = firstPage.count
                PastaLogger.ui.debug("Loaded initial clipboard history page: \(firstPage.count)/\(expectedCount) items")

                guard firstPage.count < expectedCount else {
                    isLoadingEntries = false
                    refreshTask = nil
                    return
                }

                var allEntries = firstPage
                allEntries.reserveCapacity(expectedCount)

                while allEntries.count < expectedCount {
                    guard !Task.isCancelled else { return }
                    let offset = allEntries.count
                    let nextLimit = min(pageSize, expectedCount - offset)
                    let nextPage = try await Task.detached(priority: .utility) {
                        try db.fetchRecent(limit: nextLimit, offset: offset)
                    }.value
                    guard !Task.isCancelled else { return }
                    guard !nextPage.isEmpty else { break }

                    allEntries.append(contentsOf: nextPage)
                    loadedEntryCount = allEntries.count
                }

                entries = allEntries
                loadedEntryCount = allEntries.count
                isLoadingEntries = false
                refreshTask = nil
                PastaLogger.ui.debug("Refreshed entries incrementally: \(allEntries.count) items")
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
        return configuredLimit > 0 ? configuredLimit : RefreshTuning.fallbackDisplayLimit
    }

    private func refreshAfterInsert(insertedCount: Int) async {
        guard insertedCount > 0 else { return }
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
            var seen = Set<UUID>()
            var merged: [ClipboardEntry] = []
            merged.reserveCapacity(min(displayLimit, latestHead.count + currentEntries.count))

            for entry in latestHead {
                guard seen.insert(entry.id).inserted else { continue }
                merged.append(entry)
            }

            for entry in currentEntries {
                guard seen.insert(entry.id).inserted else { continue }
                merged.append(entry)
                if merged.count >= displayLimit {
                    break
                }
            }

            return merged
        }.value

        entries = merged
        PastaLogger.ui.debug("Incrementally refreshed entries: \(entries.count) items")
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
            await Task.detached(priority: .utility) {
                if retentionDays > 0 {
                    do {
                        let paths = try db.pruneOlderThan(days: retentionDays)
                        for path in paths {
                            try? storage.deleteImage(path: path)
                        }
                        if !paths.isEmpty {
                            PastaLogger.database.debug("Pruned \(paths.count) images due to retention policy")
                        }
                    } catch {
                        PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to prune old entries")
                    }
                }
            }.value
            
            // enforceMaxEntriesLimit is already async and runs off main thread
            await self.enforceMaxEntriesLimit()
            self.refresh()
        }
    }
    
    private func subscribe() {
        // Observe pause monitoring setting
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                let isPaused = UserDefaults.standard.bool(forKey: Defaults.pauseMonitoring)
                if isPaused {
                    self.clipboardMonitor.stop()
                    self.screenshotMonitor.stop()
                    PastaLogger.app.info("Clipboard monitoring paused")
                } else {
                    self.clipboardMonitor.start()
                    self.screenshotMonitor.start()
                    PastaLogger.app.info("Clipboard monitoring resumed")
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

                    await self.enforceMaxEntriesLimit()
                    await self.refreshAfterInsert(insertedCount: insertedEntries.count)
                    await MainActor.run {
                        self.provideFeedback(for: result.primaryEntry)
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
                    for e in result.allEntries {
                        do {
                            try db.insert(e, deduplicate: deduplicate)
                            insertedScreenshots.append(e)
                            PastaLogger.clipboard.debug("Inserted entry: \(e.contentType.rawValue)")
                        } catch {
                            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert screenshot entry")
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

                    await self.enforceMaxEntriesLimit()
                    await self.refreshAfterInsert(insertedCount: insertedScreenshots.count)
                    await MainActor.run {
                        self.provideFeedback(for: result.primaryEntry)
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
    
    private func enforceMaxEntriesLimit() async {
        let maxEntries = UserDefaults.standard.integer(forKey: Defaults.maxEntries)
        guard maxEntries > 0 else { return }

        let db = self.database
        let storage = self.imageStorage
        await Task.detached(priority: .utility) {
            guard let imagePaths = try? db.pruneToMaxEntries(maxEntries) else { return }
            if !imagePaths.isEmpty {
                PastaLogger.database.debug("Pruned \(imagePaths.count) images due to max entries limit")
            }
            for path in imagePaths {
                try? storage.deleteImage(path: path)
            }
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

        if entry.contentType == .image || entry.contentType == .screenshot, let data = entry.rawData {
            if storeImages {
                do {
                    entry.imagePath = try imageStorage.saveImage(data)
                    entry.rawData = nil
                } catch {
                    PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to save image, continuing without it")
                    entry.rawData = nil
                }
            } else {
                // Don't store image data, just record that an image was copied
                entry.rawData = nil
                PastaLogger.clipboard.debug("Skipped storing image data - disabled in settings")
            }
            return EnrichResult(primaryEntry: entry, extractedEntries: [], envVarSplitEntries: [])
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

        entry.contentType = output.primaryType
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
    @discardableResult
    func deleteRecent(minutes: Int) throws -> Int {
        let deleteService = DeleteService(database: database, imageStorage: imageStorage)
        let count = try deleteService.deleteRecent(minutes: minutes)
        refresh()
        return count
    }
    
    /// Deletes all entries and refreshes the entries list.
    ///
    /// - Parameter includePinned: when `false` (the default), pinned entries are
    ///   preserved. Pass `true` from explicit "wipe everything" UI.
    @discardableResult
    func deleteAll(includePinned: Bool = false) throws -> Int {
        let deleteService = DeleteService(database: database, imageStorage: imageStorage)
        let count = try deleteService.deleteAll(includePinned: includePinned)
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
