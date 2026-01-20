import Combine
import Foundation

@preconcurrency import PastaCore
import PastaDetectors

/// Singleton service that runs clipboard monitoring in the background.
/// This ensures clipboard capture works even when the panel is closed.
@MainActor
final class BackgroundService: ObservableObject {
    static let shared = BackgroundService()
    
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var lastError: PastaError? = nil
    
    let database: DatabaseManager
    
    private let imageStorage: ImageStorageManager
    private let clipboardMonitor: ClipboardMonitor
    private let contentTypeDetector: ContentTypeDetector
    private let screenshotMonitor: ScreenshotMonitor
    
    private var cancellables: Set<AnyCancellable> = []
    private let processingQueue = DispatchQueue(label: "pasta.background.processing")
    
    private enum Defaults {
        static let maxEntries = "pasta.maxEntries"
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
        
        self.clipboardMonitor = ClipboardMonitor()
        self.contentTypeDetector = ContentTypeDetector()
        self.screenshotMonitor = ScreenshotMonitor()
        
        // Set error after initialization completes
        if let error = dbError ?? storageError {
            self.lastError = error
        }
        
        subscribe()
        refresh()
    }
    
    func start() {
        clipboardMonitor.start()
        screenshotMonitor.start()
        PastaLogger.app.info("Background clipboard monitoring started")
    }
    
    func stop() {
        clipboardMonitor.stop()
        screenshotMonitor.stop()
        PastaLogger.app.info("Background clipboard monitoring stopped")
    }
    
    func refresh() {
        let latest = (try? database.fetchRecent(limit: 1_000)) ?? []
        PastaLogger.ui.debug("Refreshed entries: \(latest.count) items")
        self.entries = latest
    }
    
    private func subscribe() {
        clipboardMonitor.publisher
            .sink { [weak self] entry in
                guard let self else { return }
                PastaLogger.clipboard.debug("New clipboard entry received: \(entry.contentType.rawValue)")
                self.processingQueue.async {
                    let enriched: [ClipboardEntry]
                    do {
                        enriched = try self.enrich(entry)
                    } catch {
                        PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Failed to enrich entry")
                        enriched = [entry]
                    }

                    for e in enriched {
                        do {
                            try self.database.insert(e)
                            PastaLogger.clipboard.debug("Inserted entry: \(e.contentType.rawValue)")
                        } catch {
                            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert entry")
                        }
                    }

                    self.enforceMaxEntriesLimit()
                    DispatchQueue.main.async {
                        self.refresh()
                    }
                }
            }
            .store(in: &cancellables)

        screenshotMonitor.publisher
            .sink { [weak self] entry in
                guard let self else { return }
                PastaLogger.clipboard.debug("New screenshot entry received: \(entry.content)")
                self.processingQueue.async {
                    let enriched: [ClipboardEntry]
                    do {
                        enriched = try self.enrich(entry)
                    } catch {
                        PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Failed to enrich screenshot entry")
                        enriched = [entry]
                    }

                    for e in enriched {
                        do {
                            try self.database.insert(e)
                            PastaLogger.clipboard.debug("Inserted entry: \(e.contentType.rawValue)")
                        } catch {
                            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert screenshot entry")
                        }
                    }

                    self.enforceMaxEntriesLimit()
                    DispatchQueue.main.async {
                        self.refresh()
                    }
                }
            }
            .store(in: &cancellables)
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
    
    private func enrich(_ entry: ClipboardEntry) throws -> [ClipboardEntry] {
        var entry = entry

        if entry.contentType == .image || entry.contentType == .screenshot, let data = entry.rawData {
            do {
                entry.imagePath = try imageStorage.saveImage(data)
                entry.rawData = nil
            } catch let error as PastaError {
                PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to save image, continuing without it")
                DispatchQueue.main.async {
                    self.lastError = error
                }
                entry.rawData = nil
            }
            return [entry]
        }

        let output = contentTypeDetector.detect(in: entry.content)

        if output.primaryType == .envVarBlock, !output.splitEntries.isEmpty {
            return output.splitEntries.map { split in
                ClipboardEntry(
                    content: split.content,
                    contentType: split.contentType,
                    timestamp: entry.timestamp,
                    sourceApp: entry.sourceApp,
                    metadata: split.metadataJSON
                )
            }
        }

        entry.contentType = output.primaryType
        entry.metadata = output.metadataJSON

        return [entry]
    }
}
