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
    @Published var lastError: PastaError? = nil
    
    let database: DatabaseManager
    let syncManager: SyncManager
    
    private let imageStorage: ImageStorageManager
    private let clipboardMonitor: ClipboardMonitor
    private let contentTypeDetector: ContentTypeDetector
    private let screenshotMonitor: ScreenshotMonitor
    
    private var cancellables: Set<AnyCancellable> = []
    private var pruneTimer: Timer?
    
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
        // Initialize database with fallback to in-memory on error
        var dbError: PastaError? = nil
        let db: DatabaseManager
        do {
            db = try DatabaseManager()
        } catch let error as PastaError {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Database initialization failed, using in-memory fallback")
            db = try! DatabaseManager.inMemory()
            dbError = error
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Unexpected database error, using in-memory fallback")
            db = try! DatabaseManager.inMemory()
            dbError = PastaError.unknown(underlying: error)
        }
        self.database = db
        
        // Initialize image storage with fallback to temporary directory
        var storageError: PastaError? = nil
        let storage: ImageStorageManager
        do {
            storage = try ImageStorageManager()
        } catch let error as PastaError {
            PastaLogger.logError(error, logger: PastaLogger.storage, context: "Image storage initialization failed, using temporary fallback")
            storage = try! ImageStorageManager(imagesDirectoryURL: .temporaryDirectory)
            storageError = error
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.storage, context: "Unexpected storage error, using temporary fallback")
            storage = try! ImageStorageManager(imagesDirectoryURL: .temporaryDirectory)
            storageError = PastaError.unknown(underlying: error)
        }
        self.imageStorage = storage
        self.syncManager = SyncManager()
        
        self.clipboardMonitor = ClipboardMonitor()
        self.contentTypeDetector = ContentTypeDetector()
        self.screenshotMonitor = ScreenshotMonitor()
        
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
                try await syncManager.registerSubscription()
                PastaLogger.app.info("CloudKit sync initialised")
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.app, context: "CloudKit sync setup failed")
            }
        }
    }
    
    func stop() {
        clipboardMonitor.stop()
        screenshotMonitor.stop()
        pruneTimer?.invalidate()
        pruneTimer = nil
        PastaLogger.app.info("Background clipboard monitoring stopped")
    }
    
    func refresh() {
        // Use maxEntries setting, or 10,000 as a reasonable default for display
        let displayLimit = UserDefaults.standard.integer(forKey: Defaults.maxEntries)
        let limit = displayLimit > 0 ? displayLimit : 10_000
        let latest = (try? database.fetchRecent(limit: limit)) ?? []
        PastaLogger.ui.debug("Refreshed entries: \(latest.count) items")
        self.entries = latest
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
        
        // Use Task instead of Task.detached to maintain actor isolation
        Task {
            // Run database operations on a background thread
            await Task.detached {
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
            
            // Back on MainActor
            self.enforceMaxEntriesLimit()
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
            }
            .store(in: &cancellables)
        
        clipboardMonitor.publisher
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
                
                Task.detached {
                    let result: EnrichResult
                    do {
                        result = try Self.enrich(
                            entry,
                            detector: detector,
                            imageStorage: storage,
                            storeImages: storeImages,
                            extractContent: extractContent
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
                        let syncManager = self.syncManager
                        Task.detached(priority: .utility) {
                            for entry in insertedEntries {
                                try? await syncManager.pushEntry(entry)
                            }
                        }
                    }

                    await self.enforceMaxEntriesLimit()
                    await MainActor.run {
                        self.refresh()
                        self.provideFeedback(for: result.primaryEntry)
                    }
                }
            }
            .store(in: &cancellables)

        screenshotMonitor.publisher
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
                
                Task.detached {
                    let result: EnrichResult
                    do {
                        // Screenshots don't need content extraction
                        result = try Self.enrich(
                            entry,
                            detector: detector,
                            imageStorage: storage,
                            storeImages: storeImages,
                            extractContent: false
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
                        let syncManager = self.syncManager
                        Task.detached(priority: .utility) {
                            for entry in insertedScreenshots {
                                try? await syncManager.pushEntry(entry)
                            }
                        }
                    }

                    await self.enforceMaxEntriesLimit()
                    await MainActor.run {
                        self.refresh()
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
    
    private func enforceMaxEntriesLimit() {
        let maxEntries = UserDefaults.standard.integer(forKey: Defaults.maxEntries)
        guard maxEntries > 0 else { return }

        guard let imagePaths = try? database.pruneToMaxEntries(maxEntries) else { return }
        if !imagePaths.isEmpty {
            PastaLogger.database.debug("Pruned \(imagePaths.count) images due to max entries limit")
        }
        for path in imagePaths {
            try? imageStorage.deleteImage(path: path)
        }
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
        extractContent: Bool
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

        let output = detector.detect(in: entry.content)

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
    @discardableResult
    func deleteAll() throws -> Int {
        let deleteService = DeleteService(database: database, imageStorage: imageStorage)
        let count = try deleteService.deleteAll()
        refresh()
        return count
    }
}
