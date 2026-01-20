# Exact Code Patches - Error Handling Implementation

## File 1: Sources/PastaCore/PastaError.swift (NEW FILE)

```swift
import Foundation
import os.log

/// Central error type for Pasta app with user-friendly messages
public enum PastaError: LocalizedError {
    case databaseCorrupted(underlying: Error)
    case databaseInitializationFailed(underlying: Error)
    case diskFull(path: String, underlying: Error)
    case imageSaveFailed(underlying: Error)
    case clipboardAccessDenied
    case hotkeyConflict(key: String)
    case storageUnavailable(path: String)
    case unknown(underlying: Error)
    
    public var errorDescription: String? {
        switch self {
        case .databaseCorrupted:
            return "Database Error"
        case .databaseInitializationFailed:
            return "Database Initialization Failed"
        case .diskFull:
            return "Disk Full"
        case .imageSaveFailed:
            return "Image Save Failed"
        case .clipboardAccessDenied:
            return "Clipboard Access Denied"
        case .hotkeyConflict:
            return "Hotkey Conflict"
        case .storageUnavailable:
            return "Storage Unavailable"
        case .unknown:
            return "Unexpected Error"
        }
    }
    
    public var failureReason: String? {
        switch self {
        case .databaseCorrupted:
            return "The clipboard history database is corrupted and cannot be read."
        case .databaseInitializationFailed:
            return "Failed to initialize the clipboard history database."
        case .diskFull(let path, _):
            return "Not enough disk space to save image at \(path)."
        case .imageSaveFailed:
            return "Could not save clipboard image to disk."
        case .clipboardAccessDenied:
            return "Pasta does not have permission to access the clipboard."
        case .hotkeyConflict(let key):
            return "The hotkey '\(key)' is already in use by another application."
        case .storageUnavailable(let path):
            return "Cannot access storage directory at \(path)."
        case .unknown(let error):
            return error.localizedDescription
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .databaseCorrupted:
            return "Pasta will use a temporary in-memory database. Your history will not be saved. Restart the app to attempt recovery, or delete ~/Library/Application Support/Pasta/pasta.sqlite to reset."
        case .databaseInitializationFailed:
            return "Check disk space and permissions for ~/Library/Application Support/Pasta/. Pasta will use temporary storage."
        case .diskFull:
            return "Free up disk space and try again. The clipboard entry was saved but without the image."
        case .imageSaveFailed:
            return "Check disk space and permissions for ~/Library/Application Support/Pasta/Images/."
        case .clipboardAccessDenied:
            return "Grant Accessibility permissions in System Settings > Privacy & Security > Accessibility."
        case .hotkeyConflict:
            return "Choose a different hotkey in Pasta settings."
        case .storageUnavailable:
            return "Check permissions for the application support directory."
        case .unknown:
            return "Please try restarting the app. If the problem persists, check system logs."
        }
    }
}

/// Centralized logging for Pasta
public struct PastaLogger {
    private static let subsystem = "com.pasta.clipboard"
    
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    
    /// Log an error with context
    public static func logError(_ error: Error, logger: Logger, context: String) {
        if let pastaError = error as? PastaError {
            logger.error("\(context): \(pastaError.errorDescription ?? "Unknown") - \(pastaError.failureReason ?? "")")
        } else {
            logger.error("\(context): \(error.localizedDescription)")
        }
    }
}
```

## File 2: Sources/PastaCore/DatabaseManager.swift

### Patch 1: Add import
```swift
// BEFORE (line 1-2):
import Foundation
import GRDB

// AFTER:
import Foundation
import GRDB
import os.log
```

### Patch 2: Update init method
```swift
// BEFORE (line 7-17):
    public init(databaseURL: URL = DatabaseManager.defaultDatabaseURL()) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.foreignKeysEnabled = true

        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try DatabaseManager.migrator.migrate(dbQueue)
    }

// AFTER:
    public init(databaseURL: URL = DatabaseManager.defaultDatabaseURL()) throws {
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to create database directory")
            throw PastaError.storageUnavailable(path: databaseURL.deletingLastPathComponent().path)
        }

        var config = Configuration()
        config.foreignKeysEnabled = true

        do {
            self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
            try DatabaseManager.migrator.migrate(dbQueue)
            PastaLogger.database.info("Database initialized at \(databaseURL.path)")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Database initialization or migration failed")
            
            // Check if this is corruption-related
            if error.localizedDescription.contains("corrupt") || error.localizedDescription.contains("malformed") {
                PastaLogger.database.warning("Database appears corrupted, attempting recovery")
                throw PastaError.databaseCorrupted(underlying: error)
            }
            
            throw PastaError.databaseInitializationFailed(underlying: error)
        }
    }
```

### Patch 3: Update insert method
```swift
// BEFORE (line 105-144):
    public func insert(_ entry: ClipboardEntry) throws {
        let contentHash = entry.contentHash

        try dbQueue.write { db in
            if let existingID: String = try String.fetchOne(
                db,
                sql: "SELECT id FROM \(ClipboardEntry.databaseTableName) WHERE contentHash = ? LIMIT 1",
                arguments: [contentHash]
            ) {
                try db.execute(
                    sql: """
                    UPDATE \(ClipboardEntry.databaseTableName)
                    SET copyCount = copyCount + 1, timestamp = ?
                    WHERE id = ?
                    """,
                    arguments: [entry.timestamp, existingID]
                )
                return
            }

            try db.execute(
                sql: """
                INSERT INTO \(ClipboardEntry.databaseTableName)
                (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    entry.id.uuidString,
                    entry.content,
                    entry.contentType.rawValue,
                    entry.rawData,
                    entry.imagePath,
                    entry.timestamp,
                    entry.copyCount,
                    entry.sourceApp,
                    entry.metadata,
                    contentHash,
                ]
            )
        }
    }

// AFTER:
    public func insert(_ entry: ClipboardEntry) throws {
        let contentHash = entry.contentHash

        do {
            try dbQueue.write { db in
                if let existingID: String = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM \(ClipboardEntry.databaseTableName) WHERE contentHash = ? LIMIT 1",
                    arguments: [contentHash]
                ) {
                    try db.execute(
                        sql: """
                        UPDATE \(ClipboardEntry.databaseTableName)
                        SET copyCount = copyCount + 1, timestamp = ?
                        WHERE id = ?
                        """,
                        arguments: [entry.timestamp, existingID]
                    )
                    PastaLogger.database.debug("Updated duplicate entry with hash \(contentHash)")
                    return
                }

                try db.execute(
                    sql: """
                    INSERT INTO \(ClipboardEntry.databaseTableName)
                    (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp, metadata, contentHash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.content,
                        entry.contentType.rawValue,
                        entry.rawData,
                        entry.imagePath,
                        entry.timestamp,
                        entry.copyCount,
                        entry.sourceApp,
                        entry.metadata,
                        contentHash,
                    ]
                )
                PastaLogger.database.debug("Inserted new entry with type \(entry.contentType.rawValue)")
            }
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to insert entry")
            throw error
        }
    }
```

## File 3: Sources/PastaCore/ImageStorageManager.swift

### Patch 1: Add import
```swift
// BEFORE (line 1-3):
import CryptoKit
import Foundation

// AFTER:
import CryptoKit
import Foundation
import os.log
```

### Patch 2: Update init
```swift
// BEFORE (line 11-14):
    public init(imagesDirectoryURL: URL = ImageStorageManager.defaultImagesDirectoryURL()) throws {
        self.imagesDirectoryURL = imagesDirectoryURL
        try FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
    }

// AFTER:
    public init(imagesDirectoryURL: URL = ImageStorageManager.defaultImagesDirectoryURL()) throws {
        self.imagesDirectoryURL = imagesDirectoryURL
        do {
            try FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
            PastaLogger.storage.info("Image storage initialized at \(imagesDirectoryURL.path)")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to create images directory")
            throw PastaError.storageUnavailable(path: imagesDirectoryURL.path)
        }
    }
```

### Patch 3: Update saveImage
```swift
// BEFORE (line 24-33):
    public func saveImage(_ data: Data) throws -> String {
        let filename = "\(ImageStorageManager.sha256Hex(data)).dat"
        let url = imagesDirectoryURL.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: [.atomic])
        }

        return url.path
    }

// AFTER:
    public func saveImage(_ data: Data) throws -> String {
        let filename = "\(ImageStorageManager.sha256Hex(data)).dat"
        let url = imagesDirectoryURL.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try data.write(to: url, options: [.atomic])
                PastaLogger.storage.debug("Saved image to \(url.path) (\(data.count) bytes)")
            } catch let error as NSError {
                // Check for disk full errors
                if error.domain == NSCocoaErrorDomain && (error.code == NSFileWriteOutOfSpaceError || error.code == NSFileWriteVolumeReadOnlyError) {
                    PastaLogger.storage.error("Disk full or read-only when saving image")
                    throw PastaError.diskFull(path: url.path, underlying: error)
                }
                PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to save image")
                throw PastaError.imageSaveFailed(underlying: error)
            }
        }

        return url.path
    }
```

### Patch 4: Update deleteImage
```swift
// BEFORE (line 46-50):
    public func deleteImage(path: String) throws {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

// AFTER:
    public func deleteImage(path: String) throws {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                PastaLogger.storage.debug("Deleted image at \(path)")
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to delete image")
                throw error
            }
        }
    }
```

## File 4: Sources/PastaCore/ClipboardMonitor.swift

### Patch 1: Add import
```swift
// BEFORE (line 1-2):
import Foundation
import Combine

// AFTER:
import Foundation
import Combine
import os.log
```

### Patch 2: Update pollOnce
```swift
// BEFORE (line 131-154):
    private func pollOnce() {
        let changeCount = pasteboard.changeCount
        if let lastSeenChangeCount, changeCount == lastSeenChangeCount { return }
        lastSeenChangeCount = changeCount

        guard let contents = pasteboard.readContents() else { return }
        if contents == lastEmittedContents { return }
        lastEmittedContents = contents

        let sourceApp = workspace?.frontmostApplicationIdentifier()
        if exclusionManager.isExcluded(bundleIdentifier: sourceApp) {
            return
        }

        let entry = ClipboardEntry(
            content: contentString(for: contents),
            contentType: contentType(for: contents),
            rawData: rawData(for: contents),
            timestamp: now(),
            sourceApp: sourceApp
        )

        subject.send(entry)
    }

// AFTER:
    private func pollOnce() {
        let changeCount = pasteboard.changeCount
        if let lastSeenChangeCount, changeCount == lastSeenChangeCount { return }
        lastSeenChangeCount = changeCount

        guard let contents = pasteboard.readContents() else {
            // If we can't read the clipboard, it might be an access issue
            PastaLogger.clipboard.warning("Failed to read clipboard contents - may be access denied")
            return
        }
        
        if contents == lastEmittedContents { return }
        lastEmittedContents = contents

        let sourceApp = workspace?.frontmostApplicationIdentifier()
        if exclusionManager.isExcluded(bundleIdentifier: sourceApp) {
            PastaLogger.clipboard.debug("Skipped entry from excluded app: \(sourceApp ?? "unknown")")
            return
        }

        let entry = ClipboardEntry(
            content: contentString(for: contents),
            contentType: contentType(for: contents),
            rawData: rawData(for: contents),
            timestamp: now(),
            sourceApp: sourceApp
        )

        PastaLogger.clipboard.debug("Captured clipboard entry of type \(entry.contentType.rawValue)")
        subject.send(entry)
    }
```

## File 5: Sources/PastaCore/HotkeyManager.swift

### Patch 1: Add import
```swift
// BEFORE (line 1):
import Foundation

// AFTER:
import Foundation
import os.log
```

### Patch 2: Update init
```swift
// BEFORE (line 43-62):
    public init(
        provider: HotKeyProviding = SystemHotKeyProvider(),
        userDefaults: UserDefaults = .standard,
        onTrigger: @escaping () -> Void
    ) {
        self.provider = provider
        self.userDefaults = userDefaults
        self.onTrigger = onTrigger

        let initial = HotkeyManager.loadHotkey(from: userDefaults)
        hotKey = provider.makeHotKey(key: initial.key, modifiers: initial.modifiers)
        hotKey.keyDownHandler = onTrigger

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromUserDefaults()
        }
    }

// AFTER:
    public init(
        provider: HotKeyProviding = SystemHotKeyProvider(),
        userDefaults: UserDefaults = .standard,
        onTrigger: @escaping () -> Void
    ) {
        self.provider = provider
        self.userDefaults = userDefaults
        self.onTrigger = onTrigger

        let initial = HotkeyManager.loadHotkey(from: userDefaults)
        hotKey = provider.makeHotKey(key: initial.key, modifiers: initial.modifiers)
        hotKey.keyDownHandler = onTrigger
        
        PastaLogger.hotkey.info("Hotkey registered: \(String(describing: initial.key)) with modifiers \(initial.modifiers.rawValue)")

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromUserDefaults()
        }
    }
```

### Patch 3: Update reloadFromUserDefaults
```swift
// BEFORE (line 71-75):
    public func reloadFromUserDefaults() {
        let pref = HotkeyManager.loadHotkey(from: userDefaults)
        hotKey = provider.makeHotKey(key: pref.key, modifiers: pref.modifiers)
        hotKey.keyDownHandler = onTrigger
    }

// AFTER:
    public func reloadFromUserDefaults() {
        let pref = HotkeyManager.loadHotkey(from: userDefaults)
        hotKey = provider.makeHotKey(key: pref.key, modifiers: pref.modifiers)
        hotKey.keyDownHandler = onTrigger
        PastaLogger.hotkey.info("Hotkey reloaded: \(String(describing: pref.key))")
    }
```

## File 6: Sources/PastaCore/PasteService.swift

### Patch 1: Add import
```swift
// BEFORE (line 1):
import Foundation

// AFTER:
import Foundation
import os.log
```

### Patch 2: Update paste method
```swift
// BEFORE (line 82-88):
    @discardableResult
    public func paste(_ entry: ClipboardEntry) -> Bool {
        guard let contents = makeContents(for: entry) else { return false }
        pasteboard.write(contents)
        simulator.simulateCommandV()
        return true
    }

// AFTER:
    @discardableResult
    public func paste(_ entry: ClipboardEntry) -> Bool {
        guard let contents = makeContents(for: entry) else {
            PastaLogger.clipboard.warning("Cannot create pasteboard contents for entry type \(entry.contentType.rawValue)")
            return false
        }
        
        pasteboard.write(contents)
        simulator.simulateCommandV()
        PastaLogger.clipboard.debug("Pasted entry of type \(entry.contentType.rawValue)")
        return true
    }
```

## File 7: Sources/PastaCore/DeleteService.swift

### Patch: Replace entire file
```swift
import Foundation
import os.log

public final class DeleteService {
    private let database: DatabaseManager
    private let imageStorage: ImageStorageManager

    public init(database: DatabaseManager, imageStorage: ImageStorageManager) {
        self.database = database
        self.imageStorage = imageStorage
    }

    /// Deletes a single entry by ID and cleans up any associated image file.
    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        do {
            let entry = try database.fetch(id: id)
            let deleted = try database.delete(id: id)

            if deleted, let imagePath = entry?.imagePath {
                try imageStorage.deleteImage(path: imagePath)
            }

            PastaLogger.database.debug("Deleted entry \(id.uuidString)")
            return deleted
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete entry")
            throw error
        }
    }

    /// Deletes entries from the last X minutes and cleans up any associated image files.
    @discardableResult
    public func deleteRecent(minutes: Int, now: Date = Date()) throws -> Int {
        do {
            let result = try database.deleteRecent(minutes: minutes, now: now)

            for imagePath in result.imagePaths {
                try imageStorage.deleteImage(path: imagePath)
            }

            PastaLogger.database.info("Deleted \(result.count) recent entries from last \(minutes) minutes")
            return result.count
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete recent entries")
            throw error
        }
    }

    /// Deletes all entries and cleans up any associated image files.
    @discardableResult
    public func deleteAll() throws -> Int {
        do {
            let result = try database.deleteAll()

            for imagePath in result.imagePaths {
                try imageStorage.deleteImage(path: imagePath)
            }

            PastaLogger.database.info("Deleted all \(result.count) entries")
            return result.count
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.database, context: "Failed to delete all entries")
            throw error
        }
    }
}
```

## File 8: Sources/PastaApp/AppViewModel.swift

### Patch 1: Add import and published property
```swift
// BEFORE (line 1-12):
import Combine
import Foundation

@preconcurrency import PastaCore
import PastaDetectors

final class AppViewModel: ObservableObject {
    private enum Defaults {
        static let maxEntries = "pasta.maxEntries"
    }

    @Published private(set) var entries: [ClipboardEntry] = []

// AFTER:
import Combine
import Foundation
import os.log

@preconcurrency import PastaCore
import PastaDetectors

final class AppViewModel: ObservableObject {
    private enum Defaults {
        static let maxEntries = "pasta.maxEntries"
    }

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var lastError: PastaError? = nil
```

### Patch 2: Replace init method
```swift
// BEFORE (line 23-33):
    init() {
        self.database = (try? DatabaseManager()) ?? (try! DatabaseManager.inMemory())
        self.imageStorage = (try? ImageStorageManager()) ?? (try! ImageStorageManager(imagesDirectoryURL: .temporaryDirectory))

        self.clipboardMonitor = ClipboardMonitor()
        self.contentTypeDetector = ContentTypeDetector()

        subscribe()
        refresh()
        clipboardMonitor.start()
    }

// AFTER:
    init() {
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

        // Set error after initialization completes
        if let error = dbError ?? storageError {
            DispatchQueue.main.async {
                self.lastError = error
            }
        }

        subscribe()
        refresh()
        clipboardMonitor.start()
    }
```

### Patch 3: Update enrich method
```swift
// BEFORE (line 75-102):
    private func enrich(_ entry: ClipboardEntry) throws -> [ClipboardEntry] {
        var entry = entry

        if entry.contentType == .image, let data = entry.rawData {
            entry.imagePath = try imageStorage.saveImage(data)
            entry.rawData = nil
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

// AFTER:
    private func enrich(_ entry: ClipboardEntry) throws -> [ClipboardEntry] {
        var entry = entry

        if entry.contentType == .image, let data = entry.rawData {
            do {
                entry.imagePath = try imageStorage.saveImage(data)
                entry.rawData = nil
            } catch let error as PastaError {
                // If disk is full, save entry without image
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
```

## File 9: Sources/PastaApp/PastaApp.swift

### Patch 1: Add state variable
```swift
// BEFORE (line 59-61):
    @State private var isShowingBulkDelete: Bool = false
    @State private var lastBulkDeleteSummary: String? = nil

    @State private var isShowingOnboarding: Bool = false

// AFTER:
    @State private var isShowingBulkDelete: Bool = false
    @State private var lastBulkDeleteSummary: String? = nil

    @State private var isShowingOnboarding: Bool = false
    @State private var isShowingErrorAlert: Bool = false
```

### Patch 2: Add onChange for errors (after .onAppear)
```swift
// BEFORE (line 188-189):
            isShowingOnboarding = !didCompleteOnboarding || !AccessibilityPermission.isTrusted()
        }
        .onChange(of: contentTypeFilter) { _, newValue in

// AFTER:
            isShowingOnboarding = !didCompleteOnboarding || !AccessibilityPermission.isTrusted()
        }
        .onChange(of: appModel.lastError) { _, error in
            if error != nil {
                isShowingErrorAlert = true
            }
        }
        .onChange(of: contentTypeFilter) { _, newValue in
```

### Patch 3: Add alert modifier (after onboarding sheet, before final closing brace)
```swift
// BEFORE (line 230-234):
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView { completion in
                switch completion {
                case .dismissed:
                    isShowingOnboarding = false
                case .completed:
                    didCompleteOnboarding = true
                    isShowingOnboarding = false
                }
            }
        }
    }

// AFTER:
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView { completion in
                switch completion {
                case .dismissed:
                    isShowingOnboarding = false
                case .completed:
                    didCompleteOnboarding = true
                    isShowingOnboarding = false
                }
            }
        }
        .alert(
            appModel.lastError?.errorDescription ?? "Error",
            isPresented: $isShowingErrorAlert,
            presenting: appModel.lastError
        ) { _ in
            Button("OK") {
                appModel.lastError = nil
            }
        } message: { error in
            Text(errorMessage(for: error))
        }
    }

    private func errorMessage(for error: PastaError) -> String {
        var message = ""
        if let reason = error.failureReason {
            message += reason
        }
        if let suggestion = error.recoverySuggestion {
            message += "\n\n" + suggestion
        }
        return message
    }
```

---

## Build and Verify

```bash
cd /Users/cm/work/pasta
swift build
chmod +x verify_error_handling.sh
./verify_error_handling.sh
```
